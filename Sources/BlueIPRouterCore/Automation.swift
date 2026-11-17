import Darwin
import Foundation

extension BIR {
    /// Profiles, triggers and per-domain DNS (root-owned, applied by the helper).
    public static let automationConfig = systemDir + "/automation.json"
    /// Trigger overrides and last-seen network state (cleared at boot).
    public static let runtimeState = runDir + "/runtime.json"
    /// Recent network events detected by the helper, read by the app for notifications.
    public static let events = runDir + "/events.json"
    public static let resolverDir = "/etc/resolver"
    public static let resolverMarker = "# managed by BlueIPRouter"
}

// MARK: - Networks and profiles

/// Identifies the network the Mac is on by its router (no Wi-Fi name or location permission needed).
public struct NetworkFingerprint: Codable, Hashable, Sendable {
    public var interface: String
    public var routerIP: String
    public var routerMAC: String?

    public init(interface: String, routerIP: String, routerMAC: String?) {
        self.interface = interface
        self.routerIP = routerIP
        self.routerMAC = routerMAC
    }

    public var label: String { "router \(routerIP)" + (routerMAC.map { " (\($0))" } ?? "") + " on \(interface)" }

    /// The first physical-looking interface with a router: its router IP and MAC.
    public static func current(interfaces: [InterfaceSnapshot]) -> NetworkFingerprint? {
        let candidates = interfaces.filter { $0.isUp && !$0.isPointToPoint && !$0.isLoopback && !$0.ipv4.isEmpty && $0.name.hasPrefix("en") }
        for i in candidates {
            guard let router = RouteQuery.router(of: i.name) else { continue }
            return NetworkFingerprint(interface: i.name, routerIP: router, routerMAC: macAddress(of: router))
        }
        return nil
    }

    /// MAC address of a LAN neighbour from the ARP table ("? (192.168.1.1) at 64:9:ad:c:ec:ee on en0 …").
    public static func macAddress(of ip: String) -> String? {
        guard IPv4.isValid(ip) else { return nil }
        let out = Shell.run("/usr/sbin/arp", ["-n", ip], timeout: 4).stdout
        guard let r = out.range(of: " at ") else { return nil }
        let raw = out[r.upperBound...].split(separator: " ").first.map(String.init) ?? ""
        let parts = raw.split(separator: ":")
        guard parts.count == 6, parts.allSatisfy({ UInt8($0, radix: 16) != nil }) else { return nil }
        return parts.map { String(format: "%02x", UInt8($0, radix: 16)!) }.joined(separator: ":")
    }
}

public struct NetworkMatch: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var label: String
    public var routerIP: String
    public var routerMAC: String?

    public init(id: UUID = UUID(), label: String, routerIP: String, routerMAC: String?) {
        self.id = id
        self.label = label
        self.routerIP = routerIP
        self.routerMAC = routerMAC
    }

    /// Matches by router MAC when known (many home routers share 192.168.1.1), else by router IP.
    public func matches(_ fp: NetworkFingerprint?) -> Bool {
        guard let fp else { return false }
        if let mac = routerMAC, let other = fp.routerMAC { return mac == other }
        return routerIP == fp.routerIP
    }
}

/// A named set of active rules (and an optional kill-switch setting), chosen by hand or by network.
public struct RoutingProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var ruleIDs: [UUID]
    /// nil keeps the kill switch setting; true/false forces it while this profile is active.
    public var killSwitch: Bool?
    public var networks: [NetworkMatch]

    public init(id: UUID = UUID(), name: String, ruleIDs: [UUID] = [], killSwitch: Bool? = nil, networks: [NetworkMatch] = []) {
        self.id = id
        self.name = name
        self.ruleIDs = ruleIDs
        self.killSwitch = killSwitch
        self.networks = networks
    }
}

// MARK: - Triggers

public enum TriggerEvent: Codable, Hashable, Sendable {
    case tunnelUp, tunnelDown
    case interfaceUp(String), interfaceDown(String)
    case egressChanged, networkChanged

