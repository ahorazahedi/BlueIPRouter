import BlueIPRouterCore
import SwiftUI

struct KillSwitchView: View {
    @Environment(AppModel.self) private var model
    @State private var editingList: BlockList?
    @State private var allowText = ""
    @State private var showRules = false

    private var ks: KillSwitchConfig { model.workspace.killSwitch }
    private var live: KillSwitchStatus? { model.net.helperStatus?.killSwitch }

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Kill Switch", subtitle: "Stop traffic from leaking out of Wi-Fi or other networks when your full-tunnel VPN disconnects") {
                    Button { showRules = true } label: { Label("Preview pf Rules", systemImage: "doc.plaintext") }
                }
                PendingBanner()
                statusCard

                Card("Mode", symbol: "slider.horizontal.below.square.filled.and.square") {
                    Picker("", selection: $model.workspace.killSwitch.mode) {
                        Text("Block selected services").tag(KillSwitchConfig.Mode.destinations)
                        Text("Block everything except allowed").tag(KillSwitchConfig.Mode.fullSystem)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text(ks.mode == .destinations
                         ? "Only the services listed below are blocked on the guarded interfaces. While the VPN tunnel is up their traffic goes through it and works; when the tunnel drops, they cannot fall back to Wi-Fi or the VPN."
                         : "Everything on the guarded interfaces is blocked except your local network, the VPN server, your routing-rule destinations and DNS. Nothing can leak while the VPN is down — including normal browsing.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                Card("Guarded interfaces", symbol: "network.badge.shield.half.filled") {
                    Text("Traffic leaving through these interfaces is filtered. Never guard the tunnel itself (utun).")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(guardCandidates) { i in
                        Toggle(isOn: Binding(get: { ks.interfaces.contains(i.name) }, set: { on in
                            var list = model.workspace.killSwitch.interfaces.filter { $0 != i.name }
                            if on { list.append(i.name) }
                            model.workspace.killSwitch.interfaces = list.sorted()
                        })) {
                            HStack {
                                Image(systemName: i.kind.symbol).frame(width: 20)
                                Text("\(model.displayName(i.name)) (\(i.name))")
                                if let ip = i.ipv4 { Text(ip).font(.caption.monospaced()).foregroundStyle(.secondary) }
                                if !i.isActive { Pill(text: "Inactive", color: .secondary) }
                            }
                        }
                    }
                }

                if ks.mode == .destinations { blockListsCard } else { allowCard }
            }
            .padding(24)
        }
        .sheet(item: $editingList) { list in BlockListEditor(list: list).environment(model) }
        .sheet(isPresented: $showRules) { rulesPreview }
        .onAppear { allowText = ks.allow.joined(separator: "\n") }
    }

    private var guardCandidates: [InterfaceInfo] {
        var list = model.net.interfaces.filter { ($0.kind.isPhysical || $0.kind == .ppp || $0.kind == .ipsec) && ($0.isActive || ks.interfaces.contains($0.name)) }
        for name in ks.interfaces where !list.contains(where: { $0.name == name }) {
            list.append(InterfaceInfo(snapshot: InterfaceSnapshot(name: name), hardwarePort: nil, serviceName: nil, router: nil, dns: [],
                                      kind: NetworkScanner.classify(name: name, port: nil), isFullTunnel: false, routeCount: 0))
        }
        return list
    }

    private var statusCard: some View {
        let tunnel = model.fullTunnel
        let active = live?.active == true && live?.pfEnabled == true
        return Card {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: active ? "hand.raised.fill" : "hand.raised.slash")
                    .font(.system(size: 34)).foregroundStyle(active ? .green : .secondary)
                    .frame(width: 60, height: 60)
                    .background(RoundedRectangle(cornerRadius: 14).fill((active ? Color.green : .secondary).opacity(0.12)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(active ? "Armed" : (ks.enabled ? "On, not applied yet" : "Off")).font(.title.weight(.semibold))
                    if active {
                        Text(tunnel != nil
                             ? "Tunnel \(tunnel!.name) is up, so protected traffic flows through it. If it drops, \(live!.interfaces.joined(separator: " and ")) block it."
                             : "No tunnel is up: protected traffic is being blocked on \(live!.interfaces.joined(separator: " and ")) right now.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Uses macOS's built-in pf firewall in its own anchor (\(BIR.pfAnchor)); /etc/pf.conf is not modified.")
                            .foregroundStyle(.secondary)
                    }
                    if !model.net.service.daemonInstalled, ks.enabled {
                        Label("Turn on Persistence so the kill switch comes back after a reboot.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    ForEach(live?.errors ?? [], id: \.self) { Label($0, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red) }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { ks.enabled }, set: { on in
                    model.workspace.killSwitch.enabled = on
                    if on && model.workspace.killSwitch.interfaces.isEmpty {
                        model.workspace.killSwitch.interfaces = model.defaultGuardedInterfaces
                    }
                }))
                    .toggleStyle(.switch).controlSize(.large).labelsHidden()
                    .help("Turn on, then press Apply")
            }
            if active {
                Divider()
                HStack(spacing: 20) {
                    KeyValueRow(key: "Mode", value: live!.mode == .destinations ? "Selected services" : "Everything except allowed", mono: false)
                    KeyValueRow(key: live!.mode == .destinations ? "Blocked ranges" : "Allowed ranges",
                                value: "\(live!.mode == .destinations ? live!.blocked.count : live!.allowed.count)", mono: false)
                }
                HStack {
                    Spacer()
                    Button("Turn Off Now", role: .destructive) { Task { await model.turnOffKillSwitchNow() } }
                }
            }
        }
    }

    private var blockListsCard: some View {
        Card("Blocked services", symbol: "nosign",
             trailing: AnyView(Button { editingList = BlockList(name: "", entries: []) } label: { Label("Add List", systemImage: "plus") })) {
            if ks.blockLists.isEmpty { Text("No lists. Add one with the IP ranges or domains of a service.").foregroundStyle(.secondary) }
            ForEach(ks.blockLists) { list in
                HStack(alignment: .top) {
                    Toggle("", isOn: Binding(get: { list.enabled }, set: { v in
                        if let i = model.workspace.killSwitch.blockLists.firstIndex(where: { $0.id == list.id }) { model.workspace.killSwitch.blockLists[i].enabled = v }
                    })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(list.name).fontWeight(.medium)
                        Text("\(list.entries.count) entries · " + list.entries.prefix(5).joined(separator: ", ") + (list.entries.count > 5 ? " …" : ""))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if list.sourceURL != nil {
                        Button("Update from Source") { Task { await model.updateBlockList(list.id) } }
                            .help(list.sourceURL ?? "")
                    }
                    Button("Edit…") { editingList = list }
                    if list.id != BlockList.telegramID {
                        Button(role: .destructive) { model.workspace.killSwitch.blockLists.removeAll { $0.id == list.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                Divider()
            }
            if !ks.blockLists.contains(where: { $0.id == BlockList.telegramID }) {
                Button("Add Telegram Preset") { model.workspace.killSwitch.blockLists.insert(BlockList.telegram, at: 0) }
            }
            conflictWarning
        }
    }

    @ViewBuilder
    private var conflictWarning: some View {
        let ruleIPs = model.net.helperStatus?.installedRoutes.filter { r in ks.interfaces.contains(r.interface ?? "") }.map(\.destination) ?? []
        let blockedByRule = ruleIPs.filter { ip in ks.blockLists.filter(\.enabled).flatMap(\.entries).contains { CIDR.normalize($0).map { CIDR.contains($0, ip: ip) } ?? false } }
        if !blockedByRule.isEmpty {
            Label("Your routing rules send \(blockedByRule.joined(separator: ", ")) through a guarded interface, but a block list covers it, so it will be blocked.",
                  systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
        }
    }

    private var allowCard: some View {
        Card("Allowed through guarded interfaces", symbol: "checkmark.shield") {
            allowToggles
            Divider()
            learnedServersRow
            Divider()
            extraAllowEditor
        }
    }

    private var localNetworksLabel: String {
        let nets = NetworkFacts.attachedNetworks(model.net.interfaces.map(\.snapshot), names: ks.interfaces)
        return "Local networks (" + nets.joined(separator: ", ") + "), link-local, multicast"
    }

    private var dnsLabel: String {
        "DNS to the system resolvers (" + model.net.systemDNS.joined(separator: ", ") + ")"
    }

    @ViewBuilder
    private var allowToggles: some View {
        @Bindable var model = model
        Toggle(localNetworksLabel, isOn: $model.workspace.killSwitch.allowLocalNetworks)
        Toggle("Destinations of your routing rules", isOn: $model.workspace.killSwitch.allowRuleDestinations)
        Toggle(dnsLabel, isOn: $model.workspace.killSwitch.allowDNS)
        Toggle("DHCP (keeps Wi-Fi getting an address)", isOn: $model.workspace.killSwitch.allowDHCP)
        Toggle("Learn VPN servers automatically (xray, sing-box, v2ray, OpenVPN…)", isOn: $model.workspace.killSwitch.learnVPNServers)
    }

    private var learnedServersRow: some View {
        let learned = model.net.learnedServers
        let noTunnel = model.fullTunnel == nil
        let text: String = learned.isEmpty ? "None yet. Connect your VPN, then press Detect." : learned.joined(separator: ", ")
        let color: Color = learned.isEmpty ? .orange : .secondary
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("VPN servers learned").fontWeight(.medium)
                Text(text).font(.callout.monospaced()).foregroundStyle(color)
            }
            Spacer()
            Button("Detect VPN Servers") { Task { await model.detectVPNServers() } }
                .disabled(noTunnel)
                .help(noTunnel ? "Connect your full-tunnel VPN first" : "Finds the servers your VPN core is connected to right now")
            Button("Forget") { Task { await model.forgetLearnedServers() } }.disabled(learned.isEmpty)
        }
    }

    @ViewBuilder
    private var extraAllowEditor: some View {
        Text("Extra allowed destinations (one per line: IP, CIDR or domain)").fontWeight(.medium)
        TextEditor(text: $allowText)
            .font(.body.monospaced()).frame(minHeight: 80)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
            .onChange(of: allowText) { _, v in
                let items: [String] = v.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == " " }).map(String.init)
                model.workspace.killSwitch.allow = items
            }
        if model.net.learnedServers.isEmpty && ks.allow.isEmpty {
            Label("Without the VPN server allowed, the VPN cannot reconnect while this mode is on.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout)
        }
    }

    private func previewText() -> String {
        let cfg = ks
        let blocked: [String] = cfg.blockLists.filter(\.enabled).flatMap(\.entries).compactMap(CIDR.normalize)
        var allowed: [String] = cfg.allow.compactMap(CIDR.normalize)
        allowed += model.net.learnedServers.compactMap(CIDR.normalize)
        if cfg.allowLocalNetworks {
            allowed += NetworkFacts.attachedNetworks(model.net.interfaces.map(\.snapshot), names: cfg.interfaces)
            allowed += KillSwitchCompiler.linkLocalRanges
        }
        if cfg.allowRuleDestinations {
            allowed += model.net.helperStatus?.installedRoutes.map(\.key) ?? []
        }
        let dns: [String] = cfg.allowDNS ? model.net.systemDNS : []
        return KillSwitchCompiler.compile(mode: cfg.mode, interfaces: cfg.interfaces, blocked: blocked, allowed: allowed,
                                          dnsServers: dns, allowDHCP: cfg.allowDHCP)
    }

    private var rulesPreview: some View {
        let text = previewText()
        return VStack(alignment: .leading, spacing: 12) {
            Text("pf rules for anchor \(BIR.pfAnchor)").font(.title3.weight(.semibold))
            Text("Domains are resolved by the helper when applied, so they are not shown here.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(text).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 320)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            HStack { Spacer(); Button("Done") { showRules = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 720)
    }
}

struct BlockListEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var list: BlockList
    @State private var text = ""

    init(list: BlockList) {
        _list = State(initialValue: list)
        _text = State(initialValue: list.entries.joined(separator: "\n"))
    }

    private var entries: [String] { text.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == " " }).map(String.init) }
    private var invalid: [String] { entries.filter { KSEntry.parse($0) == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.workspace.killSwitch.blockLists.contains { $0.id == list.id } ? "Edit Block List" : "New Block List").font(.title2.weight(.semibold))
            TextField("Name", text: $list.name, prompt: Text("e.g. WhatsApp"))
            Text("IP ranges (IPv4 or IPv6 CIDR) or domains, one per line").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body.monospaced()).frame(height: 240)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
            TextField("Source URL for updates (optional, plain list of CIDRs)", text: Binding(get: { list.sourceURL ?? "" }, set: { list.sourceURL = $0.isEmpty ? nil : $0 }))
            if !invalid.isEmpty { Label("Invalid: \(invalid.joined(separator: ", "))", systemImage: "exclamationmark.circle").foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    list.entries = entries
                    if let i = model.workspace.killSwitch.blockLists.firstIndex(where: { $0.id == list.id }) {
                        model.workspace.killSwitch.blockLists[i] = list
                    } else {
                        model.workspace.killSwitch.blockLists.append(list)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(list.name.trimmingCharacters(in: .whitespaces).isEmpty || entries.isEmpty || !invalid.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
