import AppKit
import BlueIPRouterCore
import Foundation
import Observation
import UniformTypeIdentifiers

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard, connections, traffic, rules, profiles, killSwitch, blockList, routes, pathCheck, dns, adapters, automation, service, backup, activity, about

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .connections: return "Connections"
        case .traffic: return "Traffic"
        case .profiles: return "Profiles"
        case .blockList: return "Block List"
        case .dns: return "DNS"
        case .automation: return "Automation"
        case .rules: return "Routing Rules"
        case .killSwitch: return "Kill Switch"
        case .routes: return "Routing Table"
        case .pathCheck: return "Path Check"
        case .adapters: return "Network Adapters"
        case .service: return "Persistence"
        case .backup: return "Backup & Restore"
        case .activity: return "Activity Log"
        case .about: return "About"
        }
    }
    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .connections: return "point.3.filled.connected.trianglepath.dotted"
        case .traffic: return "chart.xyaxis.line"
        case .profiles: return "square.stack.3d.up"
        case .blockList: return "nosign"
        case .dns: return "server.rack"
        case .automation: return "bolt.badge.automatic"
        case .rules: return "arrow.triangle.branch"
        case .killSwitch: return "hand.raised.square.on.square"
        case .routes: return "tablecells"
        case .pathCheck: return "point.topleft.down.to.point.bottomright.curvepath"
        case .adapters: return "network"
        case .service: return "clock.arrow.circlepath"
        case .backup: return "externaldrive.badge.timemachine"
        case .activity: return "list.bullet.rectangle"
        case .about: return "info.circle"
        }
    }
}

struct ActivityEntry: Identifiable, Hashable {
    let id = UUID()
    let date = Date()
    var title: String
    var ok: Bool
    var detail: String
}

struct PendingChange: Identifiable, Hashable {
    enum Kind: String { case added = "Added", removed = "Removed", modified = "Modified" }
    var kind: Kind
    var rule: RouteRule
    var id: UUID { rule.id }
}

struct ResetOptions {
    var backupFirst = true
    var removeRoutes = true
    var deleteRules = true
    var uninstallService = false
    var resetAliasesAndSettings = false
}

struct ImportCandidate: Identifiable, Hashable {
    var id: String
    var destination: String
    var via: RouteVia
    var entry: RouteEntry
}

struct AlertInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct TrafficRate: Hashable {
    var rx: Double
    var tx: Double
}

@Observable
@MainActor
final class AppModel {
    var workspace: Workspace { didSet { Storage.save(workspace) } }
    var net = NetworkSnapshot()
    var rates: [String: TrafficRate] = [:]
    var publicIPs: [PublicIPResult] = []
    var publicIPLoading = false
    var publicIPUpdated: Date?
    private var geoCache: [String: IPIdentity] = [:]
    var activity: [ActivityEntry] = []
    var busy: String?
    var alert: AlertInfo?
    var selection: SidebarItem? = .dashboard
    var editingRule: RouteRule?
    var pathQuery = ""
    var pathResult: PathCheckResult?
    var pathChecking = false
    let traceroute = TracerouteRunner()
    var backups: [BackupFile] = []
    var helperLog = ""
    var hasScanned = false
    var showImport = false
    var showSetup = false
    var openAtLogin = LoginItem.isEnabled
    var loginItemNeedsApproval = LoginItem.needsApproval

    var traffic = TrafficHistory.load()
    var availableUpdate: AvailableUpdate?
    var checkingForUpdates = false
    private var lastEgress: String?
    private var lastPublicRefresh = Date.distantPast
    private var lastBytes: [String: (UInt64, UInt64)] = [:]
    private var lastSample: Date?
    private var loop: Task<Void, Never>?

    init() {
        if let saved = Storage.loadWorkspace() {
            workspace = saved
        } else {
            workspace = Workspace()
            Storage.save(workspace)
        }
    }

    // MARK: Lifecycle

