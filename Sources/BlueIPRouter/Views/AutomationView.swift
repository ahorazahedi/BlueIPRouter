import BlueIPRouterCore
import SwiftUI

/// Triggers run by the background service when the VPN or network changes, plus the event history.
struct AutomationView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: TriggerRule?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: L10n.tr("Automation"), subtitle: L10n.tr("React when a VPN connects or drops, or when you change networks")) {
                    Button { editing = TriggerRule(name: "", event: .tunnelDown, actions: [], notify: true) } label: {
                        Label(L10n.tr("New Trigger"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                PendingBanner()
                if !model.backgroundServiceRunning {
                    Banner(symbol: "exclamationmark.triangle", tint: .yellow, title: L10n.tr("Triggers need the background service"),
                           message: L10n.tr("The service watches the network and runs triggers, even when this app is closed."),
                           actions: AnyView(Button(L10n.tr("Turn On")) { Task { await model.setService(enabled: true) } }))
                }
                Card(L10n.tr("Triggers"), symbol: "bolt.badge.automatic") {
                    if model.workspace.automation.triggers.isEmpty {
                        Text(L10n.tr("No triggers yet. Examples: when the full-tunnel VPN disconnects, notify me; when it reconnects, re-learn its servers."))
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(L10n.tr("Add Suggested Triggers")) { addSuggested() }
                        }
                    }
                    ForEach(model.workspace.automation.triggers) { t in
                        HStack(alignment: .top) {
                            Toggle("", isOn: Binding(get: { t.enabled }, set: { v in
                                if let i = model.workspace.automation.triggers.firstIndex(where: { $0.id == t.id }) { model.workspace.automation.triggers[i].enabled = v }
                            })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t.name.isEmpty ? t.event.label : t.name).fontWeight(.medium)
                                Text(L10n.tr("When: %@", t.event.label)).font(.caption).foregroundStyle(.secondary)
                                Text(L10n.tr("Then: %@", actionSummary(t))).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L10n.tr("Edit…")) { editing = t }
                            Button(role: .destructive) { model.workspace.automation.triggers.removeAll { $0.id == t.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                        Divider()
                    }
                }
                NotificationSettingsCard()
                eventsCard
            }
            .padding(24)
        }
        .sheet(item: $editing) { t in TriggerEditor(trigger: t).environment(model) }
    }

    private func actionSummary(_ t: TriggerRule) -> String {
        var parts = t.actions.map { model.describe($0) }
        if t.notify { parts.append(L10n.tr("notify")) }
        return parts.isEmpty ? L10n.tr("record only") : parts.joined(separator: ", ")
    }

    private func addSuggested() {
        model.workspace.automation.triggers += [
            TriggerRule(name: L10n.tr("VPN dropped"), event: .tunnelDown, actions: [], notify: true),
            TriggerRule(name: L10n.tr("VPN reconnected"), event: .tunnelUp, actions: [.learnVPNServers], notify: true),
            TriggerRule(name: L10n.tr("New network"), event: .networkChanged, actions: [], notify: true),
        ]
    }

    private var eventsCard: some View {
        Card(L10n.tr("Recent events"), symbol: "clock.arrow.circlepath") {
            if model.net.events.isEmpty {
                Text(L10n.tr("No events yet. The background service records VPN and network changes here.")).foregroundStyle(.secondary)
            }
            ForEach(model.net.events.suffix(40).reversed()) { e in
                HStack(alignment: .firstTextBaseline) {
                    Text(e.date.formatted(date: .abbreviated, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 170, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title)
                        if !e.detail.isEmpty { Text(e.detail).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                }
            }
        }
    }
}

struct TriggerEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var trigger: TriggerRule
    @State private var eventKind = "tunnelDown"
    @State private var interfaceName = ""

    init(trigger: TriggerRule) {
        _trigger = State(initialValue: trigger)
        switch trigger.event {
        case .interfaceUp(let i): _eventKind = State(initialValue: "interfaceUp"); _interfaceName = State(initialValue: i)
        case .interfaceDown(let i): _eventKind = State(initialValue: "interfaceDown"); _interfaceName = State(initialValue: i)
        default: _eventKind = State(initialValue: trigger.event.kind)
        }
    }

    private var event: TriggerEvent {
        switch eventKind {
        case "tunnelUp": return .tunnelUp
        case "interfaceUp": return .interfaceUp(interfaceName)
        case "interfaceDown": return .interfaceDown(interfaceName)
        case "egressChanged": return .egressChanged
        case "networkChanged": return .networkChanged
        default: return .tunnelDown
        }
    }

    private var interfaces: [String] {
        Array(Set(model.net.interfaces.filter { !$0.isSystemNoise }.map(\.name) + [interfaceName].filter { !$0.isEmpty })).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(L10n.tr("Trigger")) {
                    TextField(L10n.tr("Name"), text: $trigger.name, prompt: Text(L10n.tr("e.g. VPN dropped")))
                    Picker(L10n.tr("When"), selection: $eventKind) {
                        Text(L10n.tr("Full-tunnel VPN disconnects")).tag("tunnelDown")
                        Text(L10n.tr("Full-tunnel VPN connects")).tag("tunnelUp")
                        Text(L10n.tr("An interface goes down")).tag("interfaceDown")
                        Text(L10n.tr("An interface comes up")).tag("interfaceUp")
                        Text(L10n.tr("Internet traffic switches interface")).tag("egressChanged")
                        Text(L10n.tr("Joined a different network")).tag("networkChanged")
                    }
                    if eventKind == "interfaceUp" || eventKind == "interfaceDown" {
                        Picker(L10n.tr("Interface"), selection: $interfaceName) {
                            Text(L10n.tr("Choose…")).tag("")
                            ForEach(interfaces, id: \.self) { Text("\(model.displayName($0)) (\($0))").tag($0) }
                        }
                    }
                }
                Section(L10n.tr("Then")) {
                    Toggle(L10n.tr("Send a notification"), isOn: $trigger.notify)
                    actionToggle(.learnVPNServers, L10n.tr("Re-learn VPN servers (for the kill switch)"))
                    actionToggle(.killSwitchOn, L10n.tr("Force the kill switch on"))
                    actionToggle(.killSwitchOff, L10n.tr("Force the kill switch off"))
                    actionToggle(.killSwitchAuto, L10n.tr("Return the kill switch to its setting"))
                    actionToggle(.clearProfile, L10n.tr("Clear the profile (all enabled rules)"))
                    ForEach(model.workspace.automation.profiles) { p in
                        actionToggle(.activateProfile(p.id), L10n.tr("Switch to profile “%@”", p.name))
                    }
                }
                Section {
                    Text(L10n.tr("Triggers run inside the background service within a few seconds of the change, even when this app is closed. Their effect lasts until another trigger changes it or the Mac restarts."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(L10n.tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("Save")) {
                    var t = trigger
                    t.event = event
                    if let i = model.workspace.automation.triggers.firstIndex(where: { $0.id == t.id }) {
                        model.workspace.automation.triggers[i] = t
                    } else {
                        model.workspace.automation.triggers.append(t)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled((eventKind == "interfaceUp" || eventKind == "interfaceDown") && interfaceName.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 540, height: 600)
    }

    private func actionToggle(_ action: TriggerAction, _ title: String) -> some View {
        Toggle(title, isOn: Binding(get: { trigger.actions.contains(action) }, set: { on in
            trigger.actions.removeAll { $0 == action }
            if on {
                // Only one kill-switch and one profile action make sense together.
                switch action {
                case .killSwitchOn, .killSwitchOff, .killSwitchAuto:
                    trigger.actions.removeAll { [.killSwitchOn, .killSwitchOff, .killSwitchAuto].contains($0) }
                case .activateProfile, .clearProfile:
                    trigger.actions.removeAll { if case .activateProfile = $0 { return true }; return $0 == .clearProfile }
                case .learnVPNServers: break
                }
                trigger.actions.append(action)
            }
        }))
    }
}
