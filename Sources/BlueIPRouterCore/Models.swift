import Foundation

/// Fixed identifiers and file locations shared by the app and the root helper.
public enum BIR {
    public static let version = "1.3.0"

    public static let helperLabel = "com.blueiprouter.helper"
    public static let helperBinary = "/Library/PrivilegedHelperTools/com.blueiprouter.helper"
    public static let daemonPlist = "/Library/LaunchDaemons/com.blueiprouter.helper.plist"

    /// Root-owned, survives reboots. Holds persistent rules and the DNS cache.
    public static let systemDir = "/Library/Application Support/BlueIPRouter"
    public static let persistentRules = systemDir + "/rules.json"
    public static let dnsCache = systemDir + "/dns-cache.json"

    /// Cleared by macOS at every boot, so session (non-persistent) rules disappear on reboot.
    public static let runDir = "/var/run/blueiprouter"
    public static let sessionRules = runDir + "/session-rules.json"
    public static let appliedState = runDir + "/applied.json"
    public static let status = runDir + "/status.json"
    public static let lockFile = runDir + "/lock"

    public static let log = "/var/log/blueiprouter.log"
}

// MARK: - Rules

/// How traffic for a rule leaves the machine.
public enum RouteVia: Codable, Hashable, Sendable {
    /// Use the router (DHCP gateway) of the interface, e.g. the Wi-Fi router.
    /// Point-to-point interfaces without a router are used directly.
    case interfaceRouter(String)
    /// Send straight out of the interface without a gateway (typical for VPN/PPP/tunnels).
    case interfaceDirect(String)
    /// Send to an explicit next-hop gateway IP.
    case gateway(String)

    public var interfaceName: String? {
        switch self {
        case .interfaceRouter(let i), .interfaceDirect(let i): return i
        case .gateway: return nil
        }
    }

    public var modeLabel: String {
        switch self {
        case .interfaceRouter: return "Interface router"
        case .interfaceDirect: return "Direct on interface"
        case .gateway: return "Specific gateway"
        }
    }

    public var validationError: String? {
        switch self {
        case .interfaceRouter(let i), .interfaceDirect(let i):
            return Validation.isInterfaceName(i) ? nil : "Choose a valid interface"
        case .gateway(let g):
            return IPv4.isValid(g) ? nil : "Gateway must be an IPv4 address"
        }
    }
}

public struct RouteRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// IPv4 hosts (1.2.3.4), networks (10.0.0.0/8) or domain names (tw.example.com).
    public var destinations: [String]
    public var via: RouteVia
    public var enabled: Bool
    /// Persistent rules are kept across reboots (needs the background service). Others last until reboot.
    public var persistent: Bool
    public var notes: String
    public var updatedAt: Date
    /// Leave the kernel routes in place when the rule is removed (for routes another app also relies on,
    /// e.g. a VPN server's own host route).
    public var keepRoutesOnRemove: Bool?

    public init(id: UUID = UUID(), name: String = "", destinations: [String] = [],
                via: RouteVia = .interfaceRouter(""), enabled: Bool = true,
                persistent: Bool = true, notes: String = "", updatedAt: Date = Date(), keepRoutesOnRemove: Bool? = nil) {
        self.keepRoutesOnRemove = keepRoutesOnRemove
        self.id = id
        self.name = name
        self.destinations = destinations
        self.via = via
        self.enabled = enabled
        self.persistent = persistent
        self.notes = notes
        self.updatedAt = updatedAt
    }

    public var parsedDestinations: [Destination] { destinations.compactMap(Destination.parse) }
    public var invalidDestinations: [String] { destinations.filter { Destination.parse($0) == nil } }

    public var validationErrors: [String] {
        var errors: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Name is required") }
        if destinations.isEmpty { errors.append("Add at least one IP, network or domain") }
        for bad in invalidDestinations { errors.append("“\(bad)” is not a valid IPv4 address, CIDR network or domain") }
        if let e = via.validationError { errors.append(e) }
        return errors
    }

    /// Same rule ignoring the edit timestamp.
    public func sameContent(as other: RouteRule) -> Bool {
        id == other.id && name == other.name && destinations == other.destinations && via == other.via
            && enabled == other.enabled && persistent == other.persistent && notes == other.notes
            && (keepRoutesOnRemove ?? false) == (other.keepRoutesOnRemove ?? false)
    }
}

