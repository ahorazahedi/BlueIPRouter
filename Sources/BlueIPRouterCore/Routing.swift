import Darwin
import Foundation

/// Result of `route -n get <destination>`: the route the kernel would actually use.
public struct RouteLookup: Codable, Hashable, Sendable {
    public var routeTo: String
    public var destination: String
    public var mask: String?
    public var gateway: String?
    public var interface: String?
    public var flags: [String]

    public var isHost: Bool { flags.contains("HOST") }
    public var isStatic: Bool { flags.contains("STATIC") }
    public var isDefault: Bool { destination == "default" }

    public var prefix: Int? {
        if isHost { return 32 }
        if isDefault { return 0 }
        if let m = mask { return IPv4.prefix(fromMask: m) }
        return nil
    }

    public var matchedRouteLabel: String {
        if isDefault { return CoreL10n.tr("default (0.0.0.0/0)", "по умолчанию (0.0.0.0/0)") }
        if isHost { return "\(destination)/32" }
        if let p = prefix { return "\(destination)/\(p)" }
        return destination
    }
}

/// One line of `netstat -rn`.
public struct RouteEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var family: String
    public var destination: String
    public var gateway: String
    public var flags: String
    public var netif: String
    public var expire: String

    public var isHost: Bool { flags.contains("H") }
    public var isStatic: Bool { flags.contains("S") }
    public var isScoped: Bool { flags.contains("I") }
    public var isLinkLayer: Bool { flags.contains("L") || flags.contains("W") }
    public var isDefault: Bool { destination == "default" }

    /// Turns netstat's abbreviated form ("10/8", "192.168.1", "1") into address + prefix.
    public var cidr: (address: String, prefix: Int)? {
        guard family == "inet" else { return nil }
        if isDefault { return ("0.0.0.0", 0) }
        let parts = destination.split(separator: "/")
        let dotted = parts[0].split(separator: ".").map(String.init)
        guard (1...4).contains(dotted.count), dotted.allSatisfy({ UInt8($0) != nil }) else { return nil }
        let full = (dotted + Array(repeating: "0", count: 4 - dotted.count)).joined(separator: ".")
        if parts.count == 2, let p = Int(parts[1]) { return (full, p) }
        if isHost || dotted.count == 4 { return (full, 32) }
        return (full, dotted.count * 8)
    }
}

public enum RouteQuery {
    public static func lookup(_ destination: String, prefix: Int = 32) -> RouteLookup? {
        let args = prefix >= 32 ? ["-n", "get", destination] : ["-n", "get", "-net", "\(destination)/\(prefix)"]
        let result = Shell.run("/sbin/route", args, timeout: 5)
        guard result.ok else { return nil }
        return parseLookup(result.stdout)
    }

