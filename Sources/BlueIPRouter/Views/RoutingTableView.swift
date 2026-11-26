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
        let flagLegend = RouteQuery.flagLegend
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: L10n.tr("Routing Table"), subtitle: L10n.tr("Every route the kernel knows about, live")) {
                HStack {
                    Button { showLegend.toggle() } label: { Label(L10n.tr("Flags"), systemImage: "questionmark.circle") }
                        .popover(isPresented: $showLegend) { legend }
                    Button { model.showImport = true } label: { Label(L10n.tr("Import Static Routes"), systemImage: "square.and.arrow.down") }
                    Button { showAdd = true } label: { Label(L10n.tr("Add Route"), systemImage: "plus") }
                }
            }
            HStack(spacing: 12) {
                Picker("", selection: $family) {
                    Text("IPv4").tag("inet")
                    Text("IPv6").tag("inet6")
                }
                .pickerStyle(.segmented).frame(width: 140).labelsHidden()
                Picker(L10n.tr("Interface"), selection: $interfaceFilter) {
                    Text(L10n.tr("All interfaces")).tag("all")
                    ForEach(interfaces, id: \.self) { Text("\(model.displayName($0)) (\($0))").tag($0) }
                }
                .frame(width: 260)
                Toggle(L10n.tr("Hide ARP/NDP entries"), isOn: $model.workspace.settings.hideLinkLayerRoutes)
                Spacer()
                Text(L10n.tr("%lld routes", entries.count)).foregroundStyle(.secondary)
            }

            Table(entries, selection: $selection) {
                TableColumn(L10n.tr("Destination")) { e in
                    Text(e.destination).font(.body.monospaced()).textSelection(.enabled)
                }
                .width(min: 140, ideal: 200)
                TableColumn(L10n.tr("Gateway")) { e in Text(e.gateway).font(.body.monospaced()) }
                    .width(min: 120, ideal: 180)
                TableColumn(L10n.tr("Flags")) { e in
                    Text(e.flags).font(.body.monospaced())
                        .help(e.flags.compactMap { c in flagLegend.first { $0.0 == String(c) }.map { "\(c): \($0.1)" } }.joined(separator: "\n"))
                }
                .width(70)
                TableColumn(L10n.tr("Interface")) { e in
                    HStack(spacing: 4) {
                        Text(e.netif).font(.body.monospaced())
                        Text(model.displayName(e.netif)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .width(min: 120, ideal: 180)
                TableColumn(L10n.tr("Owner")) { e in
                    if let o = model.ownerInfo(of: e) {
                        Pill(text: o.text, color: o.isRule ? .green : .purple)
                    } else {
                        Text(e.isStatic ? L10n.tr("Static") : L10n.tr("System")).foregroundStyle(.secondary)
                    }
                }
                .width(min: 110, ideal: 160)
                TableColumn(L10n.tr("Expire")) { e in Text(e.expire).foregroundStyle(.secondary) }
                    .width(60)
            }
            .contextMenu(forSelectionType: RouteEntry.ID.self) { ids in
                if let id = ids.first, let e = entries.first(where: { $0.id == id }) {
                    if let cidr = e.cidr, cidr.prefix > 0 {
                        Button(L10n.tr("Check Path to %@", cidr.address)) { model.openPathCheck(cidr.address) }
                        Button(L10n.tr("Create Rule for %@", cidr.prefix == 32 ? cidr.address : "\(cidr.address)/\(cidr.prefix)")) {
                            model.selection = .rules
                            model.newRule(destination: cidr.prefix == 32 ? cidr.address : "\(cidr.address)/\(cidr.prefix)")
                        }
                        Divider()
                    }
                    Button(L10n.tr("Copy Destination")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(e.destination, forType: .string)
                    }
                    Button(L10n.tr("Delete Route…"), role: .destructive) { toDelete = e }
                }
            }
        }
        .padding(24)
        .searchable(text: $search, placement: .toolbar, prompt: Text(L10n.tr("Filter routes")))
        .confirmationDialog(L10n.tr("Delete route %@?", toDelete?.destination ?? ""), isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }), presenting: toDelete) { e in
            Button(L10n.tr("Delete Route"), role: .destructive) { Task { await model.deleteRoute(e) } }
        } message: { e in
            Text(e.isDefault ? L10n.tr("This is a default route. Removing it can cut off internet access through %@.", e.netif)
                             : L10n.tr("%@ via %@ on %@. The owning app or rule may add it back.", e.destination, e.gateway, e.netif))
        }
        .sheet(isPresented: $showAdd) { AddRouteSheet().environment(model) }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("Route flags")).font(.headline).padding(.bottom, 4)
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
            Text(L10n.tr("Add One-off Route")).font(.title2.weight(.semibold))
            Text(L10n.tr("Adds a route right now without saving it. It is not restored after reboot. To keep it, create a rule instead."))
                .foregroundStyle(.secondary)
            Form {
                TextField(L10n.tr("Destination"), text: $destination, prompt: Text(L10n.tr("1.2.3.4 or 10.0.0.0/8")))
                Picker(L10n.tr("Via"), selection: $mode) {
                    Text(L10n.tr("Interface's router")).tag(0)
                    Text(L10n.tr("Directly on interface")).tag(1)
                    Text(L10n.tr("Gateway")).tag(2)
                }
                if mode < 2 {
                    Picker(L10n.tr("Interface"), selection: $iface) {
                        ForEach(model.net.interfaces.filter { $0.isActive }) { Text("\(model.displayName($0.name)) (\($0.name))").tag($0.name) }
                    }
                } else {
                    TextField(L10n.tr("Gateway"), text: $gateway)
                }
            }
            HStack {
                Button(L10n.tr("Create Rule Instead")) {
                    dismiss()
                    model.selection = .rules
                    model.newRule(destination: destination)
                }
                Spacer()
                Button(L10n.tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("Add Route")) {
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
