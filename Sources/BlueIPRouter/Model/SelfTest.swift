import BlueIPRouterCore
import Foundation

/// `BlueIPRouter --selftest` prints what the app sees (no UI, no privileges, no changes) and exits.
/// Useful for bug reports: it shows interface detection, path analysis, pf rule generation and public IPs.
enum SelfTest {
    @MainActor
    static func run() async {
        let rules = Storage.loadWorkspace()?.rules ?? []
        let snap = await Task.detached { NetworkScanner.scan(rules: rules) }.value
        for r in rules { if let l = snap.liveRoutes[r.id] { print("rule \(r.name): \(l.live)/\(l.expected) routes live") } }
        print("primary: \(snap.primaryInterface ?? "-") router \(snap.primaryRouter ?? "-")")
        print("internet route: \(snap.internetRoute?.interface ?? "-") via \(snap.internetRoute?.gateway ?? "-") (\(snap.internetRoute?.matchedRouteLabel ?? "-"))")
        for i in snap.interfaces where !i.isSystemNoise {
            print("iface \(i.name) kind=\(i.kind.label) port=\(i.hardwarePort ?? "-") up=\(i.snapshot.isUp) ipv4=\(i.ipv4 ?? "-") router=\(i.router ?? "-") fullTunnel=\(i.isFullTunnel) routes=\(i.routeCount)")
        }
        print("routes v4=\(snap.routesV4.count) v6=\(snap.routesV6.count) systemDNS=\(snap.systemDNS)")
        print("service: helper=\(snap.service.helperInstalled) daemon=\(snap.service.daemonInstalled) loaded=\(snap.service.loaded)")

        await MainActor.run {}
        let model = AppModel()
        model.net = snap
        print("import candidates: \(model.importCandidates.map { "\($0.destination) via \($0.entry.gateway)" })")
        let targets = Array(Set(rules.flatMap(\.destinations))).sorted().prefix(5) + ["1.1.1.1"]
        for t in targets {
            let r = PathAnalyzer.analyze(t, snapshot: snap, rules: rules, aliases: [:])
            for h in r.hops { print("path \(t) \(h.ip): \(h.headline)") }
        }

        let guarded = snap.interfaces.filter { ($0.kind.isPhysical || $0.kind == .ppp) && $0.isActive }.map(\.name)
        for mode in KillSwitchConfig.Mode.allCases {
            let text = KillSwitchCompiler.compile(mode: mode, interfaces: guarded, blocked: BlockList.telegram.entries,
                allowed: NetworkFacts.attachedNetworks(snap.interfaces.map(\.snapshot), names: guarded) + KillSwitchCompiler.linkLocalRanges,
                dnsServers: NetworkFacts.dnsServers(), allowDHCP: true)
            let path = NSTemporaryDirectory() + "bir-ks-\(mode.rawValue).pf"
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
            let r = Shell.run("/sbin/pfctl", ["-nf", path])
            print("pf \(mode.rawValue) on \(guarded): \(r.ok ? "syntax ok" : "FAILED \(r.stderr)")")
        }

        for (label, ks) in [("block list only", false), ("block list + kill switch", true)] {
            let text = KillSwitchCompiler.compile(mode: .destinations, interfaces: guarded, blocked: BlockList.telegram.entries, allowed: [],
                                                  dnsServers: [], allowDHCP: true, killSwitch: ks, denied: ["203.0.113.10/32", "2001:db8::/32"])
            let path = NSTemporaryDirectory() + "bir-deny.pf"
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
            let r = Shell.run("/sbin/pfctl", ["-nf", path])
            print("pf \(label): \(r.ok ? "syntax ok" : "FAILED \(r.stderr)")")
            if !ks { print(text) }
        }
        let bl = BlockListStatus(active: true, denied: ["203.0.113.0/24"], errors: [])
        print("blocklist matches 203.0.113.10: \(bl.blocks("203.0.113.10")) 8.8.8.8: \(bl.blocks("8.8.8.8"))")
        let conns = ConnectionScanner.scan(interfaces: snap.interfaces.map(\.snapshot))
        let byIf = Dictionary(grouping: conns, by: { $0.interface ?? "?" }).mapValues(\.count)
        print("connections: \(conns.count) by interface \(byIf)")
        print("full tunnels: \(NetworkFacts.fullTunnelInterfaces(routes: snap.routesV4)) network: \(snap.network?.label ?? "-")")
        for r in DNSInspector.resolvers().prefix(3) { print("resolver \(r.domain ?? "default"): \(r.nameservers) via \(r.paths)") }
        do { let u = try await UpdateChecker.latest(); print("update check: \(u.map { "newer \($0.version)" } ?? "no newer release") (repo \(UpdateChecker.repository))") }
        catch { print("update check failed: \(error.localizedDescription)") }
        let available = await Probes.availableInterfaces()
        let (def, ips) = await Probes.probePath(id: "default", title: "default", interface: nil)
        for ip in ips {
            let g = await Probes.geolocate(ip, preferred: .ipinfo)
            print("public \(ip): \(g?.location ?? "-") | \(g?.org ?? "-") | \(g?.timezone ?? "-") | \(g?.coords ?? "-")")
        }
        if def.v6 == nil { print("public IPv6: \(def.v6Error ?? "not available")") }
        for i in snap.interfaces where i.kind.isPhysical && i.isActive {
            guard let nw = available.first(where: { $0.name == i.name }) else { continue }
            let (r, _) = await Probes.probePath(id: i.name, title: i.name, interface: nw)
            print("public via \(i.name): v4=\(r.v4?.ip ?? r.v4Error ?? "-") v6=\(r.v6?.ip ?? r.v6Error ?? "-")")
        }
        exit(0)
    }

