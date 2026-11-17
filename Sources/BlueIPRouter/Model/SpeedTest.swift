import BlueIPRouterCore
import Foundation
import Network
import Observation

// MARK: - Servers

enum SpeedEngine: String, Codable, CaseIterable, Identifiable {
    case cloudflare, libreSpeed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cloudflare: return "Cloudflare"
        case .libreSpeed: return "LibreSpeed"
        }
    }
}

/// One test endpoint: where to download from, upload to and ping.
struct SpeedServer: Hashable, Identifiable, Sendable {
    var id: String { host + basePath }
    var name: String
    var host: String
    var basePath: String
    var engine: SpeedEngine

    static let cloudflare = SpeedServer(name: "Cloudflare (nearest location)", host: "speed.cloudflare.com", basePath: "/", engine: .cloudflare)

    func downloadPath(bytes: Int) -> String {
        switch engine {
        case .cloudflare: return "/__down?bytes=\(bytes)"
        // LibreSpeed's garbage.php streams ckSize chunks of 1 MiB.
        case .libreSpeed: return basePath + "garbage.php?ckSize=\(max(1, bytes / 1_048_576))&r=\(UInt32.random(in: 0...UInt32.max))"
        }
    }

    var uploadPath: String {
        switch engine {
        case .cloudflare: return "/__up"
        case .libreSpeed: return basePath + "empty.php?r=\(UInt32.random(in: 0...UInt32.max))"
        }
    }
}

enum LibreSpeedDirectory {
    /// Public LibreSpeed servers (the list librespeed.org uses).
    static func servers() async throws -> [SpeedServer] {
        let url = URL(string: "https://librespeed.org/backend-servers/servers.php")!
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("BlueIPRouter/\(BIR.version)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        return list.compactMap { o -> SpeedServer? in
            guard let name = o["name"] as? String, var server = o["server"] as? String else { return nil }
            if server.hasPrefix("//") { server = "https:" + server }
            guard let u = URL(string: server), let host = u.host, u.scheme != "http" || true else { return nil }
            var base = u.path.isEmpty ? "/" : u.path
            if !base.hasSuffix("/") { base += "/" }
            // The download/upload files live next to "server" unless the entry says otherwise.
            if let dl = o["dlURL"] as? String, dl.contains("/") {
                base += dl.split(separator: "/").dropLast().joined(separator: "/") + "/"
            }
            return SpeedServer(name: name, host: host, basePath: base, engine: .libreSpeed)
        }
    }
}

// MARK: - Low-level transfers

/// Thread-safe byte counter shared by parallel streams.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    func add(_ n: Int) { lock.lock(); total += Int64(n); lock.unlock() }
    var value: Int64 { lock.lock(); defer { lock.unlock() }; return total }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

enum SpeedIO {
    static func parameters(tls: Bool, interface: NWInterface?) -> NWParameters {
        let p = tls ? NWParameters(tls: .init(), tcp: .init()) : .tcp
        if let interface { p.requiredInterface = interface }
        return p
    }

