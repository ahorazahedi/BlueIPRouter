import BlueIPRouterCore
import SwiftUI

struct RoutingTableView: View {
    @Environment(AppModel.self) private var model
    @State private var family = "inet"
    @State private var interfaceFilter = "all"
    @State private var search = ""
    @State private var selection = Set<RouteEntry.ID>()
    @State private var toDelete: RouteEntry?
    @State private var showAdd = false
    @State private var showLegend = false

    private var entries: [RouteEntry] {
        let all = family == "inet" ? model.net.routesV4 : model.net.routesV6
        let hideLL = model.workspace.settings.hideLinkLayerRoutes
        let q = search.lowercased()
        return all.filter { e in
            (interfaceFilter == "all" || e.netif == interfaceFilter)
                && (!hideLL || !e.isLinkLayer)
                && (q.isEmpty || e.destination.lowercased().contains(q) || e.gateway.lowercased().contains(q)
                    || e.netif.contains(q) || (model.owner(of: e)?.lowercased().contains(q) ?? false))
        }
    }

    private var interfaces: [String] {
        Array(Set((family == "inet" ? model.net.routesV4 : model.net.routesV6).map(\.netif))).sorted()
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Routing Table", subtitle: "Every route the kernel knows about, live") {
                HStack {
                    Button { showLegend.toggle() } label: { Label("Flags", systemImage: "questionmark.circle") }
                        .popover(isPresented: $showLegend) { legend }
                    Button { model.showImport = true } label: { Label("Import Static Routes", systemImage: "square.and.arrow.down") }
                    Button { showAdd = true } label: { Label("Add Route", systemImage: "plus") }
                }
            }
            HStack(spacing: 12) {
                Picker("", selection: $family) {
                    Text("IPv4").tag("inet")
                    Text("IPv6").tag("inet6")
                }
                .pickerStyle(.segmented).frame(width: 140).labelsHidden()
                Picker("Interface", selection: $interfaceFilter) {
                    Text("All interfaces").tag("all")
                    ForEach(interfaces, id: \.self) { Text("\(model.displayName($0)) (\($0))").tag($0) }
                }
                .frame(width: 260)
                Toggle("Hide ARP/NDP entries", isOn: $model.workspace.settings.hideLinkLayerRoutes)
                Spacer()
                Text("\(entries.count) routes").foregroundStyle(.secondary)
            }

            Table(entries, selection: $selection) {
                TableColumn("Destination") { e in
                    Text(e.destination).font(.body.monospaced()).textSelection(.enabled)
                }
                .width(min: 140, ideal: 200)
                TableColumn("Gateway") { e in Text(e.gateway).font(.body.monospaced()) }
                    .width(min: 120, ideal: 180)
                TableColumn("Flags") { e in
                    Text(e.flags).font(.body.monospaced())
                        .help(e.flags.compactMap { c in RouteQuery.flagLegend.first { $0.0 == String(c) }.map { "\(c): \($0.1)" } }.joined(separator: "\n"))
                }
                .width(70)
                TableColumn("Interface") { e in
                    HStack(spacing: 4) {
                        Text(e.netif).font(.body.monospaced())
                        Text(model.displayName(e.netif)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .width(min: 120, ideal: 180)
                TableColumn("Owner") { e in
                    if let o = model.owner(of: e) {
                        Pill(text: o, color: o.hasPrefix("Rule") ? .green : .purple)
                    } else {
                        Text(e.isStatic ? "Static" : "System").foregroundStyle(.secondary)
                    }
                }
                .width(min: 110, ideal: 160)
                TableColumn("Expire") { e in Text(e.expire).foregroundStyle(.secondary) }
                    .width(60)
            }
            .contextMenu(forSelectionType: RouteEntry.ID.self) { ids in
                if let id = ids.first, let e = entries.first(where: { $0.id == id }) {
                    if let cidr = e.cidr, cidr.prefix > 0 {
                        Button("Check Path to \(cidr.address)") { model.openPathCheck(cidr.address) }
                        Button("Create Rule for \(cidr.prefix == 32 ? cidr.address : "\(cidr.address)/\(cidr.prefix)")") {
                            model.selection = .rules
                            model.newRule(destination: cidr.prefix == 32 ? cidr.address : "\(cidr.address)/\(cidr.prefix)")
                        }
                        Divider()
                    }
                    Button("Copy Destination") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(e.destination, forType: .string)
                    }
                    Button("Delete Route…", role: .destructive) { toDelete = e }
                }
            }
        }
        .padding(24)
        .searchable(text: $search, placement: .toolbar, prompt: "Filter routes")
        .confirmationDialog("Delete route \(toDelete?.destination ?? "")?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }), presenting: toDelete) { e in
            Button("Delete Route", role: .destructive) { Task { await model.deleteRoute(e) } }
        } message: { e in
            Text(e.isDefault ? "This is a default route. Removing it can cut off internet access through \(e.netif)."
                             : "\(e.destination) via \(e.gateway) on \(e.netif). The owning app or rule may add it back.")
        }
        .sheet(isPresented: $showAdd) { AddRouteSheet().environment(model) }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Route flags").font(.headline).padding(.bottom, 4)
            ForEach(RouteQuery.flagLegend, id: \.0) { f in
                HStack {
                    Text(f.0).font(.body.monospaced()).frame(width: 20)
                    Text(f.1)
                }
            }
        }
        .padding()
    }
}

struct AddRouteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""
    @State private var mode = 0
    @State private var iface = ""
    @State private var gateway = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add One-off Route").font(.title2.weight(.semibold))
            Text("Adds a route right now without saving it. It is not restored after reboot. To keep it, create a rule instead.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Destination", text: $destination, prompt: Text("1.2.3.4 or 10.0.0.0/8"))
                Picker("Via", selection: $mode) {
                    Text("Interface's router").tag(0)
                    Text("Directly on interface").tag(1)
                    Text("Gateway").tag(2)
                }
                if mode < 2 {
                    Picker("Interface", selection: $iface) {
                        ForEach(model.net.interfaces.filter { $0.isActive }) { Text("\(model.displayName($0.name)) (\($0.name))").tag($0.name) }
                    }
                } else {
                    TextField("Gateway", text: $gateway)
                }
            }
            HStack {
                Button("Create Rule Instead") {
                    dismiss()
                    model.selection = .rules
                    model.newRule(destination: destination)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Route") {
                    let via: RouteVia = mode == 0 ? .interfaceRouter(iface) : (mode == 1 ? .interfaceDirect(iface) : .gateway(gateway))
                    dismiss()
                    Task { await model.addOneOffRoute(destination: destination, via: via) }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(Destination.parse(destination) == nil)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { iface = model.localInterface?.name ?? model.net.primaryInterface ?? "" }
    }
}
