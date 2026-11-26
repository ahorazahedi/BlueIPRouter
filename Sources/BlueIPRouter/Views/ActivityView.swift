import BlueIPRouterCore
import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: ActivityEntry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: L10n.tr("Activity Log"), subtitle: L10n.tr("Everything BlueIPRouter changed during this session")) {
                Button(L10n.tr("Clear")) { model.activity.removeAll() }.disabled(model.activity.isEmpty)
            }
            if model.activity.isEmpty {
                ContentUnavailableView(L10n.tr("No activity yet"), systemImage: "list.bullet.rectangle",
                                       description: Text(L10n.tr("Applied changes, adapter actions and path checks appear here.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.activity, selection: $selection) {
                    TableColumn("") { e in
                        Image(systemName: e.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(e.ok ? .green : .red)
                    }
                    .width(24)
                    TableColumn(L10n.tr("Time")) { e in Text(e.date.formatted(date: .omitted, time: .standard)).monospacedDigit() }
                        .width(90)
                    TableColumn(L10n.tr("Action")) { e in Text(e.title.prefix(1).uppercased() + e.title.dropFirst()) }
                        .width(min: 200, ideal: 300)
                    TableColumn(L10n.tr("Details")) { e in Text(e.detail).lineLimit(2).foregroundStyle(.secondary).font(.callout) }
                }
                if let id = selection, let e = model.activity.first(where: { $0.id == id }), !e.detail.isEmpty {
                    Card(L10n.tr("Output"), symbol: "terminal") {
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

    private func languageLabel(_ lang: AppLanguage) -> String {
        switch lang {
        case .system: return L10n.tr("System (Auto)")
        case .ru: return "Русский"
        case .en: return "English"
        }
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section(L10n.tr("Language")) {
                Picker(L10n.tr("Interface language"), selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(languageLabel(lang)).tag(lang)
                    }
                }
            }
            Section(L10n.tr("Monitoring")) {
                Picker(L10n.tr("Refresh every"), selection: $model.workspace.settings.refreshSeconds) {
                    Text(L10n.tr("2 seconds")).tag(2.0)
                    Text(L10n.tr("5 seconds")).tag(5.0)
                    Text(L10n.tr("10 seconds")).tag(10.0)
                    Text(L10n.tr("30 seconds")).tag(30.0)
                }
                Toggle(L10n.tr("Show system interfaces (awdl, anpi, …)"), isOn: $model.workspace.settings.showSystemInterfaces)
                Toggle(L10n.tr("Hide ARP/NDP entries in the routing table"), isOn: $model.workspace.settings.hideLinkLayerRoutes)
            }
            Section {
                Picker(L10n.tr("Location lookup"), selection: $model.workspace.settings.geoProvider) {
                    ForEach(GeoProvider.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text(L10n.tr("Public IP"))
            } footer: {
                Text(L10n.tr("Addresses come from api.ipify.org (IPv4) and api6.ipify.org (IPv6); location and ISP from the provider above, with the other one as a fallback."))
            }
            Section(L10n.tr("Updates")) {
                Toggle(L10n.tr("Check for new versions once a day"), isOn: $model.workspace.settings.checkForUpdates)
                Button(L10n.tr("Check Now")) { Task { await model.checkForUpdates(manual: true) } }
            }
            Section(L10n.tr("Persistence & backups")) {
                Stepper(L10n.tr("Service checks every %lld s", model.workspace.settings.serviceIntervalSeconds),
                        value: $model.workspace.settings.serviceIntervalSeconds, in: 15...3600, step: 15)
                Stepper(L10n.tr("Keep %lld automatic snapshots", model.workspace.settings.autoBackupLimit),
                        value: $model.workspace.settings.autoBackupLimit, in: 1...200)
            }
            Section(L10n.tr("Files")) {
                LabeledContent(L10n.tr("Workspace"), value: Storage.workspaceURL.path)
                LabeledContent(L10n.tr("Rules (root)"), value: BIR.persistentRules)
                LabeledContent(L10n.tr("Helper log"), value: BIR.log)
                Button(L10n.tr("Open App Data Folder")) { NSWorkspace.shared.open(Storage.appSupport) }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