    /// `BlueIPRouter --speedtest-quick`: a 3-second check of each speed-test engine on the direct and default paths (~20–60 MB).
    @MainActor
    static func quickSpeed() async {
        let snap = await Task.detached { NetworkScanner.scan() }.value
        let available = await Probes.availableInterfaces()
        let lan = snap.interfaces.first { $0.kind.isPhysical && $0.isActive && $0.router != nil }
        let direct = lan.flatMap { l in available.first { $0.name == l.name } }
        let libre = (try? await LibreSpeedDirectory.servers()) ?? []
        print("librespeed servers: \(libre.count)")
        var servers = [SpeedServer.cloudflare]
        if let first = libre.first { servers.append(first) }
        for (label, iface) in [("direct \(direct?.name ?? "-")", direct), ("default", nil)] {
            for server in servers {
                var pings: [Double] = []
                for _ in 0..<3 { if let p = await SpeedIO.ping(server: server, interface: iface) { pings.append(p) } }
                let flag = CancelFlag()
                let down = ByteCounter(), up = ByteCounter()
                let t0 = Date(), d1 = t0.addingTimeInterval(3)
                await withTaskGroup(of: Void.self) { g in
                    for _ in 0..<2 { g.addTask { try? await SpeedIO.download(server: server, bytes: 25_000_000, interface: iface, counter: down, deadline: d1, cancel: flag) } }
                }
                let dt = Date().timeIntervalSince(t0)
                let t1 = Date(), d2 = t1.addingTimeInterval(2)
                var upErr = ""
                do { try await SpeedIO.upload(server: server, bytes: 5_000_000, interface: iface, counter: up, deadline: d2, cancel: flag) } catch { upErr = " (\(error.localizedDescription))" }
                let ut = Date().timeIntervalSince(t1)
                print(String(format: "%@ | %@ | ping %@ | down %.1f Mbps (%.1f MB) | up %.1f Mbps (%.1f MB)%@", label, server.name,
                             pings.isEmpty ? "-" : String(format: "%.0f ms", pings.min()!),
                             Double(down.value) * 8 / 1e6 / dt, Double(down.value) / 1e6,
                             Double(up.value) * 8 / 1e6 / ut, Double(up.value) / 1e6, upErr))
            }
        }
        exit(0)
    }
}
