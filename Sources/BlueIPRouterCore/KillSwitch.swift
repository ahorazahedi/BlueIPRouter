import Darwin
import Foundation

extension BIR {
    public static let killSwitchConfig = systemDir + "/killswitch.json"
    public static let learnedServers = systemDir + "/learned-vpn-servers.json"
    public static let pfRules = runDir + "/killswitch.pf"
    public static let pfToken = runDir + "/pf-token"
    public static let pfAnchor = "com.apple/blueiprouter"
}

/// A named set of destinations (CIDRs or domains), e.g. Telegram's published ranges.
public struct BlockList: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var entries: [String]
    public var enabled: Bool
    public var sourceURL: String?

    public init(id: UUID = UUID(), name: String, entries: [String], enabled: Bool = true, sourceURL: String? = nil) {
        self.id = id
        self.name = name
        self.entries = entries
        self.enabled = enabled
        self.sourceURL = sourceURL
    }

    public static let telegramID = UUID(uuidString: "7E1E6A00-0000-4000-8000-000000000001")!
    public static let telegramSource = "https://core.telegram.org/resources/cidr.txt"
    public static var telegram: BlockList {
        BlockList(id: telegramID, name: "Telegram", entries: [
            "91.108.56.0/22", "91.108.4.0/22", "91.108.8.0/22", "91.108.16.0/22", "91.108.12.0/22",
            "149.154.160.0/20", "91.105.192.0/23", "91.108.20.0/22", "185.76.151.0/24", "95.161.64.0/20",
            "2001:b28:f23d::/48", "2001:b28:f23f::/48", "2001:67c:4e8::/48", "2001:b28:f23c::/48", "2a0a:f280::/32",
        ], enabled: true, sourceURL: telegramSource)
    }
}

/// Blocks traffic on chosen interfaces (e.g. Wi-Fi, a site VPN) so traffic can only leave through a full-tunnel VPN.
public struct KillSwitchConfig: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// Block only the listed destinations on the guarded interfaces.
        case destinations
        /// Block everything on the guarded interfaces except what is explicitly allowed.
        case fullSystem
    }

    public var enabled: Bool
    public var mode: Mode
    public var interfaces: [String]
    public var blockLists: [BlockList]
    /// Full-system mode: extra destinations that may still use the guarded interfaces (e.g. the VPN server).
    public var allow: [String]
    public var allowLocalNetworks: Bool
    public var allowRuleDestinations: Bool
    public var allowDNS: Bool
    public var allowDHCP: Bool
    /// Remember the servers VPN cores (xray, sing-box…) connect to and allow them.
    public var learnVPNServers: Bool

    public init(enabled: Bool = false, mode: Mode = .destinations, interfaces: [String] = [],
                blockLists: [BlockList] = [BlockList.telegram], allow: [String] = [], allowLocalNetworks: Bool = true,
                allowRuleDestinations: Bool = true, allowDNS: Bool = true, allowDHCP: Bool = true, learnVPNServers: Bool = true) {
        self.enabled = enabled
        self.mode = mode
        self.interfaces = interfaces
        self.blockLists = blockLists
        self.allow = allow
        self.allowLocalNetworks = allowLocalNetworks
        self.allowRuleDestinations = allowRuleDestinations
        self.allowDNS = allowDNS
        self.allowDHCP = allowDHCP
        self.learnVPNServers = learnVPNServers
    }

    public var validationErrors: [String] {
        var e: [String] = []
        if interfaces.isEmpty { e.append("Choose at least one interface to guard") }
        for i in interfaces where !Validation.isInterfaceName(i) { e.append("Invalid interface \(i)") }
        for l in blockLists { for x in l.entries where KSEntry.parse(x) == nil { e.append("\(l.name): “\(x)” is not a CIDR, IP or domain") } }
        for x in allow where KSEntry.parse(x) == nil { e.append("Allow list: “\(x)” is not a CIDR, IP or domain") }
        return e
    }
}

public enum KSEntry: Hashable, Sendable {
    case cidr(String)
    case domain(String)

    public static func parse(_ raw: String) -> KSEntry? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        if let c = CIDR.normalize(s) { return .cidr(c) }
        if Validation.isDomain(s) { return .domain(s) }
        return nil
    }
}

