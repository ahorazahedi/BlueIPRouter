import BlueIPRouterCore
import SwiftUI

struct ServiceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let s = model.net.service
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Persistence", subtitle: "Keep routes in place across reboots, reconnects and IP changes")

                HStack(alignment: .top, spacing: 16) {
                    Card("Background route service", symbol: "clock.arrow.circlepath") {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.daemonInstalled && s.loaded ? "On" : "Off").font(.title.weight(.semibold))
                                    .foregroundStyle(s.daemonInstalled && s.loaded ? .green : .secondary)
                                Text("A root LaunchDaemon re-applies everything at boot, within seconds of any network change (VPN up/down, new Wi-Fi), and every \(model.workspace.settings.serviceIntervalSeconds) s. It re-resolves domains, follows router changes, runs triggers and repairs missing routes.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(get: { s.daemonInstalled }, set: { v in Task { await model.setService(enabled: v) } }))
                                .toggleStyle(.switch).labelsHidden().controlSize(.large)
                        }
                        Divider()
                        KeyValueRow(key: "Helper", value: s.helperInstalled ? "Installed (\(s.helperVersion ?? "?"))" : "Not installed", mono: false)
                        KeyValueRow(key: "LaunchDaemon", value: s.daemonInstalled ? BIR.daemonPlist : "Not installed")
                        KeyValueRow(key: "State", value: s.loaded ? (s.state ?? "loaded") : "not loaded", mono: false)
                        KeyValueRow(key: "Runs", value: s.runs.map(String.init) ?? "")
                        KeyValueRow(key: "Last exit code", value: s.lastExit ?? "")
                        KeyValueRow(key: "Last run", value: model.net.helperStatus.map { "\($0.updatedAt.formatted(date: .abbreviated, time: .standard)) (\($0.trigger))" } ?? "", mono: false)
                        HStack {
                            Stepper("Check every \(model.workspace.settings.serviceIntervalSeconds) s",
                                    value: $model.workspace.settings.serviceIntervalSeconds, in: 15...3600, step: 15)
                            Spacer()
                            if model.daemonOutdated {
                                Button("Update Service") { Task { await model.setService(enabled: true) } }
                            }
                            Button("Run Now") { Task { await model.runServiceNow() } }
                        }
                    }
                    Card("How persistence works", symbol: "info.circle") {
                        Label("Persistent rules live in \(BIR.persistentRules) and come back after a reboot.", systemImage: "lock.doc")
                        Label("“Until reboot” rules live in \(BIR.runDir), which macOS clears at boot.", systemImage: "timer")
                        Label("Routes added from the Routing Table screen are one-off and are never restored.", systemImage: "bolt")
                        Label("With the service off, rules only change when you press Apply.", systemImage: "hand.tap")
                    }
                    .font(.callout)
                }

                StartupCard()

                Card("Rule persistence", symbol: "list.bullet") {
                    if model.workspace.rules.isEmpty { Text("No rules").foregroundStyle(.secondary) }
                    ForEach(model.workspace.rules) { rule in
                        HStack {
                            Text(rule.name).fontWeight(.medium)
                            Text(rule.destinations.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Picker("", selection: Binding(get: { rule.persistent }, set: { model.setPersistent(rule.id, $0) })) {
                                Text("Persistent").tag(true)
                                Text("Until reboot").tag(false)
                            }
                            .pickerStyle(.segmented).frame(width: 220).labelsHidden()
                        }
                    }
                    PendingBanner()
                }

                Card("Helper log", symbol: "doc.text",
                     trailing: AnyView(Button("Reload") { model.loadHelperLog() })) {
                    ScrollView {
                        Text(model.helperLog.isEmpty ? "No log entries yet (\(BIR.log))." : model.helperLog)
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