    func start() async {
        guard loop == nil else { return }
        backups = Storage.listBackups()
        await refresh()
        if !workspace.setupCompleted { showSetup = true }
        Task { await refreshPublicIPs() }
        Task {
            _ = await Notifier.requestAuthorization()
            await checkForUpdates(manual: false)
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = self?.workspace.settings.refreshSeconds ?? 5
                try? await Task.sleep(for: .seconds(max(2, seconds)))
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        let rules = workspace.rules
        let snap = await Task.detached(priority: .userInitiated) { NetworkScanner.scan(rules: rules) }.value
        updateRates(snap)
        net = snap
        processEvents(snap.events)
        // Re-check public IPs when the egress interface changes, and every 5 minutes.
        let egress = snap.internetRoute?.interface
        if (lastEgress != nil && egress != lastEgress) || Date().timeIntervalSince(lastPublicRefresh) > 300 {
            Task { await refreshPublicIPs() }
        }
        lastEgress = egress
        openAtLogin = LoginItem.isEnabled
        loginItemNeedsApproval = LoginItem.needsApproval
        hasScanned = true
    }

    private func updateRates(_ snap: NetworkSnapshot) {
        let now = snap.takenAt
        if let last = lastSample {
            let dt = now.timeIntervalSince(last)
            if dt > 0.5 {
                for i in snap.interfaces {
                    guard let prev = lastBytes[i.name] else { continue }
                    func delta(_ new: UInt64, _ old: UInt64) -> Double {
                        Double(new >= old ? new - old : new + (UInt64(UInt32.max) - old))
                    }
                    rates[i.name] = TrafficRate(rx: delta(i.snapshot.rxBytes, prev.0) / dt, tx: delta(i.snapshot.txBytes, prev.1) / dt)
                }
                let tracked = rates.filter { name, _ in snap.interfaces.contains { $0.name == name && $0.snapshot.isUp && !$0.snapshot.isLoopback } }
                if traffic.add(rates: tracked, seconds: dt, at: now) { traffic.save() }
            }
        }
        lastSample = now
        lastBytes = Dictionary(uniqueKeysWithValues: snap.interfaces.map { ($0.name, ($0.snapshot.rxBytes, $0.snapshot.txBytes)) })
    }

    func refreshPublicIPs() async {
        guard !publicIPLoading else { return }
        publicIPLoading = true
        defer { publicIPLoading = false }
        let provider = workspace.settings.geoProvider
        let available = await Probes.availableInterfaces()
        let aliases = workspace.aliases
        let candidates = net.interfaces.filter { $0.isActive && $0.ipv4 != nil && ($0.kind.isPhysical || $0.kind.isVPN) }
        let egress = net.internetRoute?.interface

        var results: [PublicIPResult] = []
        var ips = Set<String>()
        await withTaskGroup(of: (PublicIPResult, [String]).self) { group in
            group.addTask { await Probes.probePath(id: "default", title: "System default path", interface: nil) }
            for c in candidates {
                let title = "\(interfaceDisplayName(c.name, info: c, aliases: aliases)) (\(c.name))"
                if c.isFullTunnel || c.name == egress {
                    results.append(PublicIPResult(id: c.name, title: title, interface: c.name,
                                                  v4Error: "Carries the system default path (see above)"))
                } else if let nw = available.first(where: { $0.name == c.name }) {
                    group.addTask { await Probes.probePath(id: c.name, title: title, interface: nw) }
                } else {
                    results.append(PublicIPResult(id: c.name, title: title, interface: c.name,
                                                  v4Error: "macOS does not let apps pin traffic to this interface"))
                }
            }
            for await (r, found) in group {
                results.append(r)
                ips.formUnion(found)
            }
        }
        // Location/ISP for every distinct address, cached per IP.
        await withTaskGroup(of: (String, IPIdentity?).self) { group in
            for ip in ips where geoCache[ip] == nil {
                group.addTask { (ip, await Probes.geolocate(ip, preferred: provider)) }
            }
            for await (ip, id) in group { if let id { geoCache[ip] = id } }
        }
        for i in results.indices {
            if let ip = results[i].v4?.ip, let g = geoCache[ip] { results[i].v4 = g }
            if let ip = results[i].v6?.ip, let g = geoCache[ip] { results[i].v6 = g }
        }
        let before = publicIPs.first { $0.id == "default" }?.v4
        publicIPs = results.sorted { a, b in a.id == "default" ? true : (b.id == "default" ? false : a.id < b.id) }
        publicIPUpdated = Date()
        lastPublicRefresh = Date()
        if let before, let after = publicIPs.first(where: { $0.id == "default" })?.v4, after.ip != before.ip,
           workspace.settings.notifications.publicIP {
            let country = before.country != after.country ? " — country \(before.country ?? "?") → \(after.country ?? "?")" : ""
            Notifier.post("Public IP changed\(after.flag.map { " " + $0 } ?? "")",
                          "\(before.ip) → \(after.ip)\(country)\n\([after.location, after.org ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))")
            log("Public IP changed", ok: true, "\(before.ip) → \(after.ip)")
        }
    }

    // MARK: Notifications & updates

    /// Notifies about helper events that are new since the last look.
    private func processEvents(_ events: [BIREvent]) {
        let key = "lastNotifiedEventDate"
        guard let newest = events.last?.date else { return }
        guard let seen = UserDefaults.standard.object(forKey: key) as? Date else {
            UserDefaults.standard.set(newest, forKey: key)
            return
        }
        let fresh = events.filter { $0.date > seen }
        guard !fresh.isEmpty else { return }
        UserDefaults.standard.set(newest, forKey: key)
        let prefs = workspace.settings.notifications
        for e in fresh.suffix(5) where prefs.wants(e) {
            Notifier.post(e.title, e.detail, id: e.id.uuidString)
        }
    }

    func checkForUpdates(manual: Bool) async {
        let key = "lastUpdateCheck"
        if !manual {
            guard workspace.settings.checkForUpdates else { return }
            if let last = UserDefaults.standard.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 86400 {
                return
            }
        }
        checkingForUpdates = true
        defer { checkingForUpdates = false }
        do {
            let update = try await UpdateChecker.latest()
            UserDefaults.standard.set(Date(), forKey: key)
            availableUpdate = update
            if let update {
                if !manual && workspace.settings.notifications.updates {
                    Notifier.post("BlueIPRouter \(update.version) is available", "Open the app to download it.")
                }
                log("Update available: \(update.version)", ok: true)
            } else if manual {
                alert = AlertInfo(title: "You're up to date", message: "BlueIPRouter \(BIR.version) is the latest version.")
            }
        } catch {
            if manual { showError("Could not check for updates", error.localizedDescription) }
        }
    }

    /// Adds an address, network or domain to the block list (applied with the next Apply).
    func block(_ value: String, note: String = "") {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard KSEntry.parse(v) != nil else { return }
        if let i = workspace.automation.blocked.firstIndex(where: { $0.value == v }) {
            workspace.automation.blocked[i].enabled = true
        } else {
            workspace.automation.blocked.append(BlockEntry(value: v, note: note))
        }
        log("Added \(v) to the block list", ok: true, "Press Apply to enforce it.")
    }

    func blockAndApply(_ value: String, note: String = "") async {
        block(value, note: note)
        await apply(title: "block \(value)")
    }

    func describe(_ action: TriggerAction) -> String {
        switch action {
        case .activateProfile(let id): return "switch to “\(workspace.automation.profiles.first { $0.id == id }?.name ?? "deleted profile")”"
        case .clearProfile: return "clear the profile"
        case .killSwitchOn: return "kill switch on"
        case .killSwitchOff: return "kill switch off"
        case .killSwitchAuto: return "kill switch to its setting"
        case .learnVPNServers: return "re-learn VPN servers"
        }
    }

    // MARK: Derived state

    var pendingChanges: [PendingChange] {
        var changes: [PendingChange] = []
        let applied = Dictionary(net.appliedRules.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let draft = Dictionary(workspace.rules.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for r in workspace.rules {
            if let a = applied[r.id] {
                if !a.sameContent(as: r) { changes.append(PendingChange(kind: .modified, rule: r)) }
            } else {
                changes.append(PendingChange(kind: .added, rule: r))
            }
        }
        for a in net.appliedRules where draft[a.id] == nil { changes.append(PendingChange(kind: .removed, rule: a)) }
        return changes
    }

    var killSwitchPending: Bool {
        guard let applied = net.appliedKillSwitch else { return workspace.killSwitch.enabled }
        return applied != workspace.killSwitch
    }

    /// Rules not yet applied whose routes nevertheless already exist (added by hand or another tool).
    var liveButUnmanaged: [RouteRule] {
        let pending = Set(pendingChanges.filter { $0.kind != .removed }.map(\.id))
        return workspace.rules.filter { pending.contains($0.id) && net.liveRoutes[$0.id]?.allLive == true }
    }

    var automationPending: Bool {
        guard let applied = net.appliedAutomation else { return !workspace.automation.isEmpty }
        return applied != workspace.automation
    }

    var pendingCount: Int { pendingChanges.count + (killSwitchPending ? 1 : 0) + (automationPending ? 1 : 0) }

    /// The installed LaunchDaemon predates the current app (e.g. the old timer-only service).
    var daemonOutdated: Bool {
        if net.service.helperInstalled, let v = net.service.helperVersion, v != BIR.version { return true }
        guard net.service.daemonInstalled, let installed = net.installedDaemonPlist else { return false }
        return installed != Privileged.daemonPlist(interval: workspace.settings.serviceIntervalSeconds)
    }
    var hasPending: Bool { pendingCount > 0 }

    /// A full-tunnel VPN is currently up.
    var fullTunnel: InterfaceInfo? { net.interfaces.first { $0.isFullTunnel && $0.snapshot.isUp } }

    func status(for rule: RouteRule) -> RuleStatus? { net.helperStatus?.rules.first { $0.ruleID == rule.id } }

    func interface(_ name: String?) -> InterfaceInfo? {
        guard let name else { return nil }
        return net.interfaces.first { $0.name == name }
    }

    func displayName(_ name: String) -> String { interfaceDisplayName(name, info: interface(name), aliases: workspace.aliases) }

    func describe(_ via: RouteVia) -> String {
        switch via {
        case .interfaceRouter(let i):
            let r = interface(i)?.router.map { " → \($0)" } ?? ""
            return "\(displayName(i)) (\(i)) router\(r)"
        case .interfaceDirect(let i): return "Direct on \(displayName(i)) (\(i))"
        case .gateway(let g): return "Gateway \(g)"
        }
    }

    func owner(of entry: RouteEntry) -> String? {
        guard let cidr = entry.cidr else { return nil }
        if let m = net.helperStatus?.installedRoutes.first(where: { $0.destination == cidr.address && $0.prefix == cidr.prefix }) {
            return "Rule: " + (workspace.rules.first { $0.id == m.ruleID }?.name ?? "deleted")
        }
        if interface(entry.netif)?.isFullTunnel == true, NetworkScanner.catchAllDestinations.contains(entry.destination) {
            return "Tunnel catch-all"
        }
        return nil
    }

    /// The physical LAN connection (Wi-Fi/Ethernet) even when a VPN is the primary interface.
    var localInterface: InterfaceInfo? {
        if let p = interface(net.primaryInterface), p.kind.isPhysical, p.ipv4 != nil { return p }
        return net.interfaces.first { $0.kind.isPhysical && $0.isActive && $0.router != nil }
            ?? net.interfaces.first { $0.kind.isPhysical && $0.ipv4 != nil }
    }

    var visibleInterfaces: [InterfaceInfo] {
        net.interfaces.filter { workspace.settings.showSystemInterfaces || !$0.isSystemNoise || $0.name == net.primaryInterface }
    }

    // MARK: Logging & alerts

    func log(_ title: String, ok: Bool, _ detail: String = "") {
        activity.insert(ActivityEntry(title: title, ok: ok, detail: detail.trimmingCharacters(in: .whitespacesAndNewlines)), at: 0)
        if activity.count > 500 { activity.removeLast(activity.count - 500) }
    }

    func showError(_ title: String, _ message: String) { alert = AlertInfo(title: title, message: message) }

    @discardableResult
    private func runPrivileged(_ title: String, _ commands: [String], stopOnError: Bool = true) async -> Bool {
        busy = title
        defer { busy = nil }
        do {
            let out = try Privileged.run(commands, prompt: "BlueIPRouter wants to: \(title).", stopOnError: stopOnError)
            log(title, ok: true, out)
            await refresh()
            return true
        } catch PrivilegedError.cancelled {
            log(title, ok: false, "Cancelled by user")
            return false
        } catch {
            log(title, ok: false, error.localizedDescription)
            showError(title, error.localizedDescription)
            await refresh()
            return false
        }
    }

    // MARK: Rules

    func newRule(destination: String? = nil) {
        let lan = localInterface?.name ?? net.primaryInterface ?? net.interfaces.first { $0.isActive && !$0.snapshot.isLoopback }?.name ?? ""
        editingRule = RouteRule(name: "", destinations: destination.map { [$0] } ?? [], via: .interfaceRouter(lan))
    }

    func upsert(_ rule: RouteRule) {
        var r = rule
        r.updatedAt = Date()
        if let i = workspace.rules.firstIndex(where: { $0.id == r.id }) { workspace.rules[i] = r } else { workspace.rules.append(r) }
    }

    func deleteRules(_ ids: Set<UUID>) { workspace.rules.removeAll { ids.contains($0.id) } }

    func duplicate(_ rule: RouteRule) {
        var copy = rule
        copy.id = UUID()
        copy.name += " copy"
        workspace.rules.append(copy)
    }

    func setEnabled(_ id: UUID, _ value: Bool) {
        if let i = workspace.rules.firstIndex(where: { $0.id == id }) { workspace.rules[i].enabled = value }
    }

    func setPersistent(_ id: UUID, _ value: Bool) {
        if let i = workspace.rules.firstIndex(where: { $0.id == id }) { workspace.rules[i].persistent = value }
    }

    func discardChanges() {
        workspace.rules = net.appliedRules
        if let ks = net.appliedKillSwitch { workspace.killSwitch = ks } else { workspace.killSwitch.enabled = false }
        workspace.automation = net.appliedAutomation ?? AutomationConfig()
        log("Discarded pending changes", ok: true)
    }

    // MARK: Apply

    func apply(extraCommands: [String] = [], title: String = "apply routing changes") async {
        let invalid = workspace.rules.filter { !$0.validationErrors.isEmpty }
        if let bad = invalid.first {
            showError("Rule “\(bad.name.isEmpty ? "Untitled" : bad.name)” is invalid", bad.validationErrors.joined(separator: "\n"))
            return
        }
        if workspace.killSwitch.enabled, let e = workspace.killSwitch.validationErrors.first {
            showError("Kill switch settings are invalid", e)
            return
        }
        do {
            let staging = Storage.stagingDir
            let k = staging.appendingPathComponent("killswitch.json").path
            let au = staging.appendingPathComponent("automation.json").path
            try BIRJSON.save(workspace.automation, to: au)
            try BIRJSON.save(workspace.killSwitch, to: k)
            let p = staging.appendingPathComponent("rules.json").path
            let s = staging.appendingPathComponent("session-rules.json").path
            try BIRJSON.save(HelperConfig(rules: workspace.rules.filter(\.persistent)), to: p)
            try BIRJSON.save(HelperConfig(rules: workspace.rules.filter { !$0.persistent }), to: s)
            var cmds = try Privileged.installHelperCommands()
            cmds += [
                "install -o root -g wheel -m 644 \(shq(p)) \(shq(BIR.persistentRules))",
                "install -o root -g wheel -m 644 \(shq(s)) \(shq(BIR.sessionRules))",
                "install -o root -g wheel -m 644 \(shq(k)) \(shq(BIR.killSwitchConfig))",
                "install -o root -g wheel -m 644 \(shq(au)) \(shq(BIR.automationConfig))",
            ]
            cmds += extraCommands
            cmds.append("\(shq(BIR.helperBinary)) apply --trigger app")
            // Persistent rules and the kill switch only survive reboots with the background service,
            // so the first Apply that needs it installs it in the same (single) admin prompt.
            let needsService = workspace.rules.contains { $0.enabled && $0.persistent } || workspace.killSwitch.enabled
                || !workspace.automation.isEmpty
            if (needsService && !net.service.daemonInstalled) || daemonOutdated {
                cmds += try Privileged.installDaemonCommands(interval: workspace.settings.serviceIntervalSeconds)
            } else if net.service.daemonInstalled {
                // Restart the long-running service so it runs the helper binary just installed.
                cmds.append("launchctl kickstart -k system/\(BIR.helperLabel)")
            }
            if await runPrivileged(title, cmds) {
                autoBackup("Applied")
                if let failing = net.helperStatus?.rules.filter({ $0.state == .failed || $0.state == .partial }), !failing.isEmpty {
                    let names = failing.compactMap { st in workspace.rules.first { $0.id == st.ruleID }?.name }
                    showError("Some rules were not fully applied", names.joined(separator: ", ") + "\nOpen Routing Rules for details.")
                }
            }
        } catch {
            showError("Could not apply", error.localizedDescription)
        }
    }

    func runServiceNow() async {
        guard net.service.helperInstalled else { await apply(); return }
        await runPrivileged("re-check all routes now", ["\(shq(BIR.helperBinary)) apply --trigger manual"])
    }

    // MARK: Persistence service

    func setService(enabled: Bool) async {
        do {
            if enabled {
                let cmds = try Privileged.installHelperCommands() + Privileged.installDaemonCommands(interval: workspace.settings.serviceIntervalSeconds)
                await runPrivileged("turn on the background route service", cmds)
            } else {
                await runPrivileged("turn off the background route service", Privileged.removeDaemonCommands)
            }
        } catch {
            showError("Background service", error.localizedDescription)
        }
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
            log(enabled ? "Turned on Open at Login" : "Turned off Open at Login", ok: true)
        } catch {
            showError("Open at Login", error.localizedDescription)
        }
        openAtLogin = LoginItem.isEnabled
        loginItemNeedsApproval = LoginItem.needsApproval
        if loginItemNeedsApproval { LoginItem.openSystemSettings() }
    }

    /// Speed of the interface that carries internet traffic (the VPN tunnel when it is up).
    var internetRate: TrafficRate {
        guard let i = net.internetRoute?.interface, let r = rates[i] else { return TrafficRate(rx: 0, tx: 0) }
        return r
    }

    var backgroundServiceRunning: Bool { net.service.daemonInstalled && net.service.loaded }

    func loadHelperLog() { helperLog = NetworkScanner.tailLog(BIR.log) }

    // MARK: Import existing static routes

    /// Static routes added outside BlueIPRouter (by hand, scripts or older tools) that can become rules.
    var importCandidates: [ImportCandidate] {
        net.routesV4.compactMap { e in
            // Routes macOS creates for a connected interface (its subnet, its own address, the router,
            // link-local) point at "link#N", are cloning or scoped. They are not user routes.
            guard e.isStatic, !e.isLinkLayer, !e.isDefault, !e.isScoped, owner(of: e) == nil, let cidr = e.cidr,
                  !e.gateway.hasPrefix("link#"), !e.flags.contains("C"), !e.flags.contains("c"),
                  !systemAddresses.contains(cidr.address),
                  !IPv4.contains(network: "169.254.0.0", prefix: 16, ip: cidr.address),
                  cidr.prefix >= 8, Validation.isInterfaceName(e.netif), !e.netif.hasPrefix("lo"),
                  !IPv4.contains(network: "224.0.0.0", prefix: 4, ip: cidr.address),
                  !IPv4.contains(network: "127.0.0.0", prefix: 8, ip: cidr.address),
                  cidr.address != "255.255.255.255" else { return nil }
            let via: RouteVia
            if IPv4.isValid(e.gateway) {
                via = interface(e.netif)?.router == e.gateway ? .interfaceRouter(e.netif) : .gateway(e.gateway)
            } else {
                via = .interfaceDirect(e.netif)
            }
            let dest = cidr.prefix == 32 ? cidr.address : "\(cidr.address)/\(cidr.prefix)"
            return ImportCandidate(id: e.id, destination: dest, via: via, entry: e)
        }
    }

    /// Addresses that belong to the interfaces themselves (own IPs, point-to-point peers, routers).
    private var systemAddresses: Set<String> {
        var out = Set<String>()
        for i in net.interfaces {
            for a in i.snapshot.ipv4 {
                out.insert(a.address)
                if let p = a.peer { out.insert(p) }
            }
            if let r = i.router { out.insert(r) }
        }
        return out
    }

    /// Groups the chosen routes by next hop into new rules.
    func importRoutes(_ candidates: [ImportCandidate], persistent: Bool) {
        let groups = Dictionary(grouping: candidates, by: \.via)
        for (via, items) in groups.sorted(by: { describe($0.key) < describe($1.key) }) {
            let label: String
            switch via {
            case .interfaceRouter(let i), .interfaceDirect(let i): label = displayName(i)
            case .gateway(let g): label = g
            }
            workspace.rules.append(RouteRule(name: "Imported via \(label)", destinations: items.map(\.destination), via: via,
                                             persistent: persistent, notes: "Imported from the routing table on \(Date().formatted(date: .abbreviated, time: .omitted))"))
        }
        log("Imported \(candidates.count) static routes into \(groups.count) rules", ok: true)
        selection = .rules
    }

    /// Interfaces a kill switch should guard by default: active physical links and site VPNs (never the tunnel).
    var defaultGuardedInterfaces: [String] {
        net.interfaces.filter { ($0.kind.isPhysical || $0.kind == .ppp || $0.kind == .ipsec) && $0.isActive }.map(\.name)
    }

    // MARK: Reset

    func reset(_ o: ResetOptions) async {
        if o.backupFirst { autoBackup("Before reset") }
        var cmds: [String] = []
        if o.removeRoutes && net.service.helperInstalled { cmds.append("\(shq(BIR.helperBinary)) remove-all") }
        if o.deleteRules {
            cmds.append("rm -f \(shq(BIR.persistentRules)) \(shq(BIR.sessionRules)) \(shq(BIR.killSwitchConfig)) \(shq(BIR.learnedServers)) \(shq(BIR.automationConfig)) \(shq(BIR.runtimeState))")
        }
        if o.uninstallService {
            cmds += Privileged.removeDaemonCommands
            cmds.append("rm -f \(shq(BIR.helperBinary))")
            cmds.append("rm -rf \(shq(BIR.systemDir)) \(shq(BIR.runDir))")
        }
        var ok = true
        if !cmds.isEmpty { ok = await runPrivileged("reset routing to default", cmds, stopOnError: false) }
        guard ok else { return }
        if o.deleteRules {
            workspace.rules = []
            workspace.killSwitch = KillSwitchConfig()
            workspace.automation = AutomationConfig()
        }
        if o.resetAliasesAndSettings {
            workspace.aliases = [:]
            workspace.settings = AppSettings()
        }
        log("Reset to default", ok: true, "routes: \(o.removeRoutes), rules: \(o.deleteRules), service: \(o.uninstallService)")
    }

    // MARK: Backup & restore

    func makeBundle(reason: String) -> BackupBundle {
        BackupBundle(createdAt: Date(), appVersion: BIR.version, hostName: Host.current().localizedName ?? "Mac",
                     reason: reason, rules: workspace.rules, aliases: workspace.aliases,
                     settings: workspace.settings, routingSnapshot: net.routesV4,
                     killSwitch: workspace.killSwitch, automation: workspace.automation)
    }

    func autoBackup(_ reason: String) {
        Storage.saveAutoBackup(makeBundle(reason: reason), limit: max(1, workspace.settings.autoBackupLimit))
        backups = Storage.listBackups()
    }

    func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        panel.nameFieldStringValue = "BlueIPRouter-backup-\(f.string(from: Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Storage.write(makeBundle(reason: "Manual export"), to: url)
            log("Exported backup", ok: true, url.path)
        } catch {
            showError("Export failed", error.localizedDescription)
        }
    }

