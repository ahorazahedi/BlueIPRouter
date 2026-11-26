import BlueIPRouterCore
import Foundation
import SwiftUI

enum PathVerdict: Hashable, Sendable {
    case direct, vpn, tunnel, local, noRoute, blocked

    var color: Color {
        switch self {
        case .direct: return .green
        case .vpn: return .blue
        case .tunnel: return .purple
        case .local: return .gray
        case .noRoute: return .red
        case .blocked: return .red
        }
    }

    var symbol: String {
        switch self {
        case .direct: return "arrow.up.right.circle.fill"
        case .vpn: return "building.columns.circle.fill"
        case .tunnel: return "lock.shield.fill"
        case .local: return "house.circle.fill"
        case .noRoute: return "xmark.octagon.fill"
        case .blocked: return "hand.raised.fill"
        }
    }
}

struct PathHop: Identifiable, Hashable, Sendable {
    var ip: String
    var lookup: RouteLookup?
    var interfaceName: String?
    var interfaceLabel: String
    var verdict: PathVerdict
    var headline: String
    var explanation: [String]
    var ruleID: UUID?
    var tcp443: String?
    var tcp443Reachable: Bool?
    var id: String { ip }
}

struct PathCheckResult: Sendable {
    var query: String
    var isDomain: Bool
    var ipv4: [String]
    var ipv6: [String]
    var dnsMs: Double?
    var hops: [PathHop]
    var error: String?
    var date = Date()
}

func interfaceDisplayName(_ name: String, info: InterfaceInfo?, aliases: [String: String]) -> String {
    if let alias = aliases[name], !alias.isEmpty { return alias }
    if let info {
        if info.isFullTunnel { return L10n.tr("Full-tunnel VPN") }
        if let port = info.hardwarePort { return port }
        return info.kind.label
    }
    return name
}

