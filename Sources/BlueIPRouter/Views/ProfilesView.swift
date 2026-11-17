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
                PageHeader(title: "Profiles", subtitle: "Switch which rules are active, by hand or by the network you join") {
                    Button { editing = RoutingProfile(name: "", ruleIDs: model.workspace.rules.map(\.id)) } label: {
                        Label("New Profile", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                PendingBanner()
                activeCard
                if auto.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("No profiles", systemImage: "square.stack.3d.up")
                    } description: {
                        Text("Without profiles every enabled rule applies everywhere. Create profiles such as Home, Office or Travel to change that.")
                    } actions: {
                        Button("New Profile") { editing = RoutingProfile(name: "", ruleIDs: model.workspace.rules.map(\.id)) }
                    }
                    .frame(minHeight: 240)
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
        return Card("Active profile", symbol: "checkmark.seal") {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(info?.name ?? "None — all enabled rules").font(.title2.weight(.semibold))
                    Text(info?.reason ?? "Applied by the helper on the next pass").foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            Picker("Manual choice", selection: $model.workspace.automation.manualProfileID) {
                Text("None (all enabled rules)").tag(UUID?.none)
                ForEach(auto.profiles) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            Toggle("Switch automatically when I join a network that a profile lists", isOn: $model.workspace.automation.autoSwitchByNetwork)
            if let fp = model.net.network {
                Text("Current network: \(fp.label)").font(.caption).foregroundStyle(.secondary)
            }
            Text("Order: a trigger's choice wins, then a matching network, then the manual choice. Press Apply after changes.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func profileCard(_ p: RoutingProfile) -> some View {
        let active = model.net.helperStatus?.profile?.id == p.id
        let rules = model.workspace.rules.filter { p.ruleIDs.contains($0.id) }
        return Card(p.name, symbol: active ? "checkmark.circle.fill" : "square.stack.3d.up",
                    trailing: AnyView(HStack {
                        if active { Pill(text: "Active", color: .green) }
                        Button("Edit…") { editing = p }
                        Button(role: .destructive) {
                            model.workspace.automation.profiles.removeAll { $0.id == p.id }
                            if model.workspace.automation.manualProfileID == p.id { model.workspace.automation.manualProfileID = nil }
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    })) {
            KeyValueRow(key: "Rules", value: rules.isEmpty ? "none" : rules.map(\.name).joined(separator: ", "), mono: false)
            KeyValueRow(key: "Kill switch", value: p.killSwitch.map { $0 ? "forced on" : "forced off" } ?? "unchanged", mono: false)
            KeyValueRow(key: "Networks", value: p.networks.isEmpty ? "manual only" : p.networks.map(\.label).joined(separator: ", "), mono: false)
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
                Section("Profile") {
                    TextField("Name", text: $profile.name, prompt: Text("e.g. Home"))
                    Picker("Kill switch", selection: $profile.killSwitch) {
                        Text("Leave as configured").tag(Bool?.none)
                        Text("Force on").tag(Bool?.some(true))
                        Text("Force off").tag(Bool?.some(false))
                    }
                }
                Section("Active rules") {
                    if model.workspace.rules.isEmpty { Text("No rules yet").foregroundStyle(.secondary) }
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
                                Text("router \(n.routerIP)\(n.routerMAC.map { " · \($0)" } ?? "")").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { profile.networks.removeAll { $0.id == n.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    if let fp = model.net.network {
                        Button("Add Current Network (\(fp.routerIP))") {
                            profile.networks.append(NetworkMatch(label: profile.name.isEmpty ? "Network \(fp.routerIP)" : profile.name,
                                                                 routerIP: fp.routerIP, routerMAC: fp.routerMAC))
                        }
                        .disabled(profile.networks.contains { $0.matches(fp) })
                    } else {
                        Text("Not connected to a network with a router.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Use automatically on these networks")
                } footer: {
                    Text("Networks are recognised by their router's hardware address, so no Wi-Fi name or location permission is needed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") {
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