    public var label: String {
        switch self {
        case .tunnelUp: return "Full-tunnel VPN connects"
        case .tunnelDown: return "Full-tunnel VPN disconnects"
        case .interfaceUp(let i): return "\(i) comes up"
        case .interfaceDown(let i): return "\(i) goes down"
        case .egressChanged: return "Internet traffic switches interface"
        case .networkChanged: return "Joined a different network"
        }
    }

    public var kind: String {
        switch self {
        case .tunnelUp: return "tunnelUp"
        case .tunnelDown: return "tunnelDown"
        case .interfaceUp: return "interfaceUp"
        case .interfaceDown: return "interfaceDown"
        case .egressChanged: return "egressChanged"
        case .networkChanged: return "networkChanged"
        }
    }
}

public enum TriggerAction: Codable, Hashable, Sendable {
    case activateProfile(UUID)
    case clearProfile
    case killSwitchOn, killSwitchOff, killSwitchAuto
    case learnVPNServers
}

public struct TriggerRule: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var event: TriggerEvent
    public var actions: [TriggerAction]
    public var notify: Bool

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, event: TriggerEvent, actions: [TriggerAction] = [], notify: Bool = true) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.event = event
        self.actions = actions
        self.notify = notify
    }
}

// MARK: - Per-domain DNS

/// Sends lookups for a domain (and its subdomains) to specific name servers via /etc/resolver.
public struct DomainResolver: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var domain: String
    public var nameservers: [String]
    public var enabled: Bool

    public init(id: UUID = UUID(), domain: String, nameservers: [String], enabled: Bool = true) {
        self.id = id
        self.domain = domain
        self.nameservers = nameservers
        self.enabled = enabled
    }

    public var validationError: String? {
        let d = domain.lowercased()
        guard Validation.isDomain(d) || (d.split(separator: ".").count == 1 && d.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } && !d.isEmpty)
        else { return "“\(domain)” is not a valid domain" }
        if nameservers.isEmpty { return "\(domain): add at least one name server" }
        if let bad = nameservers.first(where: { !IPv4.isValid($0) && !Validation.isIPv6($0) }) { return "\(domain): “\(bad)” is not an IP address" }
        return nil
    }

    public var fileContent: String {
        ([BIR.resolverMarker] + nameservers.map { "nameserver \($0)" }).joined(separator: "\n") + "\n"
    }
}

/// An address, network or domain that is blocked completely (every interface, VPN included).
public struct BlockEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var value: String
    public var note: String
    public var enabled: Bool

    public init(id: UUID = UUID(), value: String, note: String = "", enabled: Bool = true) {
        self.id = id
        self.value = value
        self.note = note
        self.enabled = enabled
    }

    public var isValid: Bool { KSEntry.parse(value) != nil }
}

public struct AutomationConfig: Codable, Hashable, Sendable {
    public var profiles: [RoutingProfile]
    public var manualProfileID: UUID?
    public var autoSwitchByNetwork: Bool
    public var triggers: [TriggerRule]
    public var resolvers: [DomainResolver]
    public var blocked: [BlockEntry]

    public init(profiles: [RoutingProfile] = [], manualProfileID: UUID? = nil, autoSwitchByNetwork: Bool = true,
                triggers: [TriggerRule] = [], resolvers: [DomainResolver] = [], blocked: [BlockEntry] = []) {
        self.blocked = blocked
        self.profiles = profiles
        self.manualProfileID = manualProfileID
        self.autoSwitchByNetwork = autoSwitchByNetwork
        self.triggers = triggers
        self.resolvers = resolvers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = (try? c.decodeIfPresent([RoutingProfile].self, forKey: .profiles)) ?? []
        manualProfileID = try? c.decodeIfPresent(UUID.self, forKey: .manualProfileID)
        autoSwitchByNetwork = (try? c.decodeIfPresent(Bool.self, forKey: .autoSwitchByNetwork)) ?? true
        triggers = (try? c.decodeIfPresent([TriggerRule].self, forKey: .triggers)) ?? []
        resolvers = (try? c.decodeIfPresent([DomainResolver].self, forKey: .resolvers)) ?? []
        blocked = (try? c.decodeIfPresent([BlockEntry].self, forKey: .blocked)) ?? []
    }

