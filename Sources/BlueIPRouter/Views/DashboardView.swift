import BlueIPRouterCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: L10n.tr("Dashboard"), subtitle: L10n.tr("Where your traffic goes right now")) {
                    Button { model.selection = .pathCheck } label: { Label(L10n.tr("Check a Path"), systemImage: "magnifyingglass") }
                }

                if let u = model.availableUpdate {
                    Banner(symbol: "arrow.down.circle", tint: .blue, title: L10n.tr("BlueIPRouter %@ is available", u.version),
                           message: L10n.tr("You have %@. Download the new version and replace the app in Applications.", BIR.version),
                           actions: AnyView(HStack {
                               Button(L10n.tr("Release Notes")) { NSWorkspace.shared.open(u.pageURL) }
                               Button(L10n.tr("Download")) { NSWorkspace.shared.open(u.downloadURL ?? u.pageURL) }.buttonStyle(.borderedProminent)
                           }))
                }
                if model.daemonOutdated {
                    Banner(symbol: "arrow.triangle.2.circlepath", tint: .orange, title: L10n.tr("Background service needs an update"),
                           message: L10n.tr("The installed helper (%@) is older than this app (%@). Update it once (administrator password).", model.net.service.helperVersion ?? L10n.tr("older"), BIR.version),
                           actions: AnyView(Button(L10n.tr("Update Service")) { Task { await model.apply(title: L10n.tr("update the background service")) } }.buttonStyle(.borderedProminent)))
                }
                PendingBanner()

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 16) {
                    localTile
                    publicTile
                    egressTile
                    rulesTile
                }

                PublicIdentityCard()
                HStack(alignment: .top, spacing: 16) {
                    publicByPath
                    managedRoutes
                }
                interfacesCard
            }
            .padding(24)
        }
    }

    private var primary: InterfaceInfo? { model.localInterface }

    private var localTile: some View {
        StatTile(title: L10n.tr("Local IP"), value: primary?.ipv4 ?? "—",
                 detail: primary.map { L10n.tr("%@ (%@) · router %@", model.displayName($0.name), $0.name, $0.router ?? "—") } ?? L10n.tr("No Wi-Fi or Ethernet connection"),
                 symbol: "laptopcomputer", tint: .blue)
    }

    private var publicTile: some View {
        let d = model.publicIPs.first { $0.id == "default" }
        return StatTile(title: L10n.tr("Public IPv4"), value: d?.v4?.ip ?? (model.publicIPLoading ? L10n.tr("Checking…") : "—"),
                        detail: d?.v4.map { [$0.location, $0.org].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
                            ?? d?.v4Error ?? L10n.tr("Default path"),
                        symbol: "globe", tint: .teal,
                        badge: d?.v4?.flag, badgeHelp: d?.v4?.country)
    }

    private var egressTile: some View {
        let route = model.net.internetRoute
        let iface = model.interface(route?.interface)
        let tint: Color = iface?.kind == .tunnel ? .purple : (iface?.kind.isVPN == true ? .blue : .green)
        return StatTile(title: L10n.tr("Internet Egress"),
                        value: route?.interface.map { model.displayName($0) } ?? L10n.tr("No route"),
                        detail: route.map { L10n.tr("%@ via %@ · route %@", $0.interface ?? "?", $0.gateway ?? "—", $0.matchedRouteLabel) } ?? "",
                        symbol: iface?.kind.symbol ?? "arrow.up.right", tint: tint)
    }

    private var rulesTile: some View {
        let statuses = model.net.helperStatus?.rules ?? []
        let active = statuses.filter { $0.state == .applied }.count
        let problems = statuses.filter { $0.state == .failed || $0.state == .partial || $0.state == .waiting }.count
        let liveOnly = model.liveButUnmanaged.count
        return StatTile(title: L10n.tr("Routing Rules"), value: L10n.tr("%lld / %lld managed", active, model.workspace.rules.count) + (liveOnly > 0 ? L10n.tr(" · %lld live", liveOnly) : ""),
                        detail: L10n.tr("%lld managed routes · %lld need attention · %lld unapplied", model.net.helperStatus?.installedRoutes.count ?? 0, problems, model.pendingChanges.count),
                        symbol: "arrow.triangle.branch", tint: problems > 0 ? .orange : .indigo)
    }

    private var publicByPath: some View {
        Card(L10n.tr("Public IP by path"), symbol: "globe.europe.africa",
             trailing: AnyView(HStack {
                 if let t = model.publicIPUpdated { Text(t.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                 Button { Task { await model.refreshPublicIPs() } } label: {
                     if model.publicIPLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                 }.buttonStyle(.borderless).help(L10n.tr("Check the public address each path exits with"))
             })) {
            if model.publicIPs.isEmpty {
                Text(model.publicIPLoading ? L10n.tr("Checking…") : L10n.tr("Not checked yet")).foregroundStyle(.secondary)
            }
            ForEach(model.publicIPs) { r in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title).fontWeight(.medium)
                        if let e = r.error {
                            Text(e).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        } else if let id = r.primary {
                            Text([id.location, id.org].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    if let ms = r.latencyMs { Text(L10n.tr("%.0f ms", ms)).font(.caption).foregroundStyle(.secondary) }
                    if let flag = r.primary?.flag { Text(flag).help(r.primary?.country ?? "") }
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(r.v4?.ip ?? (r.error == nil ? L10n.tr("no IPv4") : "—")).font(.body.monospaced()).textSelection(.enabled)
                        if let v6 = r.v6?.ip { Text(v6).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
                if r.id != model.publicIPs.last?.id { Divider() }
            }
        }
    }

    private var managedRoutes: some View {
        Card(L10n.tr("Managed routes"), symbol: "point.3.filled.connected.trianglepath.dotted") {
            let routes = model.net.helperStatus?.installedRoutes ?? []
            if routes.isEmpty {
                Text(model.workspace.rules.isEmpty ? L10n.tr("No rules yet. Add one in Routing Rules.") : L10n.tr("No routes installed yet."))
                    .foregroundStyle(.secondary)
                Button(L10n.tr("New Rule")) { model.selection = .rules; model.newRule() }
            }
            ForEach(routes.prefix(12)) { r in
                HStack {
                    Image(systemName: "arrow.right.circle.fill").foregroundStyle(.green)
                    Text(r.destinationLabel).font(.body.monospaced())
                    if let d = r.sourceDomain { Text(d).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(r.nextHopLabel).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                .contextMenu { Button(L10n.tr("Check Path")) { model.openPathCheck(r.destination) } }
            }
            if routes.count > 12 {
                Button(L10n.tr("Show all %lld…", routes.count)) { model.selection = .routes }.buttonStyle(.link)
            }
        }
    }

    private var interfacesCard: some View {
        Card(L10n.tr("Active interfaces"), symbol: "network",
             trailing: AnyView(Button(L10n.tr("Manage")) { model.selection = .adapters }.buttonStyle(.link))) {
            let list = model.net.interfaces.filter { $0.isActive && !$0.snapshot.ipv4.isEmpty && !$0.snapshot.isLoopback }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                GridRow {
                    Text(L10n.tr("Interface")); Text(L10n.tr("Type")); Text("IPv4"); Text(L10n.tr("Router / Peer")); Text(L10n.tr("Down")); Text(L10n.tr("Up"))
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(list) { i in
                    GridRow {
                        HStack(spacing: 6) {
                            Image(systemName: i.kind.symbol).foregroundStyle(.secondary).frame(width: 18)
                            Text(model.displayName(i.name)).fontWeight(.medium)
                            Text(i.name).font(.caption.monospaced()).foregroundStyle(.secondary)
                            if i.name == model.net.internetRoute?.interface { Pill(text: L10n.tr("Internet"), color: .purple) }
                            if i.name == model.net.primaryInterface { Pill(text: L10n.tr("Primary"), color: .blue) }
                        }
                        Text(i.isFullTunnel ? L10n.tr("Full tunnel") : i.kind.label).foregroundStyle(.secondary)
                        Text(i.ipv4 ?? "—").font(.body.monospaced()).textSelection(.enabled)
                        Text(i.router ?? i.snapshot.ipv4.first?.peer ?? "—").font(.body.monospaced())
                        Text(formatRate(model.rates[i.name]?.rx)).monospacedDigit()
                        Text(formatRate(model.rates[i.name]?.tx)).monospacedDigit()
                    }
                }
            }
        }
    }
}

/// The default path's public identity, laid out like the `myip` shell function: IPv4 and IPv6 with
/// location, ISP/org, time zone and coordinates.
struct PublicIdentityCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = model.publicIPs.first { $0.id == "default" }
        Card(L10n.tr("My public IP"), symbol: "person.badge.shield.checkmark",
             trailing: AnyView(HStack(spacing: 8) {
                 if let t = model.publicIPUpdated { Text(L10n.tr("Checked %@", t.formatted(date: .omitted, time: .shortened))).font(.caption).foregroundStyle(.secondary) }
                 Button { Task { await model.refreshPublicIPs() } } label: {
                     if model.publicIPLoading { ProgressView().controlSize(.small) } else { Label(L10n.tr("Refresh"), systemImage: "arrow.clockwise") }
                 }
                 .disabled(model.publicIPLoading)
             })) {
            HStack(alignment: .top, spacing: 16) {
                column("IPv4", d?.v4, error: d?.v4Error)
                Divider()
                column("IPv6", d?.v6, error: d?.v6Error)
            }
            if let egress = model.net.internetRoute?.interface {
                Text(L10n.tr("As seen through the system default path: %@ (%@).", model.displayName(egress), egress))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func column(_ label: String, _ id: IPIdentity?, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                if let id {
                    if let flag = id.flag { Text(flag).font(.title2).help(id.country ?? "") }
                    Text(id.ip).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled).lineLimit(1).minimumScaleFactor(0.6)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(id.ip, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help(L10n.tr("Copy"))
                } else {
                    Text(model.publicIPLoading ? L10n.tr("Checking…") : L10n.tr("not available")).font(.title3).foregroundStyle(.secondary)
                }
            }
            if let id {
                KeyValueRow(key: L10n.tr("Location"), value: id.location, mono: false)
                KeyValueRow(key: L10n.tr("ISP/Org"), value: id.org ?? "", mono: false)
                KeyValueRow(key: L10n.tr("Timezone"), value: id.timezone ?? "", mono: false)
                KeyValueRow(key: L10n.tr("Coords"), value: id.coords ?? "")
            } else if let error, !model.publicIPLoading {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
