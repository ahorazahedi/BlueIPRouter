import BlueIPRouterCore
import SwiftUI

struct PathCheckView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: L10n.tr("Path Check"), subtitle: L10n.tr("Find out which interface and gateway an IP or domain uses"))

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L10n.tr("IP address or domain, e.g. example.com"), text: $model.pathQuery)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($focused)
                        .onSubmit { Task { await model.checkPath() } }
                    if model.pathChecking { ProgressView().controlSize(.small) }
                    Button(L10n.tr("Check")) { Task { await model.checkPath() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.pathQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))

                HStack(spacing: 8) {
                    Text(L10n.tr("Try:")).foregroundStyle(.secondary)
                    ForEach(suggestions, id: \.self) { s in
                        Button(s) { Task { await model.checkPath(s) } }.buttonStyle(.bordered).controlSize(.small)
                    }
                }

                if let r = model.pathResult { result(r) }
            }
            .padding(24)
        }
        .onAppear { focused = true }
    }

    private var suggestions: [String] {
        var list = model.workspace.rules.flatMap(\.destinations).prefix(4).map { $0 }
        list.append("1.1.1.1")
        return Array(NSOrderedSet(array: list).array as? [String] ?? list)
    }

    @ViewBuilder
    private func result(_ r: PathCheckResult) -> some View {
        if r.isDomain {
            Card(L10n.tr("DNS"), symbol: "text.magnifyingglass") {
                KeyValueRow(key: L10n.tr("Name"), value: r.query)
                KeyValueRow(key: "IPv4", value: r.ipv4.joined(separator: ", "))
                KeyValueRow(key: "IPv6", value: r.ipv6.joined(separator: ", "))
                KeyValueRow(key: L10n.tr("Lookup time"), value: r.dnsMs.map { String(format: L10n.tr("%.0f ms"), $0) } ?? "", mono: false)
                KeyValueRow(key: L10n.tr("Resolver"), value: model.net.systemDNS.joined(separator: ", "))
            }
        }
        if let e = r.error {
            Banner(symbol: "exclamationmark.triangle", tint: .orange, title: L10n.tr("Note"), message: e, actions: AnyView(EmptyView()))
        }
        ForEach(r.hops) { hop in hopCard(hop) }
        if !r.hops.isEmpty { tracerouteCard(r) }
    }

    private func hopCard(_ hop: PathHop) -> some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: hop.verdict.symbol)
                    .font(.system(size: 30))
                    .foregroundStyle(hop.verdict.color)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(hop.ip).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled)
                        Spacer()
                        Button(L10n.tr("Block"), role: .destructive) {
                            let target = model.pathResult?.isDomain == true ? model.pathResult!.query : hop.ip
                            Task { await model.blockAndApply(target, note: L10n.tr("Blocked from Path Check")) }
                        }
                        .help(L10n.tr("Add to the block list and apply"))
                        if let ruleID = hop.ruleID, let rule = model.workspace.rules.first(where: { $0.id == ruleID }) {
                            Button(L10n.tr("Edit Rule “%@”", rule.name)) { model.editingRule = rule }
                        } else {
                            Button(L10n.tr("Create Rule for this IP")) {
                                model.selection = .rules
                                model.newRule(destination: model.pathResult?.isDomain == true ? model.pathResult!.query : hop.ip)
                            }
                        }
                    }
                    Text(hop.headline).font(.headline).foregroundStyle(hop.verdict.color)
                    if let l = hop.lookup {
                        HStack(spacing: 8) {
                            Pill(text: L10n.tr("Interface %@", l.interface ?? "?"), color: .secondary)
                            Pill(text: L10n.tr("Gateway %@", l.gateway ?? L10n.tr("none")), color: .secondary)
                            Pill(text: L10n.tr("Route %@", l.matchedRouteLabel), color: .secondary)
                            ForEach(l.flags.prefix(5), id: \.self) { Pill(text: $0, color: .secondary) }
                        }
                    }
                    ForEach(hop.explanation, id: \.self) { line in
                        Label(line, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    }
                    if let t = hop.tcp443 {
                        let ok = hop.tcp443Reachable ?? true
                        Label(t, systemImage: ok ? "checkmark.circle" : "xmark.circle")
                            .font(.callout).foregroundStyle(ok ? .green : .orange)
                    } else {
                        HStack { ProgressView().controlSize(.mini); Text(L10n.tr("Testing TCP 443…")).font(.callout).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private func tracerouteCard(_ r: PathCheckResult) -> some View {
        Card(L10n.tr("Traceroute"), symbol: "point.3.connected.trianglepath.dotted",
             trailing: AnyView(HStack {
                 if model.traceroute.running {
                     ProgressView().controlSize(.small)
                     Button(L10n.tr("Stop")) { model.traceroute.stop() }
                 } else {
                     Button(L10n.tr("Run Traceroute to %@", r.hops.first?.ip ?? "")) {
                         if let ip = r.hops.first?.ip { model.traceroute.start(target: ip) }
                     }
                 }
             })) {
            if model.traceroute.lines.isEmpty {
                Text(L10n.tr("Shows each router hop on the way. Hops through a tunnel appear as the tunnel's far end."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.traceroute.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
    }
}
