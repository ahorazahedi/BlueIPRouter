import BlueIPRouterCore
import SwiftUI

struct AdaptersView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?

    var body: some View {
        @Bindable var model = model
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $selected) {
                    Section("Active") {
                        ForEach(model.visibleInterfaces.filter(\.isActive)) { row($0) }
                    }
                    Section("Inactive") {
                        ForEach(model.visibleInterfaces.filter { !$0.isActive }) { row($0) }
                    }
                }
                Divider()
                Toggle("Show system interfaces", isOn: $model.workspace.settings.showSystemInterfaces)
                    .padding(10).font(.callout)
            }
            .frame(minWidth: 250, idealWidth: 290, maxWidth: 360)

            Group {
                if let name = selected ?? model.net.primaryInterface, let info = model.interface(name) {
                    AdapterDetail(info: info).id(info.name)
                } else {
                    ContentUnavailableView("Select an adapter", systemImage: "network")
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ i: InterfaceInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: i.kind.symbol).frame(width: 22).foregroundStyle(i.isActive ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName(i.name)).fontWeight(.medium)
                Text("\(i.name) · \(i.ipv4 ?? (i.snapshot.isUp ? "no IPv4" : "down"))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(i.isActive ? .green : (i.snapshot.isUp ? .yellow : .gray)).frame(width: 8, height: 8)
        }
        .tag(i.name)
        .padding(.vertical, 2)
    }
}

struct AdapterDetail: View {
    @Environment(AppModel.self) private var model
    let info: InterfaceInfo
    @State private var alias = ""
    @State private var mtu = ""
    @State private var dns = ""
    @State private var confirm: ConfirmAction?

    enum ConfirmAction: Identifiable {
        case down, wifiOff
        var id: Int { self == .down ? 0 : 1 }
    }