    /// Round trip of a tiny HTTPS request after the connection is set up: time from sending the request to the
    /// first byte of the reply. Unlike a TCP-handshake ping this is still correct through VPN clients that answer
    /// the handshake locally (TUN proxies such as xray or sing-box).
    static func ping(server: SpeedServer, interface: NWInterface?, timeout: Double = 4) async -> Double? {
        let conn = NWConnection(host: NWEndpoint.Host(server.host), port: 443, using: parameters(tls: true, interface: interface))
        let queue = DispatchQueue(label: "speed.ping")
        return await withCheckedContinuation { cont in
            let once = Once()
            func finish(_ v: Double?) { once.run { conn.cancel(); cont.resume(returning: v) } }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let path = server.engine == .cloudflare ? "/__down?bytes=0" : server.basePath + "empty.php?r=\(UInt32.random(in: 0...UInt32.max))"
                    let req = "GET \(path) HTTP/1.0\r\nHost: \(server.host)\r\nUser-Agent: BlueIPRouter/\(BIR.version)\r\nConnection: close\r\n\r\n"
                    let sent = Date()
                    conn.send(content: Data(req.utf8), completion: .contentProcessed { e in if e != nil { finish(nil) } })
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                        finish(error == nil && !(data ?? Data()).isEmpty ? Date().timeIntervalSince(sent) * 1000 : nil)
                    }
                case .failed, .waiting: finish(nil)
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// One HTTPS download, counting body bytes as they arrive. Stops at the deadline.
    static func download(server: SpeedServer, bytes: Int, interface: NWInterface?, counter: ByteCounter,
                         deadline: Date, cancel: CancelFlag) async throws {
        let conn = NWConnection(host: NWEndpoint.Host(server.host), port: 443, using: parameters(tls: true, interface: interface))
        let queue = DispatchQueue(label: "speed.down")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            func finish(_ error: Error?) {
                once.run {
                    conn.cancel()
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
            nonisolated(unsafe) var header = Data()
            nonisolated(unsafe) var inBody = false
            func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                    if let data, !data.isEmpty {
                        if inBody {
                            counter.add(data.count)
                        } else {
                            header.append(data)
                            if let r = header.range(of: Data("\r\n\r\n".utf8)) {
                                let status = String(decoding: header[..<r.lowerBound], as: UTF8.self)
                                    .split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
                                guard (200..<300).contains(status) else { finish(URLError(.badServerResponse)); return }
                                inBody = true
                                counter.add(header.count - r.upperBound)
                            }
                        }
                    }
                    if let error { finish(error); return }
                    if complete || Date() >= deadline || cancel.isCancelled { finish(nil); return }
                    receive()
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let req = "GET \(server.downloadPath(bytes: bytes)) HTTP/1.0\r\nHost: \(server.host)\r\n"
                        + "User-Agent: BlueIPRouter/\(BIR.version)\r\nAccept: */*\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(req.utf8), completion: .contentProcessed { e in if let e { finish(e) } })
                    receive()
                case .failed(let e), .waiting(let e): finish(e)
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + max(1, deadline.timeIntervalSinceNow) + 2) { finish(nil) }
        }
    }

    /// One HTTPS upload of `bytes`, counting bytes as the network stack accepts them. Stops at the deadline.
    static func upload(server: SpeedServer, bytes: Int, interface: NWInterface?, counter: ByteCounter,
                       deadline: Date, cancel: CancelFlag) async throws {
        let conn = NWConnection(host: NWEndpoint.Host(server.host), port: 443, using: parameters(tls: true, interface: interface))
        let queue = DispatchQueue(label: "speed.up")
        let chunk = Data(count: 64 * 1024)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            func finish(_ error: Error?) {
                once.run {
                    conn.cancel()
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
            nonisolated(unsafe) var remaining = bytes
            func sendNext() {
                if remaining <= 0 {
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in finish(nil) }
                    return
                }
                if Date() >= deadline || cancel.isCancelled { finish(nil); return }
                let piece = remaining >= chunk.count ? chunk : chunk.prefix(remaining)
                conn.send(content: piece, completion: .contentProcessed { e in
                    if let e { finish(e); return }
                    counter.add(piece.count)
                    remaining -= piece.count
                    sendNext()
                })
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let head = "POST \(server.uploadPath) HTTP/1.0\r\nHost: \(server.host)\r\nUser-Agent: BlueIPRouter/\(BIR.version)\r\n"
                        + "Content-Type: application/octet-stream\r\nContent-Length: \(bytes)\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(head.utf8), completion: .contentProcessed { e in
                        if let e { finish(e) } else { sendNext() }
                    })
                case .failed(let e), .waiting(let e): finish(e)
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + max(1, deadline.timeIntervalSinceNow) + 3) { finish(nil) }
        }
    }
}

// MARK: - Results

struct SpeedTestResult: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var engine: SpeedEngine
    var server: String
    var pathTitle: String
    var interface: String?
    var downloadMbps: Double
    var uploadMbps: Double
    var pingMs: Double
    var jitterMs: Double
    var loadedPingMs: Double?
    var dataMB: Double
    var publicIP: String?
    var country: String?
    var org: String?

    var flag: String? { publicIP.map { IPIdentity(ip: $0, country: country).flag } ?? nil }
}

enum SpeedHistoryStore {
    static var url: URL { Storage.appSupport.appendingPathComponent("speedtests.json") }
    static func load() -> [SpeedTestResult] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? BIRJSON.decoder.decode([SpeedTestResult].self, from: d)) ?? []
    }
    static func save(_ list: [SpeedTestResult]) {
        if let d = try? BIRJSON.encoder.encode(Array(list.suffix(200))) { try? d.write(to: url, options: .atomic) }
    }
}