public enum Destination: Hashable, Sendable {
    case host(String)
    case network(String, Int)
    case domain(String)

    public static func parse(_ raw: String) -> Destination? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        if let slash = s.firstIndex(of: "/") {
            let addr = String(s[..<slash])
            guard let value = IPv4.parse(addr), let prefix = Int(s[s.index(after: slash)...]),
                  (1...32).contains(prefix) else { return nil }
            if prefix == 32 { return .host(IPv4.format(value)) }
            return .network(IPv4.format(value & IPv4.mask(prefix: prefix)), prefix)
        }
        if let value = IPv4.parse(s) { return .host(IPv4.format(value)) }
        if Validation.isDomain(s) { return .domain(s.hasSuffix(".") ? String(s.dropLast()) : s) }
        return nil
    }

    public var display: String {
        switch self {
        case .host(let ip): return ip
        case .network(let a, let p): return "\(a)/\(p)"
        case .domain(let d): return d
        }
    }

    public var kindLabel: String {
        switch self {
        case .host: return "Host"
        case .network: return "Network"
        case .domain: return "Domain"
        }
    }
}

// MARK: - Helper state

public struct HelperConfig: Codable, Sendable {
    public var version: Int
    public var rules: [RouteRule]
    public init(rules: [RouteRule]) {
        self.version = 1
        self.rules = rules
    }
}

/// One kernel route that BlueIPRouter installed and owns.
public struct ManagedRoute: Codable, Hashable, Sendable, Identifiable {
    public var ruleID: UUID
    public var destination: String
    public var prefix: Int
    public var gateway: String?
    public var interface: String?
    public var sourceDomain: String?
    public var keepOnRemove: Bool?

    public init(ruleID: UUID, destination: String, prefix: Int, gateway: String?, interface: String?, sourceDomain: String?, keepOnRemove: Bool? = nil) {
        self.keepOnRemove = keepOnRemove
        self.ruleID = ruleID
        self.destination = destination
        self.prefix = prefix
        self.gateway = gateway
        self.interface = interface
        self.sourceDomain = sourceDomain
    }

    public var id: String { key }
    public var key: String { "\(destination)/\(prefix)" }
    public var isHost: Bool { prefix == 32 }
    public var destinationLabel: String { isHost ? destination : key }
    public var nextHopLabel: String {
        switch (gateway, interface) {
        case let (g?, i?): return "\(g) (\(i))"
        case let (g?, nil): return g
        case let (nil, i?): return "direct on \(i)"
        default: return "?"
        }
    }
}

public struct RuleStatus: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable {
        case applied, partial, failed, waiting, disabled
    }

    public var ruleID: UUID
    public var state: State
    public var resolved: [String: [String]]
    public var routes: [String]
    public var expected: Int
    public var messages: [String]

    public init(ruleID: UUID, state: State = .applied, resolved: [String: [String]] = [:],
                routes: [String] = [], expected: Int = 0, messages: [String] = []) {
        self.ruleID = ruleID
        self.state = state
        self.resolved = resolved
        self.routes = routes
        self.expected = expected
        self.messages = messages
    }

    /// Derives the final state from how many of the expected routes are installed.
    public mutating func finalize() {
        if state == .disabled || state == .waiting { return }
        if expected == 0 { state = .failed }
        else if routes.count == expected { state = .applied }
        else if routes.isEmpty { state = .failed }
        else { state = .partial }
    }
}

public struct HelperStatus: Codable, Sendable {
    public var updatedAt: Date
    public var trigger: String
    public var helperVersion: String
    public var rules: [RuleStatus]
    public var installedRoutes: [ManagedRoute]
    public var killSwitch: KillSwitchStatus?
    public var profile: ActiveProfileInfo?
    public var resolvers: ResolverStatus?
    public var tunnelUp: Bool?

    public init(updatedAt: Date, trigger: String, rules: [RuleStatus], installedRoutes: [ManagedRoute], killSwitch: KillSwitchStatus? = nil) {
        self.killSwitch = killSwitch
        self.updatedAt = updatedAt
        self.trigger = trigger
        self.helperVersion = BIR.version
        self.rules = rules
        self.installedRoutes = installedRoutes
    }
}

// MARK: - JSON

public enum BIRJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func load<T: Decodable>(_ type: T.Type, from path: String) -> T? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    public static func save<T: Encodable>(_ value: T, to path: String, mode: Int = 0o644) throws {
        let data = try encoder.encode(value)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }
}
