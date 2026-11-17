import BlueIPRouterCore
import Foundation
import SystemConfiguration

enum InterfaceKind: String, Hashable, Sendable {
    case wifi, ethernet, thunderbolt, tunnel, ppp, ipsec, loopback, bridge, wirelessDirect, system, other

    var label: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .ethernet: return "Ethernet"
        case .thunderbolt: return "Thunderbolt"
        case .tunnel: return "Tunnel (utun)"
        case .ppp: return "PPP VPN"
        case .ipsec: return "IPsec VPN"
        case .loopback: return "Loopback"
        case .bridge: return "Bridge"
        case .wirelessDirect: return "Apple Wireless Direct"
        case .system: return "System"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector.horizontal"
        case .thunderbolt: return "bolt.horizontal"
        case .tunnel: return "lock.shield"
        case .ppp, .ipsec: return "building.columns"
        case .loopback: return "arrow.triangle.2.circlepath"
        case .bridge: return "point.3.connected.trianglepath.dotted"
        case .wirelessDirect: return "dot.radiowaves.left.and.right"
        case .system: return "gearshape"
        case .other: return "network"
        }
    }

    var isVPN: Bool { self == .tunnel || self == .ppp || self == .ipsec }
    var isPhysical: Bool { self == .wifi || self == .ethernet || self == .thunderbolt }
}

struct InterfaceInfo: Identifiable, Hashable, Sendable {
    var snapshot: InterfaceSnapshot
    var hardwarePort: String?
    var serviceName: String?
    var router: String?
    var dns: [String]
    var kind: InterfaceKind
    /// Holds catch-all routes (0/1 + 128/1, or 1, 2/7 … 128/1) so it captures all internet traffic.
    var isFullTunnel: Bool
    var routeCount: Int

    var id: String { snapshot.name }
    var name: String { snapshot.name }
    var ipv4: String? { snapshot.ipv4.first?.address }
    var isActive: Bool { snapshot.isUp && (!snapshot.ipv4.isEmpty || (snapshot.isRunning && !snapshot.ipv6.isEmpty)) }
    var isSystemNoise: Bool {
        kind == .system || kind == .wirelessDirect || kind == .loopback || (kind == .tunnel && snapshot.ipv4.isEmpty)
            || (kind == .thunderbolt && snapshot.ipv4.isEmpty)
    }
}

struct ServiceStatus: Hashable, Sendable {
    var helperInstalled = false
    var helperVersion: String?
    var daemonInstalled = false
    var loaded = false
    var state: String?
    var lastExit: String?
    var runs: Int?
    var interval: Int?
}

struct LiveCount: Hashable, Sendable {
    var live: Int
    var expected: Int
    var allLive: Bool { expected > 0 && live == expected }
}

struct NetworkSnapshot: Sendable {
    var interfaces: [InterfaceInfo] = []
    var routesV4: [RouteEntry] = []
    var routesV6: [RouteEntry] = []
    var internetRoute: RouteLookup?
    var primaryInterface: String?
    var primaryRouter: String?
    var systemDNS: [String] = []
    var helperStatus: HelperStatus?
    var appliedRules: [RouteRule] = []
    /// For each draft rule: how many of its routes already exist in the kernel (whoever added them).
    var liveRoutes: [UUID: LiveCount] = [:]
    var service = ServiceStatus()
    var appliedKillSwitch: KillSwitchConfig?
    var learnedServers: [String] = []
    var pfEnabled = false
    var takenAt = Date()
}

/// Reads everything the app shows. Runs off the main thread and needs no privileges.
enum NetworkScanner {
    static let catchAllDestinations: Set<String> = ["0/1", "128.0/1", "1", "2/7", "4/6", "8/5", "16/4", "32/3", "64/2"]

    static func scan(rules: [RouteRule] = []) -> NetworkSnapshot {
        var snap = NetworkSnapshot()
        let raw = InterfaceInventory.snapshot()
        snap.routesV4 = RouteQuery.table(family: "inet")
        snap.routesV6 = RouteQuery.table(family: "inet6")
        snap.internetRoute = RouteQuery.lookup("1.1.1.1")

        let ports = hardwarePorts()
        let services = serviceNames()
        let dns = dnsByInterface()
        snap.systemDNS = dns.global

        if let store = SCDynamicStoreCreate(nil, "BlueIPRouter" as CFString, nil, nil),
           let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            snap.primaryInterface = global["PrimaryInterface"] as? String
            snap.primaryRouter = global["Router"] as? String
        }

        snap.interfaces = raw.map { s in
            let port = ports[s.name]
            let kind = classify(name: s.name, port: port)
            let catchAll = snap.routesV4.filter { $0.netif == s.name && catchAllDestinations.contains($0.destination) }.count
            let router = (s.isUp && !s.ipv4.isEmpty && !s.isPointToPoint && !s.isLoopback) ? RouteQuery.router(of: s.name) : nil
            return InterfaceInfo(snapshot: s, hardwarePort: port, serviceName: services[s.name], router: router,
                                 dns: dns.byInterface[s.name] ?? [], kind: kind, isFullTunnel: catchAll >= 2,
                                 routeCount: snap.routesV4.filter { $0.netif == s.name }.count)
        }

