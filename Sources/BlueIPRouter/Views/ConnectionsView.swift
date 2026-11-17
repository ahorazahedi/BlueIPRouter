import BlueIPRouterCore
import SwiftUI

/// Live list of which app talks to which address, and through which interface.
struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    @State private var connections: [LiveConnection] = []
    @State private var search = ""
    @State private var interfaceFilter = "all"
    @State private var leaksOnly = false
    @State private var paused = false
    @State private var selection = Set<LiveConnection.ID>()
    @State private var updated: Date?

    private var tunnel: String? { model.fullTunnel?.name }

    /// Traffic leaving outside the full tunnel to a public address that no rule sends there on purpose.
    private func isLeak(_ c: LiveConnection) -> Bool {
        guard let tunnel, let i = c.interface, i != tunnel, !i.hasPrefix("lo") else { return false }
        if IPv4.isValid(c.remoteIP) && IPv4.isPrivate(c.remoteIP) { return false }
        if c.remoteIP.hasPrefix("fe80") || c.remoteIP.hasPrefix("fd") || c.remoteIP == "::1" { return false }
        let managed = model.net.helperStatus?.installedRoutes.contains { r in
            IPv4.isValid(c.remoteIP) && IPv4.contains(network: r.destination, prefix: r.prefix, ip: c.remoteIP)
        } ?? false
        return !managed
    }

    private var rows: [LiveConnection] {
        let q = search.lowercased()
        return connections.filter { c in
            (interfaceFilter == "all" || c.interface == interfaceFilter)
                && (!leaksOnly || isLeak(c))
                && (q.isEmpty || c.process.lowercased().contains(q) || c.remoteIP.contains(q) || c.remotePort == q)
        }
        .sorted { ($0.process.lowercased(), $0.remoteIP) < ($1.process.lowercased(), $1.remoteIP) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Connections", subtitle: "Which app is talking to which address, and through which interface — live") {
                HStack {
                    if let updated { Text("Updated \(updated.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                    Button { paused.toggle() } label: { Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") }
                }
            }
            summary
            HStack(spacing: 12) {
                Picker("Interface", selection: $interfaceFilter) {
                    Text("All interfaces").tag("all")
                    ForEach(Array(Set(connections.compactMap(\.interface))).sorted(), id: \.self) {
                        Text("\(model.displayName($0)) (\($0))").tag($0)
                    }
                }
                .frame(width: 280)
                Toggle("Only traffic outside the VPN tunnel", isOn: $leaksOnly)
                    .disabled(tunnel == nil)
                    .help(tunnel == nil ? "No full-tunnel VPN is up" : "Public destinations reached outside \(tunnel!) that no rule routes on purpose")
                Spacer()
                Text("\(rows.count) connections").foregroundStyle(.secondary)
            }
            Table(rows, selection: $selection) {
                TableColumn("App") { c in
                    HStack(spacing: 6) {
                        if isLeak(c) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Outside the VPN tunnel") }
                        Text(c.process).fontWeight(.medium)
                        Text("\(c.pid)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .width(min: 150, ideal: 200)
                TableColumn("Remote") { c in Text("\(c.remoteIP):\(c.remotePort)").font(.callout.monospaced()).textSelection(.enabled) }
                    .width(min: 160, ideal: 240)
                TableColumn("Proto") { c in Text(c.proto) }.width(50)
                TableColumn("State") { c in Text(c.state.isEmpty ? "—" : c.state).foregroundStyle(.secondary) }.width(min: 80, ideal: 100)
                TableColumn("Interface") { c in
                    if let i = c.interface {
                        Pill(text: "\(model.displayName(i)) (\(i))", color: i == tunnel ? .purple : (isLeak(c) ? .orange : .secondary))
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                .width(min: 150, ideal: 200)
                TableColumn("Local") { c in Text("\(c.localIP):\(c.localPort)").font(.caption.monospaced()).foregroundStyle(.secondary) }
            }
            .contextMenu(forSelectionType: LiveConnection.ID.self) { ids in
                if let id = ids.first, let c = connections.first(where: { $0.id == id }) {
                    Button("Check Path to \(c.remoteIP)") { model.openPathCheck(c.remoteIP) }
                    if IPv4.isValid(c.remoteIP) {
                        Button("Create Rule for \(c.remoteIP)…") { model.selection = .rules; model.newRule(destination: c.remoteIP) }
                    }
                    Button("Block \(c.remoteIP)…", role: .destructive) {
                        Task { await model.blockAndApply(c.remoteIP, note: "Blocked from Connections (\(c.process))") }
                    }
                    Button("Copy Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(c.remoteIP, forType: .string)
                    }
                }
            }
            Text("Shows your own apps' connections. Processes running as root (VPN cores, system daemons) are not listed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .searchable(text: $search, placement: .toolbar, prompt: "Filter by app, IP or port")
        .task {
            while !Task.isCancelled {
                if !paused { await reload() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func reload() async {
        let snaps = model.net.interfaces.map(\.snapshot)
        connections = await Task.detached { ConnectionScanner.scan(interfaces: snaps) }.value
        updated = Date()
    }

    private var summary: some View {
        let byInterface = Dictionary(grouping: connections, by: { $0.interface ?? "?" })
        let leaks = connections.filter(isLeak)
        return HStack(spacing: 12) {
            ForEach(byInterface.keys.sorted(), id: \.self) { key in
                let list = byInterface[key] ?? []
                StatChip(title: key == "?" ? "Unknown" : "\(model.displayName(key)) (\(key))",
                         value: "\(list.count)", detail: "\(Set(list.map(\.process)).count) apps",
                         tint: key == tunnel ? .purple : .blue)
            }
            if tunnel != nil {
                StatChip(title: "Outside the tunnel", value: "\(leaks.count)",
                         detail: leaks.isEmpty ? "nothing leaking" : Set(leaks.map(\.process)).sorted().prefix(3).joined(separator: ", "),
                         tint: leaks.isEmpty ? .green : .orange)
            }
        }
    }
}

struct StatChip: View {
    var title: String
    var value: String
    var detail: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(minWidth: 150, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}
