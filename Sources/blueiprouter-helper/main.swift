// blueiprouter-helper — runs as root. Applies BlueIPRouter rules to the kernel routing table and pf.
//
//   daemon [--interval <s>]    long-running mode for the LaunchDaemon: applies at start, on every network
//                              change (SystemConfiguration notifications) and every <s> seconds
//   apply [--trigger <name>]   one reconcile pass: events, triggers, profile, routes, kill switch, DNS
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
import SystemConfiguration

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

func pfAnchorHasRules() -> Bool {
    let r = pfctl(["-a", BIR.pfAnchor, "-s", "rules"])
    return r.ok && !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

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
            // Without IPv6 connectivity the resolver returns IPv4-mapped ::ffff: addresses; they are not real IPv6.
            let ips = ((Resolver.resolve(d, family: AF_INET, timeout: 4) ?? []) + (Resolver.resolve(d, family: AF_INET6, timeout: 3) ?? []))
                .filter { !$0.lowercased().hasPrefix("::ffff:") }
            if !ips.isEmpty { cache["ks:" + d] = ips } else if cache["ks:" + d] == nil { errors.append("Could not resolve \(d)") }
            cidrs += (cache["ks:" + d] ?? []).compactMap(CIDR.normalize)
        case nil: errors.append("Ignored invalid entry \(raw)")
        }
    }
    return (cidrs, errors)
}

/// Loads the pf anchor: the block list (all interfaces) plus the kill switch (guarded interfaces).
func applyFirewall(routes: [ManagedRoute], interfaces: [InterfaceSnapshot], cache: inout [String: [String]],
                   enabledOverride: Bool?, blockEntries: [BlockEntry]) -> (killSwitch: KillSwitchStatus?, blockList: BlockListStatus?) {
    let loaded = BIRJSON.load(KillSwitchConfig.self, from: BIR.killSwitchConfig)
    let ksEnabled = loaded.map { enabledOverride ?? $0.enabled } ?? (enabledOverride ?? false)
    let cfg = loaded ?? KillSwitchConfig()

    var denyErrors: [String] = []
    var denied: [String] = []
    let denyValues = blockEntries.filter(\.enabled).map(\.value)
    if !denyValues.isEmpty {
        let r = resolveEntries(denyValues, cache: &cache)
        denied = Array(Set(r.cidrs)).sorted()
        denyErrors = r.errors
    }

    guard ksEnabled || !denied.isEmpty else {
        if FileManager.default.fileExists(atPath: BIR.pfRules) { killSwitchOff(reason: "nothing to enforce") }
        return (nil, denyValues.isEmpty ? nil : BlockListStatus(active: false, denied: [], errors: denyErrors))
    }

    let ifs = cfg.interfaces.filter(Validation.isInterfaceName)
    var errors: [String] = []
    var blocked: [String] = []
    var allowed: [String] = []
    var dns: [String] = []
    var learned: [String] = []
    if ksEnabled {
        learned = cfg.learnVPNServers ? learnVPNServers() : []
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
    }

    let text = KillSwitchCompiler.compile(mode: cfg.mode, interfaces: ifs, blocked: blocked, allowed: allowed,
                                          dnsServers: dns, allowDHCP: cfg.allowDHCP, killSwitch: ksEnabled, denied: denied)
    let previous = try? String(contentsOfFile: BIR.pfRules, encoding: .utf8)
    let changed = previous.map { $0.split(separator: "\n").dropFirst() != text.split(separator: "\n").dropFirst() } ?? true
    let expectsRules = !denied.isEmpty || (ksEnabled && !ifs.isEmpty && (cfg.mode == .fullSystem || !blocked.isEmpty))
    let needsReload = changed || !pfIsEnabled() || (expectsRules && !pfAnchorHasRules())
    var pfOK = true
    if needsReload {
        do {
            try text.write(toFile: BIR.pfRules, atomically: true, encoding: .utf8)
            chmod(BIR.pfRules, 0o644)
        } catch { errors.append("Cannot write pf rules: \(error)") }
        let load = pfctl(["-a", BIR.pfAnchor, "-f", BIR.pfRules])
        if !load.ok {
            pfOK = false
            errors.append("pfctl rejected the rules: \(load.combined)")
            log("firewall load failed: \(load.combined)")
        } else if expectsRules && !pfAnchorHasRules() {
            pfOK = false
            errors.append("pfctl did not retain rules in \(BIR.pfAnchor)")
            log("firewall load failed: \(BIR.pfAnchor) is empty after reload")
        } else if changed {
            var parts: [String] = []
            if !denied.isEmpty { parts.append("block list \(denied.count) ranges") }
            if ksEnabled { parts.append("kill switch \(cfg.mode.rawValue) on \(ifs.joined(separator: ", "))") }
            log("firewall loaded: \(parts.joined(separator: "; "))")
        } else {
            log("firewall reloaded into \(BIR.pfAnchor) (kernel state was cleared)")
        }
    }
    let enabled = pfOK && ensurePFEnabled()
    if !enabled { errors.append("pf could not be enabled") }
    let ks = ksEnabled ? KillSwitchStatus(active: pfOK, mode: cfg.mode, interfaces: ifs, blocked: blocked, allowed: allowed,
                                          dnsServers: dns, learnedServers: learned, pfEnabled: enabled, errors: errors) : nil
    let bl = denyValues.isEmpty ? nil : BlockListStatus(active: pfOK && enabled && !denied.isEmpty, denied: denied,
                                                        errors: denyErrors + (pfOK ? [] : errors))
    return (ks, bl)
}

