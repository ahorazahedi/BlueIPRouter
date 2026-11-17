import BlueIPRouterCore
import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: ActivityEntry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Activity Log", subtitle: "Everything BlueIPRouter changed during this session") {
                Button("Clear") { model.activity.removeAll() }.disabled(model.activity.isEmpty)
            }
            if model.activity.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Applied changes, adapter actions and path checks appear here."))
                    .frame(maxHeight: .infinity)
            } else {
                Table(model.activity, selection: $selection) {
                    TableColumn("") { e in
                        Image(systemName: e.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(e.ok ? .green : .red)
                    }
                    .width(24)
                    TableColumn("Time") { e in Text(e.date.formatted(date: .omitted, time: .standard)).monospacedDigit() }
                        .width(90)
                    TableColumn("Action") { e in Text(e.title.prefix(1).uppercased() + e.title.dropFirst()) }
                        .width(min: 200, ideal: 300)
                    TableColumn("Details") { e in Text(e.detail).lineLimit(2).foregroundStyle(.secondary).font(.callout) }
                }
                if let id = selection, let e = model.activity.first(where: { $0.id == id }), !e.detail.isEmpty {
                    Card("Output", symbol: "terminal") {
                        ScrollView {
                            Text(e.detail).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 160)
                    }
                }
            }
        }
        .padding(24)
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Monitoring") {
                Picker("Refresh every", selection: $model.workspace.settings.refreshSeconds) {
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                }
                Toggle("Show system interfaces (awdl, anpi, …)", isOn: $model.workspace.settings.showSystemInterfaces)
                Toggle("Hide ARP/NDP entries in the routing table", isOn: $model.workspace.settings.hideLinkLayerRoutes)
            }
            Section {
                Picker("Location lookup", selection: $model.workspace.settings.geoProvider) {
                    ForEach(GeoProvider.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Public IP")
            } footer: {
                Text("Addresses come from api.ipify.org (IPv4) and api6.ipify.org (IPv6); location and ISP from the provider above, with the other one as a fallback.")
            }
            Section("Persistence & backups") {
                Stepper("Service checks every \(model.workspace.settings.serviceIntervalSeconds) s",
                        value: $model.workspace.settings.serviceIntervalSeconds, in: 15...3600, step: 15)
                Stepper("Keep \(model.workspace.settings.autoBackupLimit) automatic snapshots",
                        value: $model.workspace.settings.autoBackupLimit, in: 1...200)
            }
            Section("Files") {
                LabeledContent("Workspace", value: Storage.workspaceURL.path)
                LabeledContent("Rules (root)", value: BIR.persistentRules)
                LabeledContent("Helper log", value: BIR.log)
                Button("Open App Data Folder") { NSWorkspace.shared.open(Storage.appSupport) }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
