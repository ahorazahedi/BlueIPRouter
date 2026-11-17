// blueiprouter-helper — runs as root. Applies BlueIPRouter rules to the kernel routing table and pf.
//
//   apply [--trigger <name>]   reconcile routes and the kill switch with the rule files (app + LaunchDaemon)
//   remove-all                 delete every route this helper installed and unload the kill switch
//   killswitch-off             unload the kill switch only
//   detect-vpn                 record the servers VPN cores (xray, sing-box…) are connected to
//   plan <rules.json>          dry run (no root): print the route commands a rules file would produce
//   version                    print version
//
// It only reads root-owned files, validates every value, and runs tools with argument arrays (no shell).

import BlueIPRouterCore
import Darwin
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    print(message)
    if !FileManager.default.fileExists(atPath: BIR.log) {
        FileManager.default.createFile(atPath: BIR.log, contents: nil, attributes: [.posixPermissions: 0o644])
    }
    if let handle = FileHandle(forWritingAtPath: BIR.log) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    }
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

func ensureDirs() {
    mkdir(BIR.runDir, 0o755)
    chmod(BIR.runDir, 0o755)
    try? FileManager.default.createDirectory(atPath: BIR.systemDir, withIntermediateDirectories: true)
}

/// Serialises runs so the daemon and a manual apply never race.
func withLock<T>(_ body: () -> T) -> T {
    ensureDirs()
    let fd = open(BIR.lockFile, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { fail("cannot open lock file") }
    flock(fd, LOCK_EX)
    defer { flock(fd, LOCK_UN); close(fd) }
    return body()
}

func route(_ args: [String]) -> ShellResult { Shell.run("/sbin/route", args, timeout: 10) }
func pfctl(_ args: [String]) -> ShellResult { Shell.run("/sbin/pfctl", args, timeout: 15) }

func loadRules() -> [RouteRule] {
    let persistent = BIRJSON.load(HelperConfig.self, from: BIR.persistentRules)?.rules ?? []
    let session = BIRJSON.load(HelperConfig.self, from: BIR.sessionRules)?.rules ?? []
    var seen = Set<UUID>()
    return (persistent + session).filter { seen.insert($0.id).inserted }
}

func removeRoute(_ old: ManagedRoute, reason: String) -> Bool {
    if old.keepOnRemove == true {
        log("left \(old.destinationLabel) in place (\(reason); rule keeps its routes)")
        return false
    }
    guard RouteCommands.isInstalled(old, RouteQuery.lookup(old.destination, prefix: old.prefix)) else { return false }
    let r = route(RouteCommands.delete(old))
    log(r.ok ? "removed \(old.destinationLabel) -> \(old.nextHopLabel) (\(reason))" : "failed to remove \(old.destinationLabel): \(r.combined)")
    return r.ok
}

// MARK: - Kill switch

func pfIsEnabled() -> Bool { pfctl(["-s", "info"]).combined.contains("Status: Enabled") }

func ensurePFEnabled() -> Bool {
    if pfIsEnabled() { return true }
    let r = pfctl(["-E"])
    if let token = r.combined.split(separator: "\n").first(where: { $0.contains("Token") })?
        .split(separator: ":").last?.trimmingCharacters(in: .whitespaces), !token.isEmpty {
        try? token.write(toFile: BIR.pfToken, atomically: true, encoding: .utf8)
    }
    return pfIsEnabled()
}

func killSwitchOff(reason: String) {
    let flushed = pfctl(["-a", BIR.pfAnchor, "-F", "all"])
    if let token = try? String(contentsOfFile: BIR.pfToken, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
       !token.isEmpty, token.allSatisfy(\.isNumber) {
        _ = pfctl(["-X", token])
        try? FileManager.default.removeItem(atPath: BIR.pfToken)
    }
    try? FileManager.default.removeItem(atPath: BIR.pfRules)
    if flushed.ok { log("kill switch off (\(reason))") }
}

func learnVPNServers() -> [String] {
    var learned = Set(BIRJSON.load([String].self, from: BIR.learnedServers) ?? [])
    let before = learned.count
    for (_, ips) in NetworkFacts.vpnServerPeers() { learned.formUnion(ips) }
    let list = Array(learned).sorted()
    if list.count != before {
        try? BIRJSON.save(list, to: BIR.learnedServers)
        log("learned VPN servers: \(list.joined(separator: ", "))")
    }
    return list
}

func resolveEntries(_ entries: [String], cache: inout [String: [String]]) -> (cidrs: [String], errors: [String]) {
    var cidrs: [String] = []
    var errors: [String] = []
    for raw in entries {
        switch KSEntry.parse(raw) {
        case .cidr(let c): cidrs.append(c)
        case .domain(let d):
            let ips = (Resolver.resolve(d, family: AF_INET, timeout: 4) ?? []) + (Resolver.resolve(d, family: AF_INET6, timeout: 3) ?? [])
            if !ips.isEmpty { cache["ks:" + d] = ips } else if cache["ks:" + d] == nil { errors.append("Could not resolve \(d)") }
            cidrs += (cache["ks:" + d] ?? []).compactMap(CIDR.normalize)
        case nil: errors.append("Ignored invalid entry \(raw)")
        }
    }
    return (cidrs, errors)
}

func applyKillSwitch(routes: [ManagedRoute], interfaces: [InterfaceSnapshot], cache: inout [String: [String]]) -> KillSwitchStatus? {
    guard let cfg = BIRJSON.load(KillSwitchConfig.self, from: BIR.killSwitchConfig), cfg.enabled else {
        if FileManager.default.fileExists(atPath: BIR.pfRules) { killSwitchOff(reason: "disabled") }
        return nil
    }
    let ifs = cfg.interfaces.filter(Validation.isInterfaceName)
    var errors: [String] = []
    var blocked: [String] = []
    var allowed: [String] = []
    var dns: [String] = []
    let learned = cfg.learnVPNServers ? learnVPNServers() : []

    switch cfg.mode {
    case .destinations:
        for list in cfg.blockLists where list.enabled {
            let r = resolveEntries(list.entries, cache: &cache)
            blocked += r.cidrs
            errors += r.errors
        }
    case .fullSystem:
        let r = resolveEntries(cfg.allow, cache: &cache)
        allowed += r.cidrs
        errors += r.errors
        allowed += learned.compactMap(CIDR.normalize)
        if cfg.allowLocalNetworks {
            allowed += NetworkFacts.attachedNetworks(interfaces, names: ifs) + KillSwitchCompiler.linkLocalRanges
        }
        if cfg.allowRuleDestinations { allowed += routes.map(\.key) }
        if cfg.allowDNS { dns = NetworkFacts.dnsServers() }
        if learned.isEmpty && cfg.allow.isEmpty {
            errors.append("No VPN server is allowed yet: connect your VPN once and press “Detect VPN servers”, or the VPN cannot reconnect.")
        }
    }
    blocked = Array(Set(blocked)).sorted()
    allowed = Array(Set(allowed)).sorted()

    let text = KillSwitchCompiler.compile(mode: cfg.mode, interfaces: ifs, blocked: blocked, allowed: allowed,
                                          dnsServers: dns, allowDHCP: cfg.allowDHCP)
    let previous = try? String(contentsOfFile: BIR.pfRules, encoding: .utf8)
    let changed = previous.map { $0.split(separator: "\n").dropFirst() != text.split(separator: "\n").dropFirst() } ?? true
    var pfOK = true
    if changed || !pfIsEnabled() {
        do {
            try text.write(toFile: BIR.pfRules, atomically: true, encoding: .utf8)
            chmod(BIR.pfRules, 0o644)
        } catch { errors.append("Cannot write pf rules: \(error)") }
        let load = pfctl(["-a", BIR.pfAnchor, "-f", BIR.pfRules])
        if !load.ok {
            pfOK = false
            errors.append("pfctl rejected the rules: \(load.combined)")
            log("kill switch load failed: \(load.combined)")
        } else if changed {
            log("kill switch loaded (\(cfg.mode.rawValue)) on \(ifs.joined(separator: ", ")): \(cfg.mode == .destinations ? "\(blocked.count) blocked" : "\(allowed.count) allowed") ranges")
        }
    }
    let enabled = pfOK && ensurePFEnabled()
    if !enabled { errors.append("pf could not be enabled") }
    return KillSwitchStatus(active: pfOK, mode: cfg.mode, interfaces: ifs, blocked: blocked, allowed: allowed,
                            dnsServers: dns, learnedServers: learned, pfEnabled: enabled, errors: errors)
}

// MARK: - Apply

func apply(trigger: String) {
    let rules = loadRules()
    var cache = BIRJSON.load([String: [String]].self, from: BIR.dnsCache) ?? [:]
    let previous = BIRJSON.load([ManagedRoute].self, from: BIR.appliedState) ?? []
    let interfaces = InterfaceInventory.snapshot()

    let plan = RoutePlanner.plan(rules: rules, interfaces: interfaces,
                                 router: { RouteQuery.router(of: $0) },
                                 resolve: { Resolver.resolve($0, timeout: 4) },
                                 cache: cache)
    cache.merge(plan.cache) { _, new in new }
    var statuses = plan.statuses
    let desiredKeys = Set(plan.routes.map(\.key))
    let liveRules = Set(rules.filter(\.enabled).map(\.id))

    // 1. Remove routes we installed earlier that are no longer wanted.
    for old in previous where !desiredKeys.contains(old.key) {
        // A rule whose interface is just down keeps its routes recorded so they come back later.
        if liveRules.contains(old.ruleID), statuses[old.ruleID]?.state == .waiting { continue }
        _ = removeRoute(old, reason: "no longer in any rule")
    }

    // 2. Install or correct every desired route.
    var installed: [ManagedRoute] = previous.filter { old in
        !desiredKeys.contains(old.key) && liveRules.contains(old.ruleID) && statuses[old.ruleID]?.state == .waiting
    }
    for desired in plan.routes {
        let current = RouteQuery.lookup(desired.destination, prefix: desired.prefix)
        if RouteCommands.isInstalled(desired, current) {
            installed.append(desired)
            statuses[desired.ruleID]?.routes.append("\(desired.destinationLabel) → \(desired.nextHopLabel)")
            continue
        }
        if RouteCommands.exactRouteExists(desired, current) {
            _ = route(RouteCommands.delete(desired))
        }
        let r = route(RouteCommands.add(desired))
        if r.ok {
            installed.append(desired)
            statuses[desired.ruleID]?.routes.append("\(desired.destinationLabel) → \(desired.nextHopLabel)")
            log("added \(desired.destinationLabel) -> \(desired.nextHopLabel)\(desired.sourceDomain.map { " [\($0)]" } ?? "")")
        } else {
            statuses[desired.ruleID]?.messages.append("route add \(desired.destinationLabel) failed: \(r.combined)")
            log("failed to add \(desired.destinationLabel): \(r.combined)")
        }
    }

    var ordered: [RuleStatus] = []
    for rule in rules {
        guard var st = statuses[rule.id] else { continue }
        st.finalize()
        ordered.append(st)
    }

    // 3. Kill switch (pf).
    let ks = applyKillSwitch(routes: plan.routes, interfaces: interfaces, cache: &cache)

    do {
        ensureDirs()
        try BIRJSON.save(installed, to: BIR.appliedState)
        try BIRJSON.save(HelperStatus(updatedAt: Date(), trigger: trigger, rules: ordered, installedRoutes: installed, killSwitch: ks), to: BIR.status)
        try BIRJSON.save(cache, to: BIR.dnsCache)
    } catch {
        fail("could not write state: \(error)")
    }
    print("ok: \(installed.count)/\(plan.routes.count) routes for \(rules.filter(\.enabled).count) enabled rules; kill switch \(ks?.active == true ? "on" : "off")")
}

func removeAll() {
    let previous = BIRJSON.load([ManagedRoute].self, from: BIR.appliedState) ?? []
    var removed = 0
    for old in previous where removeRoute(old, reason: "remove-all") { removed += 1 }
    killSwitchOff(reason: "remove-all")
    ensureDirs()
    try? BIRJSON.save([ManagedRoute](), to: BIR.appliedState)
    try? BIRJSON.save(HelperStatus(updatedAt: Date(), trigger: "remove-all", rules: [], installedRoutes: []), to: BIR.status)
    print("ok: removed \(removed) routes, kill switch off")
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "version":
    print(BIR.version)
case "plan":
    guard args.count >= 2, let config = BIRJSON.load(HelperConfig.self, from: args[1]) else { fail("usage: plan <rules.json>") }
    let plan = RoutePlanner.plan(rules: config.rules, interfaces: InterfaceInventory.snapshot(),
                                 router: { RouteQuery.router(of: $0) }, resolve: { Resolver.resolve($0, timeout: 4) }, cache: [:])
    for r in plan.routes {
        let state = RouteCommands.isInstalled(r, RouteQuery.lookup(r.destination, prefix: r.prefix)) ? "installed" : "missing"
        print("\(RouteCommands.display(RouteCommands.add(r)))   [\(state)]\(r.keepOnRemove == true ? " keep" : "")")
    }
    for (_, st) in plan.statuses { for m in st.messages { print("note: \(m)") } }
case "apply":
    guard geteuid() == 0 else { fail("must run as root", code: 77) }
    var trigger = "manual"
    if let i = args.firstIndex(of: "--trigger"), i + 1 < args.count { trigger = args[i + 1] }
    withLock { apply(trigger: trigger) }
case "remove-all":
    guard geteuid() == 0 else { fail("must run as root", code: 77) }
    withLock { removeAll() }
case "killswitch-off":
    guard geteuid() == 0 else { fail("must run as root", code: 77) }
    withLock { killSwitchOff(reason: "manual") }
case "detect-vpn":
    guard geteuid() == 0 else { fail("must run as root", code: 77) }
    withLock {
        let peers = NetworkFacts.vpnServerPeers()
        for (name, ips) in peers.sorted(by: { $0.key < $1.key }) { print("\(name): \(ips.joined(separator: ", "))") }
        let all = learnVPNServers()
        print("learned: \(all.joined(separator: ", "))")
    }
default:
    print("usage: blueiprouter-helper apply [--trigger name] | remove-all | killswitch-off | detect-vpn | plan <file> | version")
    exit(64)
}