// MARK: - Per-domain DNS (/etc/resolver)

/// Resolver file that makes every lookup for a blocked domain and its subdomains fail immediately
/// (a closed port on loopback), so names like www.example.com or uk.example.com are blocked too.
let blockedResolverContent = BIR.resolverMarker + " (block list)\nnameserver 127.0.0.1\nport 1\ntimeout 1\n"

func applyResolvers(_ resolvers: [DomainResolver], blockedDomains: [String] = []) -> ResolverStatus {
    var errors: [String] = []
    var active: [String] = []
    var changed = false
    let fm = FileManager.default
    if !resolvers.isEmpty || !blockedDomains.isEmpty { try? fm.createDirectory(atPath: BIR.resolverDir, withIntermediateDirectories: true) }
    var wanted: [String: String] = [:]
    for r in resolvers where r.enabled {
        if let e = r.validationError { errors.append(e); continue }
        let name = r.domain.lowercased()
        guard !name.contains("/"), !name.hasPrefix(".") else { continue }
        wanted[name] = r.fileContent
    }
    for d in blockedDomains {
        let name = d.lowercased()
        guard Validation.isDomain(name) else { continue }
        if wanted[name] != nil {
            errors.append("\(name) is both blocked and has its own name servers; the name servers win")
            continue
        }
        wanted[name] = blockedResolverContent
    }
    for (name, content) in wanted {
        let path = BIR.resolverDir + "/" + name
        let existing = try? String(contentsOfFile: path, encoding: .utf8)
        if let existing, !existing.hasPrefix(BIR.resolverMarker) {
            errors.append("\(path) exists and was not created by BlueIPRouter; left unchanged")
            continue
        }
        if existing != content {
            do {
                try content.write(toFile: path, atomically: true, encoding: .utf8)
                chmod(path, 0o644)
                changed = true
                log("resolver \(name) -> \(content.split(separator: "\n").dropFirst().joined(separator: ", "))")
            } catch { errors.append("Cannot write \(path): \(error.localizedDescription)") }
        }
        active.append(name)
    }
    for entry in ResolverFiles.list() where entry.managed && wanted[entry.domain] == nil {
        try? fm.removeItem(atPath: BIR.resolverDir + "/" + entry.domain)
        changed = true
        log("resolver \(entry.domain) removed")
    }
    if changed {
        _ = Shell.run("/usr/bin/dscacheutil", ["-flushcache"], timeout: 5)
        _ = Shell.run("/usr/bin/killall", ["-HUP", "mDNSResponder"], timeout: 5)
    }
    return ResolverStatus(active: active.sorted(), errors: errors)
}

// MARK: - Events and triggers

func recordEvents(_ new: [BIREvent]) {
    guard !new.isEmpty else { return }
    var all = BIRJSON.load([BIREvent].self, from: BIR.events) ?? []
    all.append(contentsOf: new)
    if all.count > 200 { all.removeFirst(all.count - 200) }
    try? BIRJSON.save(all, to: BIR.events)
    for e in new { log("event: \(e.title)\(e.detail.isEmpty ? "" : " — \(e.detail)")") }
}