/// A network path to test: pinned to one interface, or the system default (whatever routing picks, e.g. the VPN).
struct SpeedPath: Identifiable, Hashable {
    var id: String
    var title: String
    var detail: String
    var interfaceName: String?
    var nw: NWInterface?
    static func == (a: SpeedPath, b: SpeedPath) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - Runner

@Observable
@MainActor
final class SpeedTestRunner {
    enum Phase: String { case idle, server, ping, download, upload, done, failed, cancelled }

    var phase: Phase = .idle
    var liveMbps: Double = 0
    var progress: Double = 0
    var pingMs: Double?
    var jitterMs: Double?
    var loadedPingMs: Double?
    var downloadMbps: Double?
    var uploadMbps: Double?
    var serverName: String?
    var identity: IPIdentity?
    var error: String?
    var history: [SpeedTestResult] = SpeedHistoryStore.load()
    var libreServers: [SpeedServer] = []

    var isRunning: Bool { [.server, .ping, .download, .upload].contains(phase) }

    private var cancel = CancelFlag()
    private var task: Task<Void, Never>?

    nonisolated static let streams = 4
    nonisolated static let downloadSeconds = 10.0
    nonisolated static let uploadSeconds = 8.0

    func stop() {
        cancel.cancel()
        task?.cancel()
        if isRunning { phase = .cancelled }
    }

    func loadLibreServers() async {
        guard libreServers.isEmpty else { return }
        libreServers = (try? await LibreSpeedDirectory.servers()) ?? []
    }

    func start(engine: SpeedEngine, libreServerID: String?, path: SpeedPath, geo: GeoProvider) {
        stop()
        cancel = CancelFlag()
        let flag = cancel
        phase = .server
        liveMbps = 0; progress = 0
        pingMs = nil; jitterMs = nil; loadedPingMs = nil; downloadMbps = nil; uploadMbps = nil
        identity = nil; error = nil; serverName = nil
        task = Task { await self.run(engine: engine, libreServerID: libreServerID, path: path, geo: geo, cancel: flag) }
    }

    private func run(engine: SpeedEngine, libreServerID: String?, path: SpeedPath, geo: GeoProvider, cancel: CancelFlag) async {
        let iface = path.nw
        // Public identity of this path, in parallel with the test.
        let identityTask = Task.detached { () -> IPIdentity? in
            guard case .success(let (ip, _)) = await Probes.publicAddress(v6: false, interface: iface) else { return nil }
            return await Probes.geolocate(ip, preferred: geo) ?? IPIdentity(ip: ip)
        }

        // 1. Server
        var server = SpeedServer.cloudflare
        if engine == .libreSpeed {
            await loadLibreServers()
            if let id = libreServerID, let s = libreServers.first(where: { $0.id == id }) {
                server = s
            } else if let best = await fastest(libreServers.prefix(24), interface: iface) {
                server = best
            } else {
                fail("No LibreSpeed server answered on this path.")
                return
            }
        }
        serverName = server.name
        let target = server
        guard !cancel.isCancelled else { return }

        // 2. Ping and jitter
        phase = .ping
        var pings: [Double] = []
        for i in 0..<10 {
            if cancel.isCancelled { return }
            if let p = await SpeedIO.ping(server: server, interface: iface) { pings.append(p) }
            progress = Double(i + 1) / 10
        }
        guard !pings.isEmpty else { fail("The server did not answer on \(path.title). This path may have no internet access."); return }
        pingMs = pings.sorted()[pings.count / 2]
        jitterMs = zip(pings, pings.dropFirst()).map { abs($0 - $1) }.reduce(0, +) / Double(max(1, pings.count - 1))

        // 3. Download (with latency under load)
        phase = .download
        let down = await measure(seconds: Self.downloadSeconds, cancel: cancel, loadedPing: (target, iface)) { counter, deadline in
            try await SpeedIO.download(server: target, bytes: 25_000_000, interface: iface, counter: counter, deadline: deadline, cancel: cancel)
        }
        guard !cancel.isCancelled else { return }
        downloadMbps = down.mbps
        loadedPingMs = down.loadedPing

        // 4. Upload
        phase = .upload
        let up = await measure(seconds: Self.uploadSeconds, cancel: cancel, loadedPing: nil) { counter, deadline in
            try await SpeedIO.upload(server: target, bytes: 10_000_000, interface: iface, counter: counter, deadline: deadline, cancel: cancel)
        }
        guard !cancel.isCancelled else { return }
        uploadMbps = up.mbps

        identity = await identityTask.value
        if down.bytes == 0 && up.bytes == 0 {
            fail(down.error ?? up.error ?? "No data could be transferred on this path.")
            return
        }
        phase = .done
        liveMbps = 0
        let result = SpeedTestResult(engine: engine, server: server.name, pathTitle: path.title, interface: path.interfaceName,
                                     downloadMbps: down.mbps, uploadMbps: up.mbps, pingMs: pingMs ?? 0, jitterMs: jitterMs ?? 0,
                                     loadedPingMs: down.loadedPing, dataMB: Double(down.bytes + up.bytes) / 1_000_000,
                                     publicIP: identity?.ip, country: identity?.country, org: identity?.org)
        history.append(result)
        SpeedHistoryStore.save(history)
    }