        snap.helperStatus = BIRJSON.load(HelperStatus.self, from: BIR.status)
        let persistent = BIRJSON.load(HelperConfig.self, from: BIR.persistentRules)?.rules ?? []
        let session = BIRJSON.load(HelperConfig.self, from: BIR.sessionRules)?.rules ?? []
        snap.appliedRules = persistent + session
        snap.service = serviceStatus()
        snap.liveRoutes = liveCheck(rules, interfaces: raw)
        snap.appliedKillSwitch = BIRJSON.load(KillSwitchConfig.self, from: BIR.killSwitchConfig)
        snap.learnedServers = BIRJSON.load([String].self, from: BIR.learnedServers) ?? []
        snap.pfEnabled = snap.helperStatus?.killSwitch?.pfEnabled ?? false
        snap.takenAt = Date()
        return snap
    }

    /// Plans each rule exactly like the helper would and checks which routes are already installed.
    static func liveCheck(_ rules: [RouteRule], interfaces: [InterfaceSnapshot]) -> [UUID: LiveCount] {
        let enabled = rules.filter(\.enabled)
        guard !enabled.isEmpty else { return [:] }
        let plan = RoutePlanner.plan(rules: enabled, interfaces: interfaces, router: { RouteQuery.router(of: $0) },
                                     resolve: { Resolver.resolve($0, timeout: 2) }, cache: [:])
        var out: [UUID: LiveCount] = [:]
        for rule in enabled {
            let mine = plan.routes.filter { $0.ruleID == rule.id }
            let live = mine.filter { RouteCommands.isInstalled($0, RouteQuery.lookup($0.destination, prefix: $0.prefix)) }.count
            out[rule.id] = LiveCount(live: live, expected: mine.count)
        }
        return out
    }

    static func classify(name: String, port: String?) -> InterfaceKind {
        if let port {
            if port == "Wi-Fi" || port == "AirPort" { return .wifi }
            if port.contains("Bridge") { return .bridge }
            if port.hasPrefix("Thunderbolt") { return .thunderbolt }
            if port.localizedCaseInsensitiveContains("Ethernet") || port.localizedCaseInsensitiveContains("LAN") { return .ethernet }
        }
        if name.hasPrefix("utun") { return .tunnel }
        if name.hasPrefix("ppp") { return .ppp }
        if name.hasPrefix("ipsec") { return .ipsec }
        if name.hasPrefix("lo") { return .loopback }
        if name.hasPrefix("bridge") { return .bridge }
        if name.hasPrefix("awdl") || name.hasPrefix("llw") { return .wirelessDirect }
        if ["anpi", "ap", "gif", "stf", "XHC", "vmenet"].contains(where: { name.hasPrefix($0) }) { return .system }
        if name.hasPrefix("en") { return .ethernet }
        return .other
    }

    /// Device → hardware port name (e.g. "en0" → "Wi-Fi").
    static func hardwarePorts() -> [String: String] {
        let out = Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"], timeout: 8).stdout
        var map: [String: String] = [:]
        var port: String?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("Hardware Port: ") { port = String(line.dropFirst("Hardware Port: ".count)) }
            if line.hasPrefix("Device: "), let p = port { map[String(line.dropFirst("Device: ".count))] = p }
        }
        return map
    }

    /// Device → network service name, needed by networksetup (e.g. DNS changes).
    static func serviceNames() -> [String: String] {
        let out = Shell.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"], timeout: 8).stdout
        var map: [String: String] = [:]
        var current: String?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("("), let close = line.firstIndex(of: ")"), !line.hasPrefix("(Hardware") {
                current = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            } else if let r = line.range(of: "Device: "), let name = current {
                let device = line[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
                if !device.isEmpty { map[device] = name }
            }
        }
        return map
    }

    static func dnsByInterface() -> (global: [String], byInterface: [String: [String]]) {
        let out = Shell.run("/usr/sbin/scutil", ["--dns"], timeout: 8).stdout
        let mainSection = out.components(separatedBy: "DNS configuration (for scoped queries)").first ?? out
        var global: [String] = []
        var map: [String: [String]] = [:]
        for block in mainSection.components(separatedBy: "resolver #").dropFirst() {
            var servers: [String] = []
            var iface: String?
            var hasDomain = false
            for line in block.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("nameserver["), let v = t.split(separator: ":", maxSplits: 1).last {
                    servers.append(v.trimmingCharacters(in: .whitespaces))
                }
                if t.hasPrefix("domain") { hasDomain = true }
                if t.hasPrefix("if_index"), let open = t.firstIndex(of: "("), let close = t.firstIndex(of: ")") {
                    iface = String(t[t.index(after: open)..<close])
                }
            }
            if global.isEmpty, !hasDomain, !servers.isEmpty { global = servers }
            if let iface, !servers.isEmpty { map[iface, default: []].append(contentsOf: servers) }
        }
        return (global, map)
    }

    static func serviceStatus() -> ServiceStatus {
        var s = ServiceStatus()
        s.helperInstalled = FileManager.default.isExecutableFile(atPath: BIR.helperBinary)
        if s.helperInstalled {
            let v = Shell.run(BIR.helperBinary, ["version"], timeout: 3).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            s.helperVersion = v.isEmpty ? nil : v
        }
        s.daemonInstalled = FileManager.default.fileExists(atPath: BIR.daemonPlist)
        let r = Shell.run("/bin/launchctl", ["print", "system/\(BIR.helperLabel)"], timeout: 5)
        s.loaded = r.ok
        if r.ok {
            for line in r.stdout.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                func value() -> String { String(t.split(separator: "=", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces) }
                if t.hasPrefix("state = "), s.state == nil { s.state = value() }
                if t.hasPrefix("last exit code = ") { s.lastExit = value() }
                if t.hasPrefix("runs = ") { s.runs = Int(value()) }
                if t.hasPrefix("run interval = ") { s.interval = Int(value().split(separator: " ").first ?? "") }
            }
        }
        return s
    }

    static func tailLog(_ path: String, lines: Int = 300) -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}