    func pickBackupFile() -> BackupBundle? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { return try Storage.readBackup(url) } catch {
            showError("Cannot read backup", error.localizedDescription)
            return nil
        }
    }

    func restore(_ bundle: BackupBundle, replace: Bool, includeSettings: Bool) {
        autoBackup("Before restore")
        if replace {
            workspace.rules = bundle.rules
        } else {
            for r in bundle.rules {
                if let i = workspace.rules.firstIndex(where: { $0.id == r.id }) { workspace.rules[i] = r } else { workspace.rules.append(r) }
            }
        }
        if let ks = bundle.killSwitch, replace || includeSettings { workspace.killSwitch = ks }
        if let au = bundle.automation, replace || includeSettings { workspace.automation = au }
        if includeSettings {
            workspace.aliases.merge(bundle.aliases) { _, new in new }
            workspace.settings = bundle.settings
        }
        log("Restored backup from \(bundle.createdAt.formatted())", ok: true, "\(bundle.rules.count) rules, \(replace ? "replaced" : "merged")")
        selection = .rules
    }

    func deleteBackup(_ file: BackupFile) {
        try? FileManager.default.removeItem(at: file.url)
        backups = Storage.listBackups()
    }

    // MARK: Kill switch

    /// Records the servers VPN cores (xray, sing-box, …) are connected to, so full-system mode allows them.
    func detectVPNServers() async {
        do {
            let cmds = try Privileged.installHelperCommands() + ["\(shq(BIR.helperBinary)) detect-vpn"]
            await runPrivileged("detect the servers your VPN is connected to", cmds)
        } catch {
            showError("Detect VPN servers", error.localizedDescription)
        }
    }

    func forgetLearnedServers() async {
        await runPrivileged("forget learned VPN servers", ["rm -f \(shq(BIR.learnedServers))"])
    }

    /// Downloads a block list's published ranges (e.g. Telegram's cidr.txt) and replaces its entries.
    func updateBlockList(_ id: UUID) async {
        guard let i = workspace.killSwitch.blockLists.firstIndex(where: { $0.id == id }),
              let source = workspace.killSwitch.blockLists[i].sourceURL, let url = URL(string: source) else { return }
        busy = "downloading \(workspace.killSwitch.blockLists[i].name) ranges"
        defer { busy = nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let entries = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { CIDR.normalize($0) != nil }
            guard !entries.isEmpty else { throw URLError(.cannotParseResponse) }
            workspace.killSwitch.blockLists[i].entries = entries
            log("Updated \(workspace.killSwitch.blockLists[i].name) ranges", ok: true, entries.joined(separator: "\n"))
        } catch {
            showError("Could not download ranges", error.localizedDescription)
        }
    }

    func turnOffKillSwitchNow() async {
        workspace.killSwitch.enabled = false
        await apply(title: "turn off the kill switch")
    }

    // MARK: Adapters

    private func validIface(_ name: String) -> Bool {
        if Validation.isInterfaceName(name) { return true }
        showError("Invalid interface", name)
        return false
    }

    func setInterface(_ name: String, up: Bool) async {
        guard validIface(name) else { return }
        await runPrivileged("\(up ? "enable" : "disable") interface \(name)", ["/sbin/ifconfig \(name) \(up ? "up" : "down")"])
    }

    func setWiFiPower(_ name: String, on: Bool) async {
        guard validIface(name) else { return }
        await runPrivileged("turn Wi-Fi \(on ? "on" : "off") (\(name))", ["/usr/sbin/networksetup -setairportpower \(name) \(on ? "on" : "off")"])
    }

    func renewDHCP(_ name: String) async {
        guard validIface(name) else { return }
        await runPrivileged("renew the DHCP lease on \(name)", ["/usr/sbin/ipconfig set \(name) DHCP"])
    }

    func setMTU(_ name: String, _ mtu: Int) async {
        guard validIface(name) else { return }
        guard (576...9000).contains(mtu) else { showError("Invalid MTU", "Use a value between 576 and 9000."); return }
        await runPrivileged("set the MTU of \(name) to \(mtu)", ["/sbin/ifconfig \(name) mtu \(mtu)"])
    }

    func setDNS(service: String, servers: [String]) async {
        let bad = servers.filter { !IPv4.isValid($0) && !Validation.isIPv6($0) }
        guard bad.isEmpty else { showError("Invalid DNS server", bad.joined(separator: ", ")); return }
        let list = servers.isEmpty ? "Empty" : servers.joined(separator: " ")
        await runPrivileged("set DNS servers for \(service)", ["/usr/sbin/networksetup -setdnsservers \(shq(service)) \(list)"])
    }

    func flushDNS() async {
        await runPrivileged("flush the DNS cache", ["/usr/bin/dscacheutil -flushcache", "/usr/bin/killall -HUP mDNSResponder"])
    }

    func setAlias(_ name: String, _ alias: String) {
        let t = alias.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { workspace.aliases.removeValue(forKey: name) } else { workspace.aliases[name] = t }
    }

    // MARK: Raw routes

    func deleteRoute(_ e: RouteEntry) async {
        let safe = e.destination.allSatisfy { $0.isHexDigit || ".:/%".contains($0) || $0.isLetter || $0.isNumber }
        guard safe, Validation.isInterfaceName(e.netif) || e.netif.isEmpty else { showError("Cannot delete", "Unexpected route format"); return }
        var cmd = "/sbin/route -n delete"
        if e.family == "inet6" { cmd += " -inet6" }
        if e.isDefault { cmd += " default" } else { cmd += (e.isHost ? " -host " : " -net ") + shq(e.destination) }
        if e.isScoped && !e.netif.isEmpty { cmd += " -ifscope \(e.netif)" }
        await runPrivileged("delete route \(e.destination) via \(e.netif)", [cmd])
    }

    func addOneOffRoute(destination: String, via: RouteVia) async {
        guard let d = Destination.parse(destination), d.kindLabel != "Domain" else {
            showError("Invalid destination", "Use an IPv4 address or CIDR network. For domains, create a rule.")
            return
        }
        if let e = via.validationError { showError("Invalid next hop", e); return }
        var cmd = "/sbin/route -n add "
        switch d {
        case .host(let ip): cmd += "-host \(ip)"
        case .network(let a, let p): cmd += "-net \(a)/\(p)"
        case .domain: return
        }
        switch via {
        case .gateway(let g): cmd += " \(g)"
        case .interfaceDirect(let i): cmd += " -interface \(i)"
        case .interfaceRouter(let i):
            guard let r = interface(i)?.router else { showError("No router", "\(i) has no router right now."); return }
            cmd += " \(r)"
        }
        await runPrivileged("add a one-off route for \(d.display)", [cmd])
    }

    // MARK: Path check

    func checkPath(_ query: String? = nil) async {
        if let query { pathQuery = query }
        let q = pathQuery
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        traceroute.stop()
        traceroute.lines = []
        pathChecking = true
        defer { pathChecking = false }
        await refresh()
        let snap = net, rules = workspace.rules, aliases = workspace.aliases
        var result = await Task.detached { PathAnalyzer.analyze(q, snapshot: snap, rules: rules, aliases: aliases) }.value
        pathResult = result
        for i in result.hops.indices {
            switch await Probes.tcpConnect(ip: result.hops[i].ip, port: 443) {
            case .success(let ms): result.hops[i].tcp443 = String(format: "TCP 443 reachable in %.0f ms", ms)
            case .failure(let e): result.hops[i].tcp443 = "TCP 443 not reachable (\(e.localizedDescription))"
            }
            pathResult = result
        }
        log("Path check: \(result.query)", ok: result.error == nil, result.hops.map { "\($0.ip): \($0.headline)" }.joined(separator: "\n"))
    }

    func openPathCheck(_ query: String) {
        selection = .pathCheck
        Task { await checkPath(query) }
    }
}