    public static func parseLookup(_ text: String) -> RouteLookup? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil { fields[key] = value }
        }
        guard let destination = fields["destination"] else { return nil }
        let flags = (fields["flags"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .split(separator: ",").map(String.init)
        return RouteLookup(routeTo: fields["route to"] ?? destination, destination: destination,
                           mask: fields["mask"], gateway: fields["gateway"], interface: fields["interface"], flags: flags)
    }

    public static func table(family: String) -> [RouteEntry] {
        let result = Shell.run("/usr/sbin/netstat", ["-rn", "-f", family], timeout: 10)
        var entries: [RouteEntry] = []
        var started = false
        for line in result.stdout.split(separator: "\n") {
            if line.hasPrefix("Destination") { started = true; continue }
            guard started else { continue }
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.count >= 4 else { continue }
            entries.append(RouteEntry(id: "\(family)-\(entries.count)", family: family, destination: cols[0],
                                      gateway: cols[1], flags: cols[2], netif: cols[3],
                                      expire: cols.count >= 5 ? cols[4] : ""))
        }
        return entries
    }

    /// DHCP/configured router of an interface, e.g. 192.168.1.1.
    public static func router(of interface: String) -> String? {
        guard Validation.isInterfaceName(interface) else { return nil }
        let r = Shell.run("/usr/sbin/ipconfig", ["getoption", interface, "router"], timeout: 5)
        let value = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return IPv4.isValid(value) ? value : nil
    }

    public static var flagLegend: [(String, String)] {
        [
            ("U", CoreL10n.tr("Up", "Активен (Up)")),
            ("G", CoreL10n.tr("Uses a gateway", "Через шлюз")),
            ("H", CoreL10n.tr("Host route (single IP)", "Маршрут на узел (один IP)")),
            ("S", CoreL10n.tr("Static (added manually or by an app)", "Статический (добавлен вручную или приложением)")),
            ("C", CoreL10n.tr("Cloning", "Клонирующий (Cloning)")),
            ("c", CoreL10n.tr("Protocol-specific cloning", "Клонирующий для протокола")),
            ("L", CoreL10n.tr("Link-layer (ARP/NDP) entry", "Канальный уровень (ARP/NDP)")),
            ("W", CoreL10n.tr("Cloned from another route", "Клонирован из другого маршрута")),
            ("I", CoreL10n.tr("Scoped to one interface", "Привязан к одному интерфейсу")),
            ("g", CoreL10n.tr("Gateway route", "Шлюзовый маршрут")),
            ("m", CoreL10n.tr("Multicast", "Мультикаст")),
            ("R", CoreL10n.tr("Reject", "Отклонять (Reject)")),
            ("B", CoreL10n.tr("Blackhole", "Чёрная дыра (Blackhole)")),
            ("b", CoreL10n.tr("Broadcast", "Широковещательный")),
            ("r", CoreL10n.tr("Router (default router entry)", "Роутер (маршрут роутера по умолчанию)")),
            ("i", CoreL10n.tr("Interface route", "Маршрут интерфейса")),
            ("D", CoreL10n.tr("Dynamic (redirect)", "Динамический (редирект)")),
            ("M", CoreL10n.tr("Modified (redirect)", "Изменённый (редирект)")),
            ("A", CoreL10n.tr("Address-configuration route", "Маршрут автонастройки адреса")),
            ("1", CoreL10n.tr("Protocol-specific flag 1", "Флаг протокола 1")),
            ("2", CoreL10n.tr("Protocol-specific flag 2", "Флаг протокола 2")),
            ("3", CoreL10n.tr("Protocol-specific flag 3", "Флаг протокола 3")),
        ]
    }
}

/// Builds the exact `route` arguments for a managed route.
public enum RouteCommands {
    public static func destinationArgs(_ r: ManagedRoute) -> [String] {
        r.isHost ? ["-host", r.destination] : ["-net", "\(r.destination)/\(r.prefix)"]
    }

    public static func add(_ r: ManagedRoute) -> [String] {
        var args = ["-n", "add"] + destinationArgs(r)
        if let g = r.gateway { args.append(g) } else { args += ["-interface", r.interface ?? "lo0"] }
        return args
    }

    public static func delete(_ r: ManagedRoute) -> [String] { ["-n", "delete"] + destinationArgs(r) }

    public static func display(_ args: [String]) -> String { (["route"] + args).joined(separator: " ") }

    /// Whether the kernel's chosen route for this destination is exactly the managed route.
    public static func isInstalled(_ r: ManagedRoute, _ lookup: RouteLookup?) -> Bool {
        guard let l = lookup, l.destination == r.destination, l.prefix == r.prefix else { return false }
        if let g = r.gateway { return l.gateway == g }
        return l.interface == r.interface
    }

    /// Whether some route with the same destination and prefix exists (possibly to another next hop).
    public static func exactRouteExists(_ r: ManagedRoute, _ lookup: RouteLookup?) -> Bool {
        guard let l = lookup else { return false }
        return l.destination == r.destination && l.prefix == r.prefix
    }
}

// MARK: - Planning

/// Turns rules into concrete kernel routes (resolving domains and interface routers).
public enum RoutePlanner {
    public struct Result: Sendable {
        public var routes: [ManagedRoute]
        public var statuses: [UUID: RuleStatus]
        public var cache: [String: [String]]
    }

