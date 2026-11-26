import BlueIPRouterCore
import Foundation
import Network
import Observation

// MARK: - Public IP

/// What the internet sees for one address (like `myip`): the IP plus location, ISP, time zone and coordinates.
struct IPIdentity: Hashable, Sendable {
    var ip: String
    var city: String?
    var region: String?
    var country: String?
    var org: String?
    var timezone: String?
    var coords: String?

    /// Flag emoji built from the two-letter ISO country code (e.g. "GB" → 🇬🇧). Nil if the code is unknown.
    var flag: String? {
        guard let code = country?.uppercased(), code.count == 2,
              code.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else { return nil }
        let scalars = code.unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }
        return String(String.UnicodeScalarView(scalars))
    }

    var location: String {
        [city, region, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

struct PublicIPResult: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var interface: String?
    var v4: IPIdentity?
    var v6: IPIdentity?
    var v4Error: String?
    var v6Error: String?
    var latencyMs: Double?

    var ip: String? { v4?.ip ?? v6?.ip }
    var primary: IPIdentity? { v4 ?? v6 }
    var error: String? { ip == nil ? (v4Error ?? v6Error ?? L10n.tr("Not available")) : nil }
}

private final class OneShot<T>: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    private let body: (T) -> Void
    init(_ body: @escaping (T) -> Void) { self.body = body }
    func fire(_ value: T) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body(value) }
    }
}

enum ProbeError: LocalizedError {
    case noAddress(String), badResponse(String)
    var errorDescription: String? {
        switch self {
        case .noAddress(let m), .badResponse(let m): return m
        }
    }
}