    private var s: InterfaceSnapshot { info.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                HStack(alignment: .top, spacing: 16) {
                    Card("Addresses", symbol: "number") {
                        ForEach(s.ipv4, id: \.address) { a in
                            KeyValueRow(key: "IPv4", value: "\(a.address)/\(a.prefix.map(String.init) ?? "?")")
                            if let p = a.peer { KeyValueRow(key: "Peer", value: p) }
                        }
                        ForEach(s.ipv6.prefix(4), id: \.address) { a in KeyValueRow(key: "IPv6", value: a.address) }
                        if s.ipv4.isEmpty && s.ipv6.isEmpty { Text("No addresses").foregroundStyle(.secondary) }
                        KeyValueRow(key: "MAC", value: s.mac ?? "")
                        KeyValueRow(key: "Router", value: info.router ?? "")
                        KeyValueRow(key: "DNS", value: info.dns.joined(separator: ", "))
                    }
                    Card("Traffic", symbol: "arrow.up.arrow.down") {
                        KeyValueRow(key: "Download", value: formatRate(model.rates[info.name]?.rx), mono: false)
                        KeyValueRow(key: "Upload", value: formatRate(model.rates[info.name]?.tx), mono: false)
                        KeyValueRow(key: "Received", value: "\(formatBytes(s.rxBytes)) · \(s.rxPackets) pkts", mono: false)
                        KeyValueRow(key: "Sent", value: "\(formatBytes(s.txBytes)) · \(s.txPackets) pkts", mono: false)
                        KeyValueRow(key: "Errors", value: "in \(s.rxErrors) · out \(s.txErrors)", mono: false)
                        Text("Counters are 32-bit and wrap at 4 GiB.").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    Card("Configuration", symbol: "slider.horizontal.3") {
                        KeyValueRow(key: "Hardware port", value: info.hardwarePort ?? "", mono: false)
                        KeyValueRow(key: "Service", value: info.serviceName ?? "", mono: false)
                        KeyValueRow(key: "Index", value: "\(s.index)")
                        KeyValueRow(key: "MTU", value: "\(s.mtu)")
                        KeyValueRow(key: "Flags", value: s.flagNames.joined(separator: " "))
                        KeyValueRow(key: "Routes via it", value: "\(info.routeCount)")
                        HStack {
                            Text("Alias").foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                            TextField("Friendly name", text: $alias, onCommit: { model.setAlias(info.name, alias) })
                            Button("Save") { model.setAlias(info.name, alias) }
                        }
                    }
                    Card("Routes through this adapter", symbol: "arrow.triangle.branch") {
                        let routes = model.net.routesV4.filter { $0.netif == info.name && !$0.isLinkLayer }
                        if routes.isEmpty { Text("None").foregroundStyle(.secondary) }
                        ForEach(routes.prefix(14)) { r in
                            HStack {
                                Text(r.destination).font(.callout.monospaced())
                                Spacer()
                                if let o = model.owner(of: r) { Text(o).font(.caption).foregroundStyle(.secondary) }
                                Text(r.gateway).font(.callout.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        if routes.count > 14 { Text("+ \(routes.count - 14) more in Routing Table").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                actions
            }
            .padding(24)
        }
        .onAppear {
            alias = model.workspace.aliases[info.name] ?? ""
            mtu = "\(s.mtu)"
            dns = info.dns.joined(separator: " ")
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { c in
            Button(c == .down ? "Disable \(info.name)" : "Turn Wi-Fi Off", role: .destructive) {
                Task {
                    if c == .down { await model.setInterface(info.name, up: false) } else { await model.setWiFiPower(info.name, on: false) }
                }
            }
        } message: { _ in
            Text(info.name == model.net.primaryInterface ? "This is your primary connection. You will lose network access through it." : "Traffic routed through \(info.name) will stop.")
        }
    }

    private var confirmTitle: String { confirm == .wifiOff ? "Turn off Wi-Fi?" : "Disable \(info.name)?" }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: info.kind.symbol)
                .font(.system(size: 28)).foregroundStyle(.tint)
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 4) {
                Text(model.displayName(info.name)).font(.title.weight(.semibold))
                HStack(spacing: 6) {
                    Text(info.name).font(.body.monospaced()).foregroundStyle(.secondary)
                    Pill(text: info.isFullTunnel ? "Full tunnel" : info.kind.label, color: .accentColor)
                    Pill(text: s.isUp ? (s.isRunning ? "Up · Running" : "Up") : "Down", color: s.isUp ? .green : .gray)
                    if info.name == model.net.primaryInterface { Pill(text: "Primary", color: .blue) }
                    if info.name == model.net.internetRoute?.interface { Pill(text: "Carries internet traffic", color: .purple) }
                }
            }
            Spacer()
        }
    }

    private var actions: some View {
        Card("Controls", symbol: "switch.2") {
            Text("Every action asks for an administrator password. Changes made here are live and are not part of your rules.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if s.isUp {
                    Button { confirm = .down } label: { Label("Disable Interface", systemImage: "power") }
                } else {
                    Button { Task { await model.setInterface(info.name, up: true) } } label: { Label("Enable Interface", systemImage: "power") }
                }
                if info.kind == .wifi {
                    Button { confirm = .wifiOff } label: { Label("Wi-Fi Off", systemImage: "wifi.slash") }
                    Button { Task { await model.setWiFiPower(info.name, on: true) } } label: { Label("Wi-Fi On", systemImage: "wifi") }
                }
                if info.kind.isPhysical {
                    Button { Task { await model.renewDHCP(info.name) } } label: { Label("Renew DHCP", systemImage: "arrow.triangle.2.circlepath") }
                }
                Button { model.openPathCheck("1.1.1.1") } label: { Label("Test Internet Path", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
            }
            Divider()
            HStack {
                Text("MTU").frame(width: 130, alignment: .leading).foregroundStyle(.secondary)
                TextField("1500", text: $mtu).frame(width: 90).font(.body.monospaced())
                Button("Set MTU") { Task { await model.setMTU(info.name, Int(mtu) ?? 0) } }
                    .disabled(Int(mtu) == nil || Int(mtu) == s.mtu)
                Spacer()
            }
            HStack {
                Text("DNS servers").frame(width: 130, alignment: .leading).foregroundStyle(.secondary)
                TextField("1.1.1.1 8.8.8.8  (empty = automatic)", text: $dns).font(.body.monospaced())
                Button("Set DNS") {
                    let servers = dns.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
                    if let service = info.serviceName { Task { await model.setDNS(service: service, servers: servers) } }
                }
                .disabled(info.serviceName == nil)
                .help(info.serviceName == nil ? "This interface has no macOS network service, so DNS cannot be set here." : "Applies to the “\(info.serviceName!)” service")
                Button("Flush DNS Cache") { Task { await model.flushDNS() } }
            }
        }
    }
}