public enum CIDR {
    /// Normalises "1.2.3.4", "10.0.0.0/8", "2001:db8::/32" into pf-ready CIDR strings.
    public static func normalize(_ s: String) -> String? {
        let parts = s.split(separator: "/", maxSplits: 1).map(String.init)
        let addr = parts[0]
        if let v = IPv4.parse(addr) {
            let p = parts.count == 2 ? Int(parts[1]) : 32
            guard let p, (0...32).contains(p) else { return nil }
            return "\(IPv4.format(v & IPv4.mask(prefix: p)))/\(p)"
        }
        if Validation.isIPv6(addr) {
            let p = parts.count == 2 ? Int(parts[1]) : 128
            guard let p, (0...128).contains(p) else { return nil }
            return "\(addr)/\(p)"
        }
        return nil
    }

    public static func contains(_ cidr: String, ip: String) -> Bool {
        let parts = cidr.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let p = Int(parts[1]) else { return false }
        if IPv4.isValid(parts[0]) { return IPv4.isValid(ip) && IPv4.contains(network: parts[0], prefix: p, ip: ip) }
        var a = in6_addr(), b = in6_addr()
        guard parts[0].withCString({ inet_pton(AF_INET6, $0, &a) }) == 1, ip.withCString({ inet_pton(AF_INET6, $0, &b) }) == 1 else { return false }
        let x = withUnsafeBytes(of: &a) { Array($0) }, y = withUnsafeBytes(of: &b) { Array($0) }
        var bits = p
        for i in 0..<16 where bits > 0 {
            let m: UInt8 = bits >= 8 ? 0xff : UInt8(0xff << (8 - bits))
            if x[i] & m != y[i] & m { return false }
            bits -= 8
        }
        return true
    }
}

/// State of the block list as loaded into pf.
public struct BlockListStatus: Codable, Hashable, Sendable {
    public var active: Bool
    public var denied: [String]
    public var errors: [String]

    public init(active: Bool, denied: [String], errors: [String]) {
        self.active = active
        self.denied = denied
        self.errors = errors
    }

    /// Whether traffic to `ip` is refused by the block list.
    public func blocks(_ ip: String) -> Bool { active && denied.contains { CIDR.contains($0, ip: ip) } }
}

public struct KillSwitchStatus: Codable, Hashable, Sendable {
    public var active: Bool
    public var mode: KillSwitchConfig.Mode
    public var interfaces: [String]
    public var blocked: [String]
    public var allowed: [String]
    public var dnsServers: [String]
    public var learnedServers: [String]
    public var pfEnabled: Bool
    public var errors: [String]

    public init(active: Bool, mode: KillSwitchConfig.Mode, interfaces: [String], blocked: [String], allowed: [String],
                dnsServers: [String], learnedServers: [String], pfEnabled: Bool, errors: [String]) {
        self.active = active
        self.mode = mode
        self.interfaces = interfaces
        self.blocked = blocked
        self.allowed = allowed
        self.dnsServers = dnsServers
        self.learnedServers = learnedServers
        self.pfEnabled = pfEnabled
        self.errors = errors
    }

    /// Whether a packet to `ip` leaving through `interface` would be dropped.
    public func blocks(ip: String, interface: String) -> Bool {
        guard active, pfEnabled, interfaces.contains(interface) else { return false }
        switch mode {
        case .destinations: return blocked.contains { CIDR.contains($0, ip: ip) }
        case .fullSystem: return !allowed.contains { CIDR.contains($0, ip: ip) } && !dnsServers.contains(ip)
        }
    }
}

