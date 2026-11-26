import BlueIPRouterCore
import SwiftUI

/// Named sets of rules, picked by hand or automatically by the network the Mac joins.
struct ProfilesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: RoutingProfile?

    private var auto: AutomationConfig { model.workspace.automation }

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: L10n.tr("Profiles"), subtitle: L10n.tr("Switch which rules are active, by hand or by the network you join")) {
                    Button { editing = RoutingProfile(name: "", ruleIDs: model.workspace.rules.map(\.id)) } label: {
                        Label(L10n.tr("New Profile"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                PendingBanner()
                activeCard
                if auto.profiles.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.tr("No profiles"), systemImage: "square.stack.3d.up")
                    } description: {
                        Text(L10n.tr("Without profiles every enabled rule applies everywhere. Create profiles such as Home, Office or Travel to change that."))
                    } actions: {
                        Button(L10n.tr("New Profile")) { editing = RoutingProfile(name: "", ruleIDs: model.workspace.rules.map(\.id)) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
                ForEach(auto.profiles) { p in profileCard(p) }
            }
            .padding(24)
        }
        .sheet(item: $editing) { p in ProfileEditor(profile: p).environment(model) }
    }

    private var activeCard: some View {
        @Bindable var model = model
        let info = model.net.helperStatus?.profile
        return Card(L10n.tr("Active profile"), symbol: "checkmark.seal") {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(info?.name ?? L10n.tr("None — all enabled rules")).font(.title2.weight(.semibold))
                    Text(info?.reason ?? L10n.tr("Applied by the helper on the next pass")).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            Picker(L10n.tr("Manual choice"), selection: $model.workspace.automation.manualProfileID) {
                Text(L10n.tr("None (all enabled rules)")).tag(UUID?.none)
                ForEach(auto.profiles) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            Toggle(L10n.tr("Switch automatically when I join a network that a profile lists"), isOn: $model.workspace.automation.autoSwitchByNetwork)
            if let fp = model.net.network {
                Text(L10n.tr("Current network: %@", fp.label)).font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.tr("Order: a trigger's choice wins, then a matching network, then the manual choice. Press Apply after changes."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func profileCard(_ p: RoutingProfile) -> some View {
        let active = model.net.helperStatus?.profile?.id == p.id
        let rules = model.workspace.rules.filter { p.ruleIDs.contains($0.id) }
        return Card(p.name, symbol: active ? "checkmark.circle.fill" : "square.stack.3d.up",
                    trailing: AnyView(HStack {
                        if active { Pill(text: L10n.tr("Active"), color: .green) }
                        Button(L10n.tr("Edit…")) { editing = p }
                        Button(role: .destructive) {
                            model.workspace.automation.profiles.removeAll { $0.id == p.id }
                            if model.workspace.automation.manualProfileID == p.id { model.workspace.automation.manualProfileID = nil }
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    })) {
            KeyValueRow(key: L10n.tr("Rules"), value: rules.isEmpty ? L10n.tr("none") : rules.map(\.name).joined(separator: ", "), mono: false)
            KeyValueRow(key: L10n.tr("Kill switch"), value: p.killSwitch.map { $0 ? L10n.tr("forced on") : L10n.tr("forced off") } ?? L10n.tr("unchanged"), mono: false)
            KeyValueRow(key: L10n.tr("Networks"), value: p.networks.isEmpty ? L10n.tr("manual only") : p.networks.map(\.label).joined(separator: ", "), mono: false)
        }
    }
}

struct ProfileEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var profile: RoutingProfile

    private var isNew: Bool { !model.workspace.automation.profiles.contains { $0.id == profile.id } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(L10n.tr("Profile")) {
                    TextField(L10n.tr("Name"), text: $profile.name, prompt: Text(L10n.tr("e.g. Home")))
                    Picker(L10n.tr("Kill switch"), selection: $profile.killSwitch) {
                        Text(L10n.tr("Leave as configured")).tag(Bool?.none)
                        Text(L10n.tr("Force on")).tag(Bool?.some(true))
                        Text(L10n.tr("Force off")).tag(Bool?.some(false))
                    }
                }
                Section(L10n.tr("Active rules")) {
                    if model.workspace.rules.isEmpty { Text(L10n.tr("No rules yet")).foregroundStyle(.secondary) }
                    ForEach(model.workspace.rules) { rule in
                        Toggle(isOn: Binding(get: { profile.ruleIDs.contains(rule.id) }, set: { on in
                            profile.ruleIDs.removeAll { $0 == rule.id }
                            if on { profile.ruleIDs.append(rule.id) }
                        })) {
                            VStack(alignment: .leading) {
                                Text(rule.name)
                                Text(rule.destinations.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                Section {
                    ForEach(profile.networks) { n in
                        HStack {
                            Image(systemName: "wifi.router")
                            VStack(alignment: .leading) {
                                Text(n.label)
                                Text(L10n.tr("router %@%@", n.routerIP, n.routerMAC.map { " · \($0)" } ?? "")).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { profile.networks.removeAll { $0.id == n.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    if let fp = model.net.network {
                        Button(L10n.tr("Add Current Network (%@)", fp.routerIP)) {
                            profile.networks.append(NetworkMatch(label: profile.name.isEmpty ? L10n.tr("Network %@", fp.routerIP) : profile.name,
                                                                 routerIP: fp.routerIP, routerMAC: fp.routerMAC))
                        }
                        .disabled(profile.networks.contains { $0.matches(fp) })
                    } else {
                        Text(L10n.tr("Not connected to a network with a router.")).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(L10n.tr("Use automatically on these networks"))
                } footer: {
                    Text(L10n.tr("Networks are recognised by their router's hardware address, so no Wi-Fi name or location permission is needed."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(L10n.tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? L10n.tr("Create") : L10n.tr("Save")) {
                    if let i = model.workspace.automation.profiles.firstIndex(where: { $0.id == profile.id }) {
                        model.workspace.automation.profiles[i] = profile
                    } else {
                        model.workspace.automation.profiles.append(profile)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
    }
}
