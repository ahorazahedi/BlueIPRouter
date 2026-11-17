import BlueIPRouterCore
import SwiftUI

/// One resolver from `scutil --dns` and the path packets to it take.
struct SystemResolver: Identifiable, Hashable, Sendable {
    var id: Int
    var domain: String?
    var nameservers: [String]
    var interface: String?
    var paths: [String: String]
}

enum DNSInspector {
    static func resolvers() -> [SystemResolver] {
        let out = Shell.run("/usr/sbin/scutil", ["--dns"], timeout: 8).stdout
        let main = out.components(separatedBy: "DNS configuration (for scoped queries)").first ?? out
        var list: [SystemResolver] = []
        for (n, block) in main.components(separatedBy: "resolver #").dropFirst().enumerated() {
            var r = SystemResolver(id: n, domain: nil, nameservers: [], interface: nil, paths: [:])
            for line in block.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                let value = t.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if t.hasPrefix("nameserver[") { r.nameservers.append(value) }
                if t.hasPrefix("domain ") || t.hasPrefix("domain:") { r.domain = value }
                if t.hasPrefix("if_index"), let o = t.firstIndex(of: "("), let c = t.firstIndex(of: ")") {
                    r.interface = String(t[t.index(after: o)..<c])
                }
            }
            guard !r.nameservers.isEmpty else { continue }
            for ns in r.nameservers where IPv4.isValid(ns) {
                r.paths[ns] = RouteQuery.lookup(ns)?.interface
            }
            list.append(r)
        }
        return list
    }
}

struct DNSLeakResult: Sendable {
    struct Server: Identifiable, Hashable, Sendable {
        var ip: String
        var country: String?
        var countryCode: String?
        var asn: String?
        var id: String { ip }
        var flag: String? { IPIdentity(ip: ip, country: countryCode).flag }
    }
    var yourIP: Server?
    var servers: [Server]
    var conclusion: String?
}

