import BlueIPRouterCore
import SwiftUI

struct RulesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<UUID>()
    @State private var search = ""
    @State private var confirmDelete = false

    private var rules: [RouteRule] {
        let q = search.lowercased()
        guard !q.isEmpty else { return model.workspace.rules }
        return model.workspace.rules.filter {
            $0.name.lowercased().contains(q) || $0.destinations.contains { $0.contains(q) } || $0.notes.lowercased().contains(q)
        }
    }

    private var pendingIDs: Set<UUID> { Set(model.pendingChanges.map(\.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Routing Rules", subtitle: "Send IPs, networks or domains out of the interface you choose") {
                HStack {
                    Button { model.showImport = true } label: { Label("Import Static Routes", systemImage: "square.and.arrow.down") }
                        .help("Turn routes added by hand or by scripts into managed rules")
                    Button { model.newRule() } label: { Label("New Rule", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                }
            }
            PendingBanner()
            if !model.net.service.daemonInstalled, model.workspace.rules.contains(where: \.persistent) {
                Banner(symbol: "exclamationmark.triangle", tint: .yellow, title: "Persistent rules need the background service",
                       message: "Without it, routes are not restored after a reboot or network change.",
                       actions: AnyView(Button("Turn On") { Task { await model.setService(enabled: true) } }))
            }

            if model.workspace.rules.isEmpty {
                ContentUnavailableView {
                    Label("No routing rules", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("Create a rule to send a domain or IP directly over Wi-Fi, through a VPN, or via a specific gateway.")
                } actions: {
                    Button("New Rule") { model.newRule() }.buttonStyle(.borderedProminent)
                    Button("Import Existing Static Routes…") { model.showImport = true }
                }
                .frame(maxHeight: .infinity)
            } else {
                table
            }
        }
        .padding(24)
        .searchable(text: $search, placement: .toolbar, prompt: "Search rules")
        .confirmationDialog("Delete \(selection.count) rule\(selection.count == 1 ? "" : "s")?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteRules(selection); selection = [] }
        } message: {
            Text("Their routes are removed when you apply changes.")
        }
    }

    private var table: some View {
        Table(rules, selection: $selection) {
            TableColumn("On") { rule in
                Toggle("", isOn: Binding(get: { rule.enabled }, set: { model.setEnabled(rule.id, $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            .width(44)
            TableColumn("Name") { rule in
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.name).fontWeight(.medium)
                    if !rule.notes.isEmpty { Text(rule.notes).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("Destinations") { rule in
                Text(rule.destinations.joined(separator: ", ")).font(.callout.monospaced()).lineLimit(2)
                    .help(rule.destinations.joined(separator: "\n"))
            }
            .width(min: 160, ideal: 260)
            TableColumn("Route via") { rule in
                Text(model.describe(rule.via)).lineLimit(1)
            }
            .width(min: 160, ideal: 230)
            TableColumn("Persistence") { rule in
                Toggle(isOn: Binding(get: { rule.persistent }, set: { model.setPersistent(rule.id, $0) })) {
                    Text(rule.persistent ? "Persistent" : "Until reboot")
                }
                .toggleStyle(.checkbox)
                .help(rule.persistent ? "Restored at boot by the background service" : "Removed at the next reboot")
            }
            .width(min: 110, ideal: 120)
            TableColumn("Status") { rule in
                let st = model.status(for: rule)
                let live = model.net.liveRoutes[rule.id]
                ruleStateView(st, rule: rule, pending: pendingIDs.contains(rule.id), live: live)
                    .help(pendingIDs.contains(rule.id) && live?.allLive == true
                          ? "All \(live!.expected) routes of this rule already exist on this Mac, but BlueIPRouter does not manage them yet. Apply to take them over and keep them after reboot."
                          : (st?.messages ?? []).joined(separator: "\n"))
            }
            .width(min: 110, ideal: 130)
            TableColumn("Resolved / Routes") { rule in
                let st = model.status(for: rule)
                Text(resolvedSummary(st)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    .help(((st?.routes ?? []) + (st?.messages ?? [])).joined(separator: "\n"))
            }
            .width(min: 140, ideal: 220)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let id = ids.first, let rule = model.workspace.rules.first(where: { $0.id == id }) {
                Button("Edit…") { model.editingRule = rule }
                Button("Duplicate") { model.duplicate(rule) }
                Button(rule.enabled ? "Disable" : "Enable") { model.setEnabled(id, !rule.enabled) }
                if let first = rule.destinations.first {
                    Button("Check Path for \(first)") { model.openPathCheck(first) }
                }
                Divider()
            }
            Button("Delete", role: .destructive) { selection = ids; confirmDelete = true }
        } primaryAction: { ids in
            if let id = ids.first, let rule = model.workspace.rules.first(where: { $0.id == id }) { model.editingRule = rule }
        }
        .onDeleteCommand { if !selection.isEmpty { confirmDelete = true } }
    }

    private func resolvedSummary(_ st: RuleStatus?) -> String {
        guard let st else { return "—" }
        if !st.resolved.isEmpty {
            return st.resolved.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.joined(separator: ", "))" }.joined(separator: "\n")
        }
        if let m = st.messages.first { return m }
        return st.routes.joined(separator: "\n")
    }
}

// MARK: - Editor

struct RuleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var rule: RouteRule
    @State private var destinationsText = ""
    @State private var mode = 0
    @State private var interfaceName = ""
    @State private var gateway = ""
    @State private var preview: [String: [String]] = [:]
    @State private var resolving = false

    init(rule: RouteRule) {
        _rule = State(initialValue: rule)
        _destinationsText = State(initialValue: rule.destinations.joined(separator: "\n"))
        switch rule.via {
        case .interfaceRouter(let i): _mode = State(initialValue: 0); _interfaceName = State(initialValue: i)
        case .interfaceDirect(let i): _mode = State(initialValue: 1); _interfaceName = State(initialValue: i)
        case .gateway(let g): _mode = State(initialValue: 2); _gateway = State(initialValue: g)
        }
    }

    private var isNew: Bool { !model.workspace.rules.contains { $0.id == rule.id } }

    private var draft: RouteRule {
        var r = rule
        r.destinations = destinationsText.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        switch mode {
        case 0: r.via = .interfaceRouter(interfaceName)
        case 1: r.via = .interfaceDirect(interfaceName)
        default: r.via = .gateway(gateway.trimmingCharacters(in: .whitespaces))
        }
        return r
    }

    private var interfaceChoices: [InterfaceInfo] {
        var list = model.net.interfaces.filter { !$0.isSystemNoise || $0.name == interfaceName }
        if !list.contains(where: { $0.name == interfaceName }) {
            list.append(InterfaceInfo(snapshot: InterfaceSnapshot(name: interfaceName),
                                      hardwarePort: nil, serviceName: nil, router: nil, dns: [], kind: .other, isFullTunnel: false, routeCount: 0))
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "arrow.triangle.branch").font(.title2).foregroundStyle(.tint)
                Text(isNew ? "New Routing Rule" : "Edit Routing Rule").font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(20)
            Divider()
            Form {
                Section("General") {
                    TextField("Name", text: $rule.name, prompt: Text("e.g. Office servers direct"))
                    Toggle("Enabled", isOn: $rule.enabled)
                    Picker("Persistence", selection: $rule.persistent) {
                        Text("Persistent — restored after reboot").tag(true)
                        Text("Until reboot").tag(false)
                    }
                    TextField("Notes", text: $rule.notes, prompt: Text("Optional"))
                    Toggle("Leave routes in place when this rule is removed",
                           isOn: Binding(get: { rule.keepRoutesOnRemove ?? false }, set: { rule.keepRoutesOnRemove = $0 ? true : nil }))
                        .help("Use for routes another app also needs, like a VPN server's own route.")
                }
                Section {
                    TextEditor(text: $destinationsText)
                        .font(.body.monospaced())
                        .frame(minHeight: 90)
                    destinationChips
                } header: {
                    Text("Destinations")
                } footer: {
                    Text("One per line: an IPv4 address (203.0.113.10), a network (10.20.0.0/16) or a domain (example.com). Domains are resolved to their IPv4 addresses and re-checked by the background service.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Send traffic via") {
                    Picker("Mode", selection: $mode) {
                        Text("Interface's router").tag(0)
                        Text("Directly on interface").tag(1)
                        Text("Specific gateway").tag(2)
                    }
                    .pickerStyle(.segmented)
                    if mode < 2 {
                        Picker("Interface", selection: $interfaceName) {
                            ForEach(interfaceChoices) { i in
                                Text("\(model.displayName(i.name)) — \(i.name)\(i.ipv4.map { " · \($0)" } ?? "")\(i.isActive ? "" : " (inactive)")")
                                    .tag(i.name)
                            }
                        }
                        Text(modeHelp).font(.caption).foregroundStyle(.secondary)
                    } else {
                        TextField("Gateway IP", text: $gateway, prompt: Text("192.168.1.1"))
                            .font(.body.monospaced())
                    }
                }
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(previewCommands, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                    Button { Task { await resolvePreview() } } label: {
                        if resolving { ProgressView().controlSize(.small) } else { Label("Resolve domains now", systemImage: "magnifyingglass") }
                    }
                    .disabled(!draft.parsedDestinations.contains { if case .domain = $0 { return true }; return false })
                } header: {
                    Text("What will run")
                }
                if !draft.validationErrors.isEmpty {
                    Section {
                        ForEach(draft.validationErrors, id: \.self) { Label($0, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { model.deleteRules([rule.id]); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { model.upsert(draft); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.validationErrors.isEmpty)
                Button("Save & Apply") {
                    model.upsert(draft)
                    dismiss()
                    Task { await model.apply() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!draft.validationErrors.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 640, height: 760)
    }

    private var modeHelp: String {
        let info = model.interface(interfaceName)
        if mode == 0 {
            if let r = info?.router { return "Uses \(interfaceName)'s current router (\(r)). If the router changes (e.g. another Wi-Fi network), routes follow it automatically." }
            if info?.snapshot.isPointToPoint == true { return "\(interfaceName) is point-to-point, so traffic is sent directly on it." }
            return "\(interfaceName) has no router right now; the rule waits until it gets one."
        }
        return "Sends packets straight out of \(interfaceName) without a gateway. Use this for VPN/PPP/tunnel interfaces."
    }

    private var destinationChips: some View {
        let parts = draft.destinations
        return FlowLayout(spacing: 6) {
            ForEach(parts, id: \.self) { p in
                if let d = Destination.parse(p) {
                    Pill(text: "\(d.kindLabel): \(d.display)", color: .accentColor)
                } else {
                    Pill(text: "Invalid: \(p)", color: .red, symbol: "exclamationmark.triangle")
                }
            }
        }
    }

    private var previewCommands: [String] {
        let r = draft
        var hop: String
        switch r.via {
        case .interfaceRouter(let i):
            if let router = model.interface(i)?.router { hop = router } else { hop = "-interface \(i)" }
        case .interfaceDirect(let i): hop = "-interface \(i)"
        case .gateway(let g): hop = g.isEmpty ? "<gateway>" : g
        }
        var lines: [String] = []
        for d in r.parsedDestinations {
            switch d {
            case .host(let ip): lines.append("route -n add -host \(ip) \(hop)")
            case .network(let a, let p): lines.append("route -n add -net \(a)/\(p) \(hop)")
            case .domain(let name):
                if let ips = preview[name] {
                    lines += ips.map { "route -n add -host \($0) \(hop)    # \(name)" }
                } else {
                    lines.append("route -n add -host <each IPv4 of \(name)> \(hop)")
                }
            }
        }
        return lines.isEmpty ? ["Add a destination to see the commands."] : lines
    }

    private func resolvePreview() async {
        resolving = true
        defer { resolving = false }
        let names: [String] = draft.parsedDestinations.compactMap { if case .domain(let n) = $0 { return n }; return nil }
        let result = await Task.detached { () -> [String: [String]] in
            var out: [String: [String]] = [:]
            for n in names { out[n] = Resolver.resolve(n) ?? ["(no IPv4 address)"] }
            return out
        }.value
        preview = result
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 500
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