/// Compares the network with the last pass, records events and runs matching triggers.
func detectEvents(config: AutomationConfig, runtime: inout RuntimeState, firstRun: Bool,
                  interfaces: [InterfaceSnapshot], table: [RouteEntry]) -> [BIREvent] {
    let tunnels = NetworkFacts.fullTunnelInterfaces(routes: table)
    let tunnelUp = !tunnels.isEmpty
    let states = NetworkFacts.watchedInterfaceStates(interfaces)
    let egress = RouteQuery.lookup("1.1.1.1")?.interface
    let network = NetworkFingerprint.current(interfaces: interfaces)
    defer {
        runtime.tunnelUp = tunnelUp
        runtime.interfacesUp = states
        runtime.egress = egress
        runtime.network = network
    }
    guard !firstRun else { return [] }

    var fired: [(TriggerEvent, String)] = []
    if tunnelUp != runtime.tunnelUp {
        fired.append((tunnelUp ? .tunnelUp : .tunnelDown, tunnelUp ? "on \(tunnels.joined(separator: ", "))" : ""))
    }
    for (name, up) in states where (runtime.interfacesUp[name] ?? false) != up {
        fired.append((up ? .interfaceUp(name) : .interfaceDown(name), ""))
    }
    for (name, wasUp) in runtime.interfacesUp where wasUp && states[name] == nil {
        fired.append((.interfaceDown(name), ""))
    }
    if egress != runtime.egress {
        fired.append((.egressChanged, "\(runtime.egress ?? "none") → \(egress ?? "none")"))
    }
    if network != runtime.network, network?.routerMAC != runtime.network?.routerMAC || network?.routerIP != runtime.network?.routerIP {
        fired.append((.networkChanged, network?.label ?? "no network"))
    }

    var events: [BIREvent] = []
    for (event, detail) in fired {
        let matching = config.triggers.filter { $0.enabled && $0.event == event }
        var notes: [String] = []
        for t in matching {
            for action in t.actions {
                switch action {
                case .activateProfile(let id):
                    runtime.profileOverride = id
                    runtime.profileCleared = nil
                    notes.append("profile → \(config.profiles.first { $0.id == id }?.name ?? "?")")
                case .clearProfile:
                    runtime.profileOverride = nil
                    runtime.profileCleared = true
                    notes.append("profile cleared")
                case .killSwitchOn: runtime.killSwitchOverride = true; notes.append("kill switch on")
                case .killSwitchOff: runtime.killSwitchOverride = false; notes.append("kill switch off")
                case .killSwitchAuto: runtime.killSwitchOverride = nil; notes.append("kill switch back to its setting")
                case .learnVPNServers:
                    let learned = learnVPNServers()
                    notes.append("\(learned.count) VPN servers known")
                }
            }
        }
        let triggerNames = matching.map(\.name)
        let fullDetail = ([detail] + (triggerNames.isEmpty ? [] : ["triggers: " + triggerNames.joined(separator: ", ")]) + notes)
            .filter { !$0.isEmpty }.joined(separator: " · ")
        events.append(BIREvent(kind: event.kind, title: event.label, detail: fullDetail, notify: matching.contains { $0.notify }))
    }
    return events
}

// MARK: - Apply

func apply(trigger: String) {
    ensureDirs()
    let automation = BIRJSON.load(AutomationConfig.self, from: BIR.automationConfig) ?? AutomationConfig()
    let loadedRuntime = BIRJSON.load(RuntimeState.self, from: BIR.runtimeState)
    var runtime = loadedRuntime ?? RuntimeState()
    let interfaces = InterfaceInventory.snapshot()
    let table = RouteQuery.table(family: "inet")
    var events = detectEvents(config: automation, runtime: &runtime, firstRun: loadedRuntime == nil, interfaces: interfaces, table: table)

    // Profile: trigger override > network match > manual choice.
    let chosen = runtime.profileCleared == true
        ? (profile: RoutingProfile?.none, reason: "cleared by a trigger")
        : automation.effectiveProfile(override: runtime.profileOverride, network: runtime.network)
    let profile = chosen.profile
    if profile?.id != runtime.activeProfileID, loadedRuntime != nil {
        events.append(BIREvent(kind: "profileChanged", title: "Profile: \(profile?.name ?? "none")", detail: chosen.reason))
    }
    runtime.activeProfileID = profile?.id

    let allRules = loadRules()
    let rules = allRules.map { rule -> RouteRule in
        var r = rule
        if let profile, !profile.ruleIDs.contains(rule.id) { r.enabled = false }
        return r
    }

    var cache = BIRJSON.load([String: [String]].self, from: BIR.dnsCache) ?? [:]
    let previous = BIRJSON.load([ManagedRoute].self, from: BIR.appliedState) ?? []

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
        _ = removeRoute(old, reason: "no longer in any active rule")
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
    for rule in allRules {
        guard var st = statuses[rule.id] else { continue }
        if rule.enabled, let profile, !profile.ruleIDs.contains(rule.id) {
            st.messages.append("Not part of profile “\(profile.name)”")
        }
        st.finalize()
        ordered.append(st)
    }

    // 3. Kill switch (pf): trigger override > profile > its own setting.
    let ksOverride = runtime.killSwitchOverride ?? profile?.killSwitch
    let firewall = applyFirewall(routes: plan.routes, interfaces: interfaces, cache: &cache, enabledOverride: ksOverride,
                                 blockEntries: automation.blocked)
    let ks = firewall.killSwitch
    let armed = ks?.active == true
    if let was = runtime.killSwitchArmed, was != armed {
        events.append(BIREvent(kind: armed ? "killSwitchArmed" : "killSwitchDisarmed", title: armed ? "Kill switch armed" : "Kill switch off"))
    }
    runtime.killSwitchArmed = armed

    // 4. Per-domain DNS.
    let blockedDomains = automation.blocked.filter(\.enabled).compactMap { e -> String? in
        if case .domain(let d)? = KSEntry.parse(e.value) { return d }
        return nil
    }
    let resolvers = applyResolvers(automation.resolvers, blockedDomains: blockedDomains)

    var status = HelperStatus(updatedAt: Date(), trigger: trigger, rules: ordered, installedRoutes: installed, killSwitch: ks)
    status.profile = ActiveProfileInfo(id: profile?.id, name: profile?.name, reason: chosen.reason)
    status.resolvers = resolvers
    status.blockList = firewall.blockList
    status.tunnelUp = runtime.tunnelUp
    for st in ordered where st.state == .failed || st.state == .partial {
        if !(previousStatus?.rules.contains { $0.ruleID == st.ruleID && $0.state == st.state } ?? false) {
            let name = allRules.first { $0.id == st.ruleID }?.name ?? "rule"
            events.append(BIREvent(kind: "ruleFailed", title: "Rule “\(name)” \(st.state == .failed ? "failed" : "is only partly applied")",
                                   detail: st.messages.first ?? ""))
        }
    }

    do {
        try BIRJSON.save(installed, to: BIR.appliedState)
        try BIRJSON.save(status, to: BIR.status)
        try BIRJSON.save(cache, to: BIR.dnsCache)
        try BIRJSON.save(runtime, to: BIR.runtimeState)
    } catch {
        fail("could not write state: \(error)")
    }
    recordEvents(events)
    if trigger != "daemon" && trigger != "timer" {
        let waiting = installed.count - installed.filter { desiredKeys.contains($0.key) }.count
        log("apply (\(trigger)): \(installed.count - waiting)/\(plan.routes.count) routes in place\(waiting > 0 ? ", \(waiting) waiting for their interface" : ""); profile \(profile?.name ?? "none"); kill switch \(armed ? "on" : "off")")
    }
    print("ok: \(installed.count)/\(plan.routes.count) routes; profile \(profile?.name ?? "none"); kill switch \(armed ? "on" : "off")")
}