extension Probes {
    /// The classic DNS leak test (bash.ws): resolve unique names, then ask which resolvers fetched them.
    static func dnsLeakTest() async throws -> DNSLeakResult {
        let (idData, _) = try await httpsGet(host: "bash.ws", path: "/id", interface: nil)
        let id = String(decoding: split(idData).body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { throw ProbeError.badResponse("Leak test service did not return an id") }
        await withTaskGroup(of: Void.self) { group in
            for i in 1...10 {
                group.addTask { _ = Resolver.resolve("\(i).\(id).bash.ws", timeout: 3) }
            }
        }
        let (data, _) = try await httpsGet(host: "bash.ws", path: "/dnsleak/test/\(id)?json", interface: nil, timeout: 12)
        guard let arr = try JSONSerialization.jsonObject(with: split(data).body) as? [[String: Any]] else {
            throw ProbeError.badResponse("Unexpected leak test response")
        }
        var result = DNSLeakResult(yourIP: nil, servers: [], conclusion: nil)
        for o in arr {
            let s = DNSLeakResult.Server(ip: o["ip"] as? String ?? "", country: o["country_name"] as? String,
                                         countryCode: (o["country"] as? String)?.uppercased(), asn: o["asn"] as? String)
            switch o["type"] as? String {
            case "ip": result.yourIP = s
            case "dns": result.servers.append(s)
            case "conclusion": result.conclusion = o["ip"] as? String
            default: break
            }
        }
        return result
    }
}

struct DNSView: View {
    @Environment(AppModel.self) private var model
    @State private var resolvers: [SystemResolver] = []
    @State private var leak: DNSLeakResult?
    @State private var leakError: String?
    @State private var testing = false
    @State private var editing: DomainResolver?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "DNS", subtitle: "Which servers answer your lookups, whether they bypass the VPN, and per-domain resolvers") {
                    Button { Task { await reload() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                }
                PendingBanner()
                leakCard
                systemCard
                perDomainCard
            }
            .padding(24)
        }
        .task { await reload() }
        .sheet(item: $editing) { r in ResolverEditor(resolver: r).environment(model) }
    }

    private func reload() async {
        resolvers = await Task.detached { DNSInspector.resolvers() }.value
    }

    private var tunnel: String? { model.fullTunnel?.name }

    private var leakCard: some View {
        Card("DNS leak test", symbol: "drop.triangle",
             trailing: AnyView(Button {
                 Task {
                     testing = true
                     leakError = nil
                     do { leak = try await Probes.dnsLeakTest() } catch { leakError = error.localizedDescription }
                     testing = false
                     model.log("DNS leak test", ok: leakError == nil, leak?.servers.map { "\($0.ip) \($0.country ?? "")" }.joined(separator: "\n") ?? leakError ?? "")
                 }
             } label: {
                 if testing { ProgressView().controlSize(.small) } else { Label("Run Test", systemImage: "play.fill") }
             }.disabled(testing))) {
            Text("Looks up random names and asks bash.ws which DNS servers fetched them. If those servers belong to your local ISP while you expect the VPN's, DNS is leaking. Uses bash.ws, a third-party service.")
                .font(.callout).foregroundStyle(.secondary)
            if let e = leakError { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let leak {
                if let ip = leak.yourIP {
                    KeyValueRow(key: "Your IP", value: "\(ip.flag ?? "") \(ip.ip) · \(ip.country ?? "") \(ip.asn ?? "")", mono: false)
                }
                ForEach(leak.servers) { s in
                    KeyValueRow(key: "DNS server", value: "\(s.flag ?? "") \(s.ip) · \(s.country ?? "") \(s.asn ?? "")", mono: false)
                }
                if let c = leak.conclusion {
                    let leaking = c.localizedCaseInsensitiveContains("leak") && !c.localizedCaseInsensitiveContains("not leak")
                    Label(c, systemImage: leaking ? "exclamationmark.octagon.fill" : "checkmark.shield.fill")
                        .foregroundStyle(leaking ? .red : .green)
                }
            }
        }
    }

    private var systemCard: some View {
        Card("Resolvers macOS uses", symbol: "server.rack") {
            if resolvers.isEmpty { Text("Loading…").foregroundStyle(.secondary) }
            ForEach(resolvers) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(r.domain.map { "For *.\($0)" } ?? "Default (all other names)").fontWeight(.medium)
                        if let i = r.interface { Pill(text: "\(model.displayName(i)) (\(i))", color: .secondary) }
                        Spacer()
                    }
                    ForEach(r.nameservers, id: \.self) { ns in
                        HStack {
                            Text(ns).font(.callout.monospaced())
                            if let via = r.paths[ns] {
                                Text("reached via \(model.displayName(via)) (\(via))").font(.caption).foregroundStyle(.secondary)
                                if let tunnel, via != tunnel, !(IPv4.isPrivate(ns) && r.domain != nil) {
                                    Pill(text: "Outside the VPN tunnel", color: .orange, symbol: "exclamationmark.triangle")
                                }
                            }
                        }
                    }
                }
                Divider()
            }
            Text("A resolver reached outside the tunnel sees which sites you look up. Fix it with a per-domain resolver below, DNS settings on the adapter, or the VPN's own DNS option.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var perDomainCard: some View {
        Card("Per-domain resolvers", symbol: "arrow.triangle.branch",
             trailing: AnyView(Button { editing = DomainResolver(domain: "", nameservers: []) } label: { Label("Add", systemImage: "plus") })) {
            Text("Send lookups for a domain and its subdomains to specific name servers (for example an internal domain to your company or university DNS). Written to /etc/resolver by the background service.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(model.workspace.automation.resolvers) { r in
                HStack {
                    Toggle("", isOn: Binding(get: { r.enabled }, set: { v in
                        if let i = model.workspace.automation.resolvers.firstIndex(where: { $0.id == r.id }) { model.workspace.automation.resolvers[i].enabled = v }
                    })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    Text("*.\(r.domain)").font(.body.monospaced())
                    Text("→ \(r.nameservers.joined(separator: ", "))").font(.callout.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    if model.net.helperStatus?.resolvers?.active.contains(r.domain.lowercased()) == true { Pill(text: "Active", color: .green) }
                    Button("Edit…") { editing = r }
                    Button(role: .destructive) { model.workspace.automation.resolvers.removeAll { $0.id == r.id } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            ForEach(model.net.helperStatus?.resolvers?.errors ?? [], id: \.self) { Label($0, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout) }
            let foreign = model.net.resolverFiles.filter { !$0.managed }
            if !foreign.isEmpty {
                Divider()
                Text("Other files in /etc/resolver (not managed by BlueIPRouter)").font(.caption).foregroundStyle(.secondary)
                ForEach(foreign, id: \.domain) { f in
                    Text("*.\(f.domain) → \(f.nameservers.joined(separator: ", "))").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ResolverEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var resolver: DomainResolver
    @State private var servers = ""

    init(resolver: DomainResolver) {
        _resolver = State(initialValue: resolver)
        _servers = State(initialValue: resolver.nameservers.joined(separator: " "))
    }

    private var draft: DomainResolver {
        var r = resolver
        r.domain = r.domain.trimmingCharacters(in: .whitespaces).lowercased()
        r.nameservers = servers.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" }).map(String.init)
        return r
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Per-domain Resolver").font(.title2.weight(.semibold))
            Form {
                TextField("Domain", text: $resolver.domain, prompt: Text("example.com"))
                TextField("Name servers", text: $servers, prompt: Text("10.0.0.53 10.0.0.54"))
                Toggle("Enabled", isOn: $resolver.enabled)
            }
            Text("Tip: if the name server is only reachable through a VPN, also add a routing rule that sends its IP through that VPN.")
                .font(.caption).foregroundStyle(.secondary)
            if let e = draft.validationError { Label(e, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let i = model.workspace.automation.resolvers.firstIndex(where: { $0.id == resolver.id }) {
                        model.workspace.automation.resolvers[i] = draft
                    } else {
                        model.workspace.automation.resolvers.append(draft)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(draft.validationError != nil)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