    private func fail(_ message: String) {
        error = message
        phase = .failed
        liveMbps = 0
    }

    private func fastest(_ servers: ArraySlice<SpeedServer>, interface: NWInterface?) async -> SpeedServer? {
        await withTaskGroup(of: (SpeedServer, Double?).self) { group in
            for s in servers { group.addTask { (s, await SpeedIO.ping(server: s, interface: interface, timeout: 3)) } }
            var best: (SpeedServer, Double)?
            for await (s, p) in group { if let p, p < (best?.1 ?? .infinity) { best = (s, p) } }
            return best?.0
        }
    }

    struct Measurement { var mbps: Double; var bytes: Int64; var loadedPing: Double?; var error: String? }

    /// Runs `streams` parallel transfer loops for `seconds`, sampling throughput for the dial.
    /// The first second (TCP slow start) is left out of the final figure.
    private func measure(seconds: Double, cancel: CancelFlag, loadedPing: (SpeedServer, NWInterface?)?,
                         transfer: @escaping @Sendable (ByteCounter, Date) async throws -> Void) async -> Measurement {
        let counter = ByteCounter()
        let start = Date()
        let deadline = start.addingTimeInterval(seconds)
        let errors = ErrorBox()
        let workers = Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.streams {
                    group.addTask {
                        while Date() < deadline && !cancel.isCancelled {
                            do { try await transfer(counter, deadline) } catch {
                                errors.set(error.localizedDescription)
                                try? await Task.sleep(for: .milliseconds(300))
                            }
                        }
                    }
                }
            }
        }
        var loaded: [Double] = []
        let pinger = loadedPing.map { target in
            Task.detached { () -> [Double] in
                var out: [Double] = []
                try? await Task.sleep(for: .seconds(1))
                while Date() < deadline && !cancel.isCancelled {
                    if let p = await SpeedIO.ping(server: target.0, interface: target.1, timeout: 3) { out.append(p) }
                    try? await Task.sleep(for: .milliseconds(400))
                }
                return out
            }
        }
        var warmBytes: Int64 = 0
        var warmTime: Date?
        var lastBytes: Int64 = 0
        var lastTime = start
        while Date() < deadline && !cancel.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
            let now = Date(), bytes = counter.value
            let instant = Double(bytes - lastBytes) * 8 / 1_000_000 / max(0.05, now.timeIntervalSince(lastTime))
            liveMbps = liveMbps == 0 ? instant : liveMbps * 0.7 + instant * 0.3
            lastBytes = bytes
            lastTime = now
            progress = min(1, now.timeIntervalSince(start) / seconds)
            if warmTime == nil && now.timeIntervalSince(start) >= 1 { warmTime = now; warmBytes = bytes }
        }
        await workers.value
        if let pinger { loaded = await pinger.value }
        let end = Date(), total = counter.value
        let from = warmTime ?? start
        let mbps = Double(total - (warmTime == nil ? 0 : warmBytes)) * 8 / 1_000_000 / max(0.5, end.timeIntervalSince(from))
        let lp = loaded.isEmpty ? nil : loaded.sorted()[loaded.count / 2]
        return Measurement(mbps: max(0, mbps), bytes: total, loadedPing: lp, error: total == 0 ? errors.value : nil)
    }
}

final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?
    func set(_ m: String) { lock.lock(); if message == nil { message = m }; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return message }
}