    public static func plan(rules: [RouteRule], interfaces: [InterfaceSnapshot],
                            router: (String) -> String?, resolve: (String) -> [String]?,
                            cache: [String: [String]]) -> Result {
        var routes: [ManagedRoute] = []
        var seen: [String: UUID] = [:]
        var statuses: [UUID: RuleStatus] = [:]
        var newCache = cache

        for rule in rules {
            var st = RuleStatus(ruleID: rule.id)
            guard rule.enabled else {
                st.state = .disabled
                statuses[rule.id] = st
                continue
            }
            if let e = rule.via.validationError {
                st.state = .failed
                st.messages.append(e)
                statuses[rule.id] = st
                continue
            }

            var gateway: String?
            var iface: String?
            switch rule.via {
            case .gateway(let g):
                gateway = g
            case .interfaceDirect(let i):
                guard let s = interfaces.first(where: { $0.name == i }), s.isUp else {
                    st.state = .waiting
                    st.messages.append(CoreL10n.tr("Interface %@ is not present or is down", "Интерфейс %@ отсутствует или выключен", i))
                    statuses[rule.id] = st
                    continue
                }
                iface = i
            case .interfaceRouter(let i):
                guard let s = interfaces.first(where: { $0.name == i }), s.isUp, !s.ipv4.isEmpty else {
                    st.state = .waiting
                    st.messages.append(CoreL10n.tr("Interface %@ is down or has no IPv4 address", "Интерфейс %@ выключен или не имеет IPv4-адреса", i))
                    statuses[rule.id] = st
                    continue
                }
                iface = i
                if let r = router(i) {
                    gateway = r
                } else if !s.isPointToPoint {
                    st.state = .waiting
                    st.messages.append(CoreL10n.tr("No router known for %@ yet (DHCP not finished?)", "Роутер для %@ пока неизвестен (DHCP ещё не завершился?)", i))
                    statuses[rule.id] = st
                    continue
                }
            }

            for dest in rule.parsedDestinations {
                var targets: [(String, Int, String?)] = []
                switch dest {
                case .host(let ip):
                    targets = [(ip, 32, nil)]
                case .network(let a, let p):
                    targets = [(a, p, nil)]
                case .domain(let name):
                    if let ips = resolve(name), !ips.isEmpty {
                        let sorted = Array(Set(ips)).sorted()
                        newCache[name] = sorted
                        st.resolved[name] = sorted
                    } else if let cached = cache[name], !cached.isEmpty {
                        st.resolved[name] = cached
                        st.messages.append(CoreL10n.tr("DNS lookup for %@ failed; using last known IPs", "Не удалось разрешить %@ через DNS; используются последние известные IP", name))
                    } else {
                        st.messages.append(CoreL10n.tr("Could not resolve %@", "Не удалось разрешить %@", name))
                    }
                    targets = (st.resolved[name] ?? []).map { ($0, 32, name) }
                }
                for (address, prefix, domain) in targets {
                    let key = "\(address)/\(prefix)"
                    if address == gateway {
                        st.messages.append(CoreL10n.tr("Skipped %@: it is the gateway itself", "Пропущен %@: это сам адрес шлюза", address))
                        continue
                    }
                    if let owner = seen[key] {
                        if owner != rule.id { st.messages.append(CoreL10n.tr("%@ is already routed by another rule; skipped", "%@ уже маршрутизируется другим правилом; пропущен", key)) }
                        continue
                    }
                    seen[key] = rule.id
                    routes.append(ManagedRoute(ruleID: rule.id, destination: address, prefix: prefix,
                                               gateway: gateway, interface: iface, sourceDomain: domain,
                                               keepOnRemove: rule.keepRoutesOnRemove))
                    st.expected += 1
                }
            }
            statuses[rule.id] = st
        }
        return Result(routes: routes, statuses: statuses, cache: newCache)
    }
}

// MARK: - DNS

public enum Resolver {
    private final class Box: @unchecked Sendable { var value: [String]? }

    /// System resolver lookup with a hard timeout. Returns nil on failure or timeout.
    public static func resolve(_ host: String, family: Int32 = AF_INET, timeout: TimeInterval = 5) -> [String]? {
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.value = getaddrinfoAddresses(host, family: family)
            sem.signal()
        }
        guard sem.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }

    private static func getaddrinfoAddresses(_ host: String, family: Int32) -> [String]? {
        var hints = addrinfo()
        hints.ai_family = family
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let ai = ptr {
            if let sa = ai.pointee.ai_addr, let s = SocketAddress.string(sa) { out.append(s) }
            ptr = ai.pointee.ai_next
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}

public enum SocketAddress {
    public static func string(_ sa: UnsafePointer<sockaddr>) -> String? {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p -> String? in
                var a = p.pointee.sin_addr
                guard inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)) != nil else { return nil }
                return String(cString: buf)
            }
        case AF_INET6:
            return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p -> String? in
                var a = p.pointee.sin6_addr
                guard inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count)) != nil else { return nil }
                return String(cString: buf)
            }
        default:
            return nil
        }
    }
}