enum Probes {
    /// Interfaces Network.framework can pin a connection to.
    static func availableInterfaces() async -> [NWInterface] {
        await withCheckedContinuation { cont in
            let monitor = NWPathMonitor()
            let once = OneShot<[NWInterface]> { cont.resume(returning: $0) }
            monitor.pathUpdateHandler = { path in
                once.fire(path.availableInterfaces)
                monitor.cancel()
            }
            monitor.start(queue: DispatchQueue(label: "blueiprouter.pathmonitor"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.fire([]); monitor.cancel() }
        }
    }

    /// Minimal HTTPS GET (HTTP/1.0, no chunking). `connectTo` pins the IP (and so the address family) while
    /// TLS still verifies `host`; `interface` forces the connection out of one network interface.
    static func httpsGet(host: String, path: String, connectTo: String? = nil, interface: NWInterface?,
                         timeout: Double = 8) async throws -> (Data, Double) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        let params = NWParameters(tls: tls, tcp: .init())
        if let interface { params.requiredInterface = interface }
        let conn = NWConnection(host: NWEndpoint.Host(connectTo ?? host), port: 443, using: params)
        let queue = DispatchQueue(label: "blueiprouter.https")
        let start = Date()
        return try await withCheckedThrowingContinuation { cont in
            let once = OneShot<Result<(Data, Double), Error>> { result in
                conn.cancel()
                cont.resume(with: result)
            }
            nonisolated(unsafe) var buffer = Data()
            nonisolated(unsafe) var latency = 0.0
            func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    if let data { buffer.append(data) }
                    if let error { once.fire(.failure(error)); return }
                    if complete { once.fire(.success((buffer, latency))) } else { receive() }
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    latency = Date().timeIntervalSince(start) * 1000
                    let request = "GET \(path) HTTP/1.0\r\nHost: \(host)\r\nUser-Agent: BlueIPRouter/\(BIR.version)\r\n"
                        + "Accept: */*\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(request.utf8), completion: .contentProcessed { error in
                        if let error { once.fire(.failure(error)) }
                    })
                    receive()
                case .failed(let error), .waiting(let error):
                    once.fire(.failure(error))
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { once.fire(.failure(URLError(.timedOut))) }
        }
    }

    /// Splits an HTTP/1.x response into status code and body.
    static func split(_ data: Data) -> (status: Int, body: Data) {
        let sep = Data("\r\n\r\n".utf8)
        guard let r = data.range(of: sep) else { return (0, data) }
        let head = String(decoding: data[..<r.lowerBound], as: UTF8.self)
        let status = head.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        return (status, Data(data[r.upperBound...]))
    }

    /// The public address seen for one family (IPv4 via api.ipify.org, IPv6 via api6.ipify.org).
    static func publicAddress(v6: Bool, interface: NWInterface?) async -> Result<(String, Double), Error> {
        let host = v6 ? "api6.ipify.org" : "api.ipify.org"
        let family = v6 ? AF_INET6 : AF_INET
        guard let target = Resolver.resolve(host, family: family, timeout: 4)?.first else {
            return .failure(ProbeError.noAddress(L10n.tr(v6 ? "No IPv6 connectivity" : "No IPv4 connectivity")))
        }
        do {
            let (data, ms) = try await httpsGet(host: host, path: "/", connectTo: target, interface: interface, timeout: 6)
            let (status, body) = split(data)
            let ip = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard status == 200, IPv4.isValid(ip) || Validation.isIPv6(ip) else {
                return .failure(ProbeError.badResponse(L10n.tr("%@ answered HTTP %lld", host, status)))
            }
            return .success((ip, ms))
        } catch {
            return .failure(error)
        }
    }

    /// Location and ISP for an IP, with the other provider as a fallback (some block certain countries).
    static func geolocate(_ ip: String, preferred: GeoProvider) async -> IPIdentity? {
        for provider in [preferred] + GeoProvider.allCases.filter({ $0 != preferred }) {
            if let id = await geolocateOnce(ip, provider: provider) { return id }
        }
        return nil
    }

    private static func geolocateOnce(_ ip: String, provider: GeoProvider) async -> IPIdentity? {
        let host = provider == .ipinfo ? "ipinfo.io" : "ipwho.is"
        let path = provider == .ipinfo ? "/\(ip)/json" : "/\(ip)"
        guard let (data, _) = try? await httpsGet(host: host, path: path, interface: nil) else { return nil }
        let (status, body) = split(data)
        guard status == 200, let j = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        func str(_ k: String) -> String? { (j[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch provider {
        case .ipinfo:
            if j["bogon"] as? Bool == true { return IPIdentity(ip: ip, org: L10n.tr("Private/reserved address")) }
            return IPIdentity(ip: ip, city: str("city"), region: str("region"), country: str("country"),
                              org: str("org"), timezone: str("timezone"), coords: str("loc"))
        case .ipwhois:
            guard j["success"] as? Bool != false else { return nil }
            let conn = j["connection"] as? [String: Any]
            let asn = (conn?["asn"] as? Int).map { "AS\($0) " } ?? ""
            let org = (conn?["org"] as? String) ?? (conn?["isp"] as? String)
            let tz = (j["timezone"] as? [String: Any])?["id"] as? String
            var coords: String?
            if let la = j["latitude"] as? Double, let lo = j["longitude"] as? Double { coords = String(format: "%.4f,%.4f", la, lo) }
            return IPIdentity(ip: ip, city: str("city"), region: str("region"), country: str("country_code") ?? str("country"),
                              org: org.map { asn + $0 }, timezone: tz, coords: coords)
        }
    }

    static func friendly(_ error: Error) -> String {
        if (error as? URLError)?.code == .timedOut { return L10n.tr("No internet through this path (timed out)") }
        if let nw = error as? NWError {
            switch nw {
            case .posix(let code) where code == .ENETDOWN || code == .ENETUNREACH: return L10n.tr("No route to the internet from this interface")
            case .posix(let code) where code == .ECONNREFUSED: return L10n.tr("Connection refused")
            case .dns: return L10n.tr("DNS lookup failed")
            case .tls: return L10n.tr("TLS handshake failed (traffic may be intercepted)")
            default: return "\(nw)"
            }
        }
        return error.localizedDescription
    }

    /// One path (default or pinned to an interface): IPv4 and IPv6 in parallel.
    static func probePath(id: String, title: String, interface: NWInterface?) async -> (PublicIPResult, [String]) {
        async let a = publicAddress(v6: false, interface: interface)
        async let b = publicAddress(v6: true, interface: interface)
        let (r4, r6) = await (a, b)
        var result = PublicIPResult(id: id, title: title, interface: interface?.name)
        var ips: [String] = []
        switch r4 {
        case .success(let (ip, ms)): result.v4 = IPIdentity(ip: ip); result.latencyMs = ms; ips.append(ip)
        case .failure(let e): result.v4Error = friendly(e)
        }
        switch r6 {
        case .success(let (ip, ms)): result.v6 = IPIdentity(ip: ip); result.latencyMs = result.latencyMs ?? ms; ips.append(ip)
        case .failure: result.v6Error = L10n.tr("No IPv6 connectivity on this path")
        }
        return (result, ips)
    }

    /// TCP connect time to ip:port using normal routing.
    static func tcpConnect(ip: String, port: UInt16, timeout: Double = 5) async -> Result<Double, Error> {
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "blueiprouter.tcp")
        let start = Date()
        return await withCheckedContinuation { cont in
            let once = OneShot<Result<Double, Error>> { r in
                conn.cancel()
                cont.resume(returning: r)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: once.fire(.success(Date().timeIntervalSince(start) * 1000))
                case .failed(let e), .waiting(let e): once.fire(.failure(e))
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { once.fire(.failure(URLError(.timedOut))) }
        }
    }
}

// MARK: - Traceroute

@Observable
@MainActor
final class TracerouteRunner {
    var lines: [String] = []
    var running = false
    private var process: Process?

    func start(target: String) {
        stop()
        guard IPv4.isValid(target) else { return }
        lines = ["traceroute to \(target), max 20 hops"]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/traceroute")
        p.arguments = ["-n", "-q", "1", "-w", "1", "-m", "20", target]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                self?.lines.append(contentsOf: text.split(separator: "\n").map(String.init))
            }
        }
        p.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in self?.running = false }
        }
        do {
            try p.run()
            process = p
            running = true
        } catch {
            lines.append(L10n.tr("Could not start traceroute: %@", error.localizedDescription))
        }
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        running = false
    }
}