/// Explains which way the kernel sends traffic for an IP or a domain.
enum PathAnalyzer {
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        return s
    }

    static func analyze(_ raw: String, snapshot: NetworkSnapshot, rules: [RouteRule], aliases: [String: String]) -> PathCheckResult {
        let query = normalize(raw)
        var result = PathCheckResult(query: query, isDomain: false, ipv4: [], ipv6: [], dnsMs: nil, hops: [])
        if IPv4.isValid(query) {
            result.ipv4 = [query]
        } else if Validation.isDomain(query) {
            result.isDomain = true
            let start = Date()
            result.ipv4 = Resolver.resolve(query, family: AF_INET) ?? []
            result.dnsMs = Date().timeIntervalSince(start) * 1000
            result.ipv6 = Resolver.resolve(query, family: AF_INET6, timeout: 3) ?? []
            if result.ipv4.isEmpty && result.ipv6.isEmpty {
                result.error = L10n.tr("Could not resolve %@. Check the name or your DNS.", query)
                return result
            }
            if result.ipv4.isEmpty { result.error = L10n.tr("%@ has no IPv4 address; only IPv6 paths exist.", query) }
        } else {
            result.error = L10n.tr("Enter an IPv4 address (e.g. 203.0.113.10) or a domain (e.g. example.com).")
            return result
        }
        result.hops = result.ipv4.map { hop(for: $0, snapshot: snapshot, rules: rules, aliases: aliases) }
        return result
    }

    static func hop(for ip: String, snapshot: NetworkSnapshot, rules: [RouteRule], aliases: [String: String]) -> PathHop {
        let lookup = RouteQuery.lookup(ip)
        guard let lookup, let ifname = lookup.interface else {
            return PathHop(ip: ip, lookup: nil, interfaceName: nil, interfaceLabel: "—", verdict: .noRoute,
                           headline: L10n.tr("No route to this address"), explanation: [L10n.tr("The kernel has no route that covers %@.", ip)])
        }
        let info = snapshot.interfaces.first { $0.name == ifname }
        let label = interfaceDisplayName(ifname, info: info, aliases: aliases)
        let kind = info?.kind ?? NetworkScanner.classify(name: ifname, port: nil)

        var verdict: PathVerdict
        var headline: String
        switch kind {
        case .loopback:
            verdict = .local
            headline = L10n.tr("Stays on this Mac (loopback)")
        case .ppp, .ipsec:
            verdict = .vpn
            headline = L10n.tr("Through %@ (%@)", label, ifname)
        case .tunnel:
            verdict = .tunnel
            headline = L10n.tr("Through tunnel %@ (%@)", label, ifname)
        default:
            verdict = .direct
            headline = L10n.tr("Direct via %@ (%@)", label, ifname)
        }
        if let g = lookup.gateway, IPv4.isValid(g) { headline += " → \(L10n.tr("gateway")) \(g)" }

        var lines: [String] = []
        lines.append(L10n.tr("Matching route: %@%@", lookup.matchedRouteLabel, lookup.isStatic ? L10n.tr(" (static)") : ""))

        let installed = snapshot.helperStatus?.installedRoutes ?? []
        let owner = installed.first { r in
            r.prefix == lookup.prefix && r.destination == lookup.destination
        }
        var ruleID: UUID?
        if let owner {
            ruleID = owner.ruleID
            let name = rules.first { $0.id == owner.ruleID }?.name ?? L10n.tr("deleted rule")
            if let dom = owner.sourceDomain {
                lines.append(L10n.tr("Installed by BlueIPRouter rule “%@” for %@.", name, dom))
            } else {
                lines.append(L10n.tr("Installed by BlueIPRouter rule “%@”.", name))
            }
        } else if info?.isFullTunnel == true, lookup.flags.contains("WASCLONED") || (lookup.prefix.map { (1...8).contains($0) } ?? false) {
            lines.append(L10n.tr("This is a catch-all route of the tunnel %@: everything without a more specific route goes into it.", ifname))
        } else if lookup.isDefault {
            lines.append(L10n.tr("Uses the default route of %@.", ifname))
        } else if lookup.isHost && lookup.isStatic {
            lines.append(L10n.tr("Static host route added outside BlueIPRouter (by hand or another tool). Use Routing Table › Import to manage it."))
        } else if let p = lookup.prefix, p >= 8, !lookup.flags.contains("GATEWAY") {
            lines.append(L10n.tr("The address is on a network directly attached to %@.", ifname))
        }
        if let rule = rules.first(where: { r in r.enabled && r.parsedDestinations.contains { d in
            switch d {
            case .host(let h): return h == ip
            case .network(let n, let p): return IPv4.contains(network: n, prefix: p, ip: ip)
            case .domain: return false
            }
        } }), owner == nil {
            lines.append(L10n.tr("Rule “%@” covers this IP but its route is not active. Apply your changes or check the rule's status.", rule.name))
        }
        if let bl = snapshot.helperStatus?.blockList, bl.blocks(ip) {
            verdict = .blocked
            headline = L10n.tr("Blocked by your block list")
            lines.insert(L10n.tr("Connections to this address are refused on every interface, the VPN tunnel included."), at: 0)
        } else if let ks = snapshot.helperStatus?.killSwitch, ks.active {
            if ks.blocks(ip: ip, interface: ifname) {
                verdict = .blocked
                headline = L10n.tr("Blocked by the kill switch on %@ (%@)", label, ifname)
                lines.insert(L10n.tr("Packets to this address would leave through a guarded interface, so pf drops them."), at: 0)
            } else if verdict == .tunnel {
                let leaks = ks.interfaces.filter { ks.blocks(ip: ip, interface: $0) }
                if !leaks.isEmpty { lines.append(L10n.tr("Kill switch: if the tunnel goes down, this traffic is blocked on %@ instead of leaking.", leaks.joined(separator: ", "))) }
            }
        }
        if verdict == .tunnel, info?.isFullTunnel == true {
            lines.append(L10n.tr("To bypass the tunnel, add a rule that sends this destination via your Wi-Fi router."))
        }
        return PathHop(ip: ip, lookup: lookup, interfaceName: ifname, interfaceLabel: label, verdict: verdict,
                       headline: headline, explanation: lines, ruleID: ruleID)
    }
}