    public var isEmpty: Bool { profiles.isEmpty && triggers.isEmpty && resolvers.isEmpty && blocked.isEmpty && manualProfileID == nil }

    /// Which profile is in force, and why: a trigger override, then the current network, then the manual choice.
    public func effectiveProfile(override: UUID?, network: NetworkFingerprint?) -> (profile: RoutingProfile?, reason: String) {
        if let o = override, let p = profiles.first(where: { $0.id == o }) { return (p, "set by a trigger") }
        if autoSwitchByNetwork, let p = profiles.first(where: { $0.networks.contains { $0.matches(network) } }) {
            return (p, "matched network \(network?.label ?? "")")
        }
        if let m = manualProfileID, let p = profiles.first(where: { $0.id == m }) { return (p, "chosen manually") }
        return (nil, "no profile: all enabled rules apply")
    }
}

// MARK: - Runtime state and events

public struct RuntimeState: Codable, Sendable {
    public var profileOverride: UUID?
    public var profileCleared: Bool?
    public var killSwitchOverride: Bool?
    public var network: NetworkFingerprint?
    public var interfacesUp: [String: Bool]
    public var tunnelUp: Bool
    public var egress: String?
    public var activeProfileID: UUID?
    public var killSwitchArmed: Bool?

    public init() {
        interfacesUp = [:]
        tunnelUp = false
    }
}

public struct BIREvent: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var kind: String
    public var title: String
    public var detail: String
    /// A matching trigger asked for a notification.
    public var notify: Bool

    public init(kind: String, title: String, detail: String = "", notify: Bool = false) {
        self.id = UUID()
        self.date = Date()
        self.kind = kind
        self.title = title
        self.detail = detail
        self.notify = notify
    }
}

public struct ActiveProfileInfo: Codable, Hashable, Sendable {
    public var id: UUID?
    public var name: String?
    public var reason: String

    public init(id: UUID?, name: String?, reason: String) {
        self.id = id
        self.name = name
        self.reason = reason
    }
}

public struct ResolverStatus: Codable, Hashable, Sendable {
    public var active: [String]
    public var errors: [String]

    public init(active: [String], errors: [String]) {
        self.active = active
        self.errors = errors
    }
}

// MARK: - Helpers shared by app and helper

extension NetworkFacts {
    /// Catch-all routes VPN clients add instead of replacing the default route (0/1 + 128/1, or 1, 2/7 … 128/1).
    public static let catchAllDestinations: Set<String> = ["0/1", "128.0/1", "1", "2/7", "4/6", "8/5", "16/4", "32/3", "64/2"]

    /// Interfaces that capture all internet traffic (full-tunnel VPNs).
    public static func fullTunnelInterfaces(routes: [RouteEntry]) -> [String] {
        var counts: [String: Int] = [:]
        for r in routes where catchAllDestinations.contains(r.destination) { counts[r.netif, default: 0] += 1 }
        return counts.filter { $0.value >= 2 }.map(\.key).sorted()
    }

    /// Interfaces worth watching for up/down events.
    public static func watchedInterfaceStates(_ interfaces: [InterfaceSnapshot]) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for i in interfaces where ["en", "ppp", "utun", "ipsec"].contains(where: { i.name.hasPrefix($0) }) {
            let up = i.isUp && !i.ipv4.isEmpty
            if i.name.hasPrefix("utun") && !up { continue }
            out[i.name] = up
        }
        return out
    }
}

/// Reads the per-domain resolver files in /etc/resolver.
public enum ResolverFiles {
    public struct Entry: Hashable, Sendable {
        public var domain: String
        public var nameservers: [String]
        public var managed: Bool
    }

    public static func list() -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: BIR.resolverDir)) ?? []
        return names.sorted().compactMap { name in
            guard let text = try? String(contentsOfFile: BIR.resolverDir + "/" + name, encoding: .utf8) else { return nil }
            let ns = text.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                return parts.count >= 2 && parts[0] == "nameserver" ? String(parts[1]) : nil
            }
            return Entry(domain: name, nameservers: ns, managed: text.hasPrefix(BIR.resolverMarker))
        }
    }
}