var previousStatus: HelperStatus? { BIRJSON.load(HelperStatus.self, from: BIR.status) }

// MARK: - Daemon

/// Coalesces bursts of network notifications into one pass.
final class Scheduler {
    static let shared = Scheduler()
    private var generation = 0

    func schedule(_ reason: String, after delay: Double = 2) {
        generation += 1
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard g == self.generation else { return }
            withLock { apply(trigger: reason) }
        }
    }
}

func runDaemon(interval: Int) {
    log("daemon started (version \(BIR.version), every \(interval)s and on network changes)")
    withLock { apply(trigger: "boot") }

    let callback: SCDynamicStoreCallBack = { _, _, _ in
        DispatchQueue.main.async { Scheduler.shared.schedule("network change") }
    }
    if let store = SCDynamicStoreCreate(nil, "com.blueiprouter.helper" as CFString, callback, nil) {
        let patterns = ["State:/Network/Global/IPv4", "State:/Network/Global/DNS",
                        "State:/Network/Interface/.*/IPv4", "State:/Network/Interface/.*/Link"] as CFArray
        SCDynamicStoreSetNotificationKeys(store, nil, patterns)
        if let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    } else {
        log("could not watch network changes; falling back to the timer only")
    }
    let timer = Timer(timeInterval: TimeInterval(max(15, interval)), repeats: true) { _ in
        Scheduler.shared.schedule("timer", after: 0)
    }
    RunLoop.main.add(timer, forMode: .default)
    // Re-read rule files promptly after the app applies (it runs `apply` itself too; this keeps state fresh).
    signal(SIGHUP, SIG_IGN)
    let hup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
    hup.setEventHandler { Scheduler.shared.schedule("reload", after: 0) }
    hup.resume()
    CFRunLoopRun()
}

func removeAll() {
    let previous = BIRJSON.load([ManagedRoute].self, from: BIR.appliedState) ?? []
    var removed = 0
    for old in previous where removeRoute(old, reason: "remove-all") { removed += 1 }
    killSwitchOff(reason: "remove-all")
    _ = applyResolvers([])
    try? FileManager.default.removeItem(atPath: BIR.runtimeState)
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
case "daemon":
    guard geteuid() == 0 else { fail("must run as root", code: 77) }
    var interval = 60
    if let i = args.firstIndex(of: "--interval"), i + 1 < args.count, let v = Int(args[i + 1]) { interval = v }
    runDaemon(interval: interval)
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
    print("usage: blueiprouter-helper daemon [--interval s] | apply [--trigger name] | remove-all | killswitch-off | detect-vpn | plan <file> | version")
    exit(64)
}