/// Turns a kill-switch configuration (already resolved to CIDRs) into a pf anchor ruleset.
public enum KillSwitchCompiler {
    /// - Parameters:
    ///   - killSwitch: include the kill-switch section (guarded interfaces only).
    ///   - denied: block-list CIDRs, blocked on every interface (tunnel included).
    public static func compile(mode: KillSwitchConfig.Mode, interfaces: [String], blocked: [String], allowed: [String],
                               dnsServers: [String], allowDHCP: Bool, killSwitch: Bool = true, denied: [String] = []) -> String {
        func table(_ name: String, _ items: [String]) -> String {
            let clean = Array(Set(items.compactMap(CIDR.normalize))).sorted()
            return "table <\(name)> persist { \(clean.joined(separator: " ")) }"
        }
        var lines = ["# BlueIPRouter firewall — generated \(ISO8601DateFormatter().string(from: Date())). Do not edit."]
        if !denied.isEmpty {
            // Block list: refuse outgoing connections (apps fail fast) and drop anything coming back.
            lines.append(table("bir_deny", denied))
            lines.append("block return out quick to <bir_deny>")
            lines.append("block drop in quick from <bir_deny>")
        }
        let ifs = interfaces.filter(Validation.isInterfaceName)
        guard killSwitch, !ifs.isEmpty else { return lines.joined(separator: "\n") + "\n" }
        let on = ifs.count == 1 ? ifs[0] : "{ \(ifs.joined(separator: " ")) }"
        switch mode {
        case .destinations:
            lines.append(table("bir_block", blocked))
            if !blocked.isEmpty { lines.append("block drop out quick on \(on) to <bir_block>") }
        case .fullSystem:
            lines.append(table("bir_allow", allowed))
            lines.append(table("bir_dns", dnsServers))
            lines.append("pass out quick on \(on) to <bir_allow>")
            if !dnsServers.isEmpty { lines.append("pass out quick on \(on) proto { tcp udp } to <bir_dns> port 53") }
            if allowDHCP {
                lines.append("pass out quick on \(on) inet proto udp from any port 68 to any port 67")
                lines.append("pass out quick on \(on) inet6 proto udp from any port 546 to any port 547")
            }
            lines.append("block drop out quick on \(on) all")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Link-local, multicast and broadcast ranges needed for a LAN to keep working.
    public static let linkLocalRanges = ["169.254.0.0/16", "224.0.0.0/4", "255.255.255.255/32", "fe80::/10", "ff00::/8"]
}

/// System resolvers and VPN-core peers.
public enum NetworkFacts {
    public static func dnsServers() -> [String] {
        let out = Shell.run("/usr/sbin/scutil", ["--dns"], timeout: 8).stdout
        var seen = Set<String>()
        return out.split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("nameserver["), let v = t.split(separator: ":", maxSplits: 1).last else { return nil }
            let ip = v.trimmingCharacters(in: .whitespaces)
            return (IPv4.isValid(ip) || Validation.isIPv6(ip)) && seen.insert(ip).inserted ? ip : nil
        }
    }

    public static let vpnCoreNames = ["xray", "sing-box", "v2ray", "happd", "hiddify", "clash", "mihomo", "tun2socks", "trojan", "hysteria", "openvpn", "wireguard"]

    /// Remote IPs that VPN cores are connected to (needs root to see processes owned by root).
    public static func vpnServerPeers() -> [String: [String]] {
        let out = Shell.run("/usr/sbin/lsof", ["-nP", "-i"], timeout: 15).stdout
        var map: [String: Set<String>] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 9, let name = cols.first?.lowercased(),
                  vpnCoreNames.contains(where: { name.hasPrefix($0) }),
                  let arrow = cols.first(where: { $0.contains("->") }) else { continue }
            var remote = String(arrow.split(separator: ">").last ?? "")
            if remote.hasPrefix("[") { remote = String(remote.dropFirst().prefix { $0 != "]" }) }
            else if let colon = remote.lastIndex(of: ":") { remote = String(remote[..<colon]) }
            guard IPv4.isValid(remote) || Validation.isIPv6(remote) else { continue }
            if remote.hasPrefix("127.") || remote == "::1" { continue }
            map[name, default: []].insert(remote)
        }
        return map.mapValues { Array($0).sorted() }
    }

    /// Networks directly attached to the given interfaces (e.g. 192.168.1.0/24).
    public static func attachedNetworks(_ interfaces: [InterfaceSnapshot], names: [String]) -> [String] {
        var out: [String] = []
        for i in interfaces where names.contains(i.name) {
            for a in i.ipv4 {
                if let peer = a.peer { out.append("\(peer)/32") }
                if let p = a.prefix, let v = IPv4.parse(a.address) { out.append("\(IPv4.format(v & IPv4.mask(prefix: p)))/\(p)") }
            }
        }
        return out
    }
}
