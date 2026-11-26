import BlueIPRouterCore
import SwiftUI

struct ServiceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let s = model.net.service
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: L10n.tr("Persistence"), subtitle: L10n.tr("Keep routes in place across reboots, reconnects and IP changes"))

                HStack(alignment: .top, spacing: 16) {
                    Card(L10n.tr("Background route service"), symbol: "clock.arrow.circlepath") {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.daemonInstalled && s.loaded ? L10n.tr("On") : L10n.tr("Off")).font(.title.weight(.semibold))
                                    .foregroundStyle(s.daemonInstalled && s.loaded ? .green : .secondary)
                                Text(L10n.tr("A root LaunchDaemon re-applies everything at boot, within seconds of any network change (VPN up/down, new Wi-Fi), and every %lld s. It re-resolves domains, follows router changes, runs triggers and repairs missing routes.", model.workspace.settings.serviceIntervalSeconds))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(get: { s.daemonInstalled }, set: { v in Task { await model.setService(enabled: v) } }))
                                .toggleStyle(.switch).labelsHidden().controlSize(.large)
                        }
                        Divider()
                        KeyValueRow(key: L10n.tr("Helper"), value: s.helperInstalled ? L10n.tr("Installed (%@)", s.helperVersion ?? "?") : L10n.tr("Not installed"), mono: false)
                        KeyValueRow(key: "LaunchDaemon", value: s.daemonInstalled ? BIR.daemonPlist : L10n.tr("Not installed"))
                        KeyValueRow(key: L10n.tr("State"), value: s.loaded ? (s.state ?? L10n.tr("loaded")) : L10n.tr("not loaded"), mono: false)
                        KeyValueRow(key: L10n.tr("Runs"), value: s.runs.map(String.init) ?? "")
                        KeyValueRow(key: L10n.tr("Last exit code"), value: s.lastExit ?? "")
                        KeyValueRow(key: L10n.tr("Last run"), value: model.net.helperStatus.map { "\($0.updatedAt.formatted(date: .abbreviated, time: .standard)) (\($0.trigger))" } ?? "", mono: false)
                        HStack {
                            Stepper(L10n.tr("Check every %lld s", model.workspace.settings.serviceIntervalSeconds),
                                    value: $model.workspace.settings.serviceIntervalSeconds, in: 15...3600, step: 15)
                            Spacer()
                            if model.daemonOutdated {
                                Button(L10n.tr("Update Service")) { Task { await model.setService(enabled: true) } }
                            }
                            Button(L10n.tr("Run Now")) { Task { await model.runServiceNow() } }
                        }
                    }
                    Card(L10n.tr("How persistence works"), symbol: "info.circle") {
                        Label(L10n.tr("Persistent rules live in %@ and come back after a reboot.", BIR.persistentRules), systemImage: "lock.doc")
                        Label(L10n.tr("“Until reboot” rules live in %@, which macOS clears at boot.", BIR.runDir), systemImage: "timer")
                        Label(L10n.tr("Routes added from the Routing Table screen are one-off and are never restored."), systemImage: "bolt")
                        Label(L10n.tr("With the service off, rules only change when you press Apply."), systemImage: "hand.tap")
                    }
                    .font(.callout)
                }

                StartupCard()

                Card(L10n.tr("Rule persistence"), symbol: "list.bullet") {
                    if model.workspace.rules.isEmpty { Text(L10n.tr("No rules")).foregroundStyle(.secondary) }
                    ForEach(model.workspace.rules) { rule in
                        HStack {
                            Text(rule.name).fontWeight(.medium)
                            Text(rule.destinations.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Picker("", selection: Binding(get: { rule.persistent }, set: { model.setPersistent(rule.id, $0) })) {
                                Text(L10n.tr("Persistent")).tag(true)
                                Text(L10n.tr("Until reboot")).tag(false)
                            }
                            .pickerStyle(.segmented).frame(width: 220).labelsHidden()
                        }
                    }
                    PendingBanner()
                }

                Card(L10n.tr("Helper log"), symbol: "doc.text",
                     trailing: AnyView(Button(L10n.tr("Reload")) { model.loadHelperLog() })) {
                    ScrollView {
                        Text(model.helperLog.isEmpty ? L10n.tr("No log entries yet (%@).", BIR.log) : model.helperLog)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 220)
                }
            }
            .padding(24)
        }
        .onAppear { model.loadHelperLog() }
    }
}
