import BlueIPRouterCore
import Foundation

/// One open network connection of a process.
struct LiveConnection: Identifiable, Hashable, Sendable {
    var id: String
    var pid: Int
    var process: String
    var proto: String
    var localIP: String
    var localPort: String
    var remoteIP: String
    var remotePort: String
    var state: String
    /// Interface the socket is bound to, found from its local address.
    var interface: String?
}

/// Reads open connections with `lsof`. Without root it sees the user's own apps (browsers, chat apps…),
/// which is where leaks matter; system daemons need an administrator run.
enum ConnectionScanner {
    static func scan(interfaces: [InterfaceSnapshot], output: String? = nil) -> [LiveConnection] {
        let text = output ?? Shell.run("/usr/sbin/lsof", ["-nP", "-i", "-F", "pcPnT"], timeout: 15).stdout
        var byAddress: [String: String] = [:]
        for i in interfaces {
            for a in i.ipv4 { byAddress[a.address] = i.name }
            for a in i.ipv6 { byAddress[a.address] = i.name }
        }
        var list: [LiveConnection] = []
        var pid = 0
        var command = ""
        var proto = ""
        var pending: (local: (String, String), remote: (String, String))?
        var state = ""

        func flush() {
            guard let p = pending else { return }
            let key = "\(pid)|\(proto)|\(p.local.0):\(p.local.1)|\(p.remote.0):\(p.remote.1)"
            list.append(LiveConnection(id: key, pid: pid, process: command, proto: proto, localIP: p.local.0, localPort: p.local.1,
                                       remoteIP: p.remote.0, remotePort: p.remote.1, state: state,
                                       interface: byAddress[p.local.0]))
            pending = nil
            state = ""
        }

        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": flush(); pid = Int(value) ?? 0
            case "c": command = value
            case "f": flush()
            case "P": proto = value
            case "n":
                flush()
                guard value.contains("->") else { continue }
                let parts = value.components(separatedBy: "->")
                guard parts.count == 2, let l = splitHostPort(parts[0]), let r = splitHostPort(parts[1]) else { continue }
                pending = (l, r)
            case "T":
                if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default: break
            }
        }
        flush()
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
    }

    /// "1.2.3.4:443" or "[2001:db8::1]:443".
    static func splitHostPort(_ s: String) -> (String, String)? {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let port = s[s.index(after: close)...].dropFirst()
            return (host.components(separatedBy: "%").first ?? host, String(port))
        }
        guard let colon = s.lastIndex(of: ":") else { return nil }
        return (String(s[..<colon]), String(s[s.index(after: colon)...]))
    }
}

// MARK: - Traffic history

struct TrafficSample: Codable, Hashable, Sendable {
    var date: Date
    var rx: Double
    var tx: Double
}

/// Per-interface traffic: high resolution for the last hour (each refresh) and one point per minute
/// for the last 7 days, kept on disk.
struct TrafficHistory: Codable {
    var recent: [String: [TrafficSample]] = [:]
    var minutes: [String: [TrafficSample]] = [:]
    private var bucketStart: Date?
    private var bucket: [String: (rx: Double, tx: Double)] = [:]

    enum CodingKeys: String, CodingKey { case minutes }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minutes = try c.decodeIfPresent([String: [TrafficSample]].self, forKey: .minutes) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(minutes, forKey: .minutes)
    }

    /// Adds bytes-per-second rates measured over `seconds`. Returns true when a minute closed (time to save).
    mutating func add(rates: [String: TrafficRate], seconds: Double, at date: Date) -> Bool {
        for (name, r) in rates {
            recent[name, default: []].append(TrafficSample(date: date, rx: r.rx, tx: r.tx))
            recent[name]?.removeAll { date.timeIntervalSince($0.date) > 3600 }
            let prev = bucket[name] ?? (0, 0)
            bucket[name] = (prev.rx + r.rx * seconds, prev.tx + r.tx * seconds)
        }
        let minute = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
        guard let start = bucketStart else { bucketStart = minute; return false }
        guard minute > start else { return false }
        for (name, b) in bucket {
            minutes[name, default: []].append(TrafficSample(date: start, rx: b.rx, tx: b.tx))
            minutes[name]?.removeAll { date.timeIntervalSince($0.date) > 7 * 86400 }
        }
        bucket = [:]
        bucketStart = minute
        return true
    }

    static var url: URL { Storage.appSupport.appendingPathComponent("traffic-history.json") }

    static func load() -> TrafficHistory {
        guard let data = try? Data(contentsOf: url), let h = try? BIRJSON.decoder.decode(TrafficHistory.self, from: data) else { return TrafficHistory() }
        return h
    }

    func save() {
        guard let data = try? BIRJSON.encoder.encode(self) else { return }
        try? data.write(to: TrafficHistory.url, options: .atomic)
    }
}
