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
}
