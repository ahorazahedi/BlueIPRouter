import BlueIPRouterCore
import SwiftUI

struct BackupView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingRestore: BackupBundle?
    @State private var reset = ResetOptions()
    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: L10n.tr("Backup & Restore"), subtitle: L10n.tr("Save, move and roll back your routing setup"))

                HStack(alignment: .top, spacing: 16) {
                    Card(L10n.tr("Export"), symbol: "square.and.arrow.up") {
                        Text(L10n.tr("Saves all rules, interface aliases, settings and a snapshot of the current IPv4 routing table to a JSON file."))
                            .foregroundStyle(.secondary)
                        Button(L10n.tr("Export Backup…")) { model.exportBackup() }.buttonStyle(.borderedProminent)
                    }
                    Card(L10n.tr("Import"), symbol: "square.and.arrow.down") {
                        Text(L10n.tr("Loads rules from a backup file. You can review them and then press Apply."))
                            .foregroundStyle(.secondary)
                        Button(L10n.tr("Restore from File…")) { pendingRestore = model.pickBackupFile() }
                    }
                }

                Card(L10n.tr("Automatic snapshots"), symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                     trailing: AnyView(Button(L10n.tr("Snapshot Now")) { model.autoBackup("Manual snapshot") })) {
                    Text(L10n.tr("Taken after every successful Apply and before every restore or reset. Keeps the last %lld.", model.workspace.settings.autoBackupLimit))
                        .font(.callout).foregroundStyle(.secondary)
                    if model.backups.isEmpty { Text(L10n.tr("No snapshots yet")).foregroundStyle(.secondary) }
                    ForEach(model.backups) { b in
                        HStack {
                            Image(systemName: "doc.badge.clock").foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(b.createdAt.formatted(date: .abbreviated, time: .standard)).fontWeight(.medium)
                                Text("\(L10n.tr(b.reason)) · \(L10n.pluralRule(b.ruleCount))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L10n.tr("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([b.url]) }.buttonStyle(.borderless)
                            Button(L10n.tr("Restore…")) { pendingRestore = try? Storage.readBackup(b.url) }
                            Button(role: .destructive) { model.deleteBackup(b) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                        Divider()
                    }
                }

                Card(L10n.tr("Reset to default"), symbol: "arrow.counterclockwise.circle") {
                    Text(L10n.tr("Puts the Mac's routing back to how it was before BlueIPRouter. Routes created by other apps (VPN clients, the system) are not touched."))
                        .foregroundStyle(.secondary)
                    Toggle(L10n.tr("Take a snapshot first"), isOn: $reset.backupFirst)
                    Toggle(L10n.tr("Remove all routes installed by BlueIPRouter"), isOn: $reset.removeRoutes)
                    Toggle(L10n.tr("Delete all rules"), isOn: $reset.deleteRules)
                    Toggle(L10n.tr("Uninstall the background service and helper"), isOn: $reset.uninstallService)
                    Toggle(L10n.tr("Reset interface aliases and app settings"), isOn: $reset.resetAliasesAndSettings)
                    Button(L10n.tr("Reset to Default…"), role: .destructive) { confirmReset = true }
                        .buttonStyle(.borderedProminent).tint(.red)
                }
            }
            .padding(24)
        }
        .sheet(item: $pendingRestore) { bundle in
            RestoreSheet(bundle: bundle).environment(model)
        }
        .confirmationDialog(L10n.tr("Reset routing to default?"), isPresented: $confirmReset) {
            Button(L10n.tr("Reset"), role: .destructive) { Task { await model.reset(reset) } }
        } message: {
            Text(resetSummary)
        }
    }

    private var resetSummary: String {
        var parts: [String] = []
        if reset.removeRoutes { parts.append(L10n.tr("remove %lld managed routes", model.net.helperStatus?.installedRoutes.count ?? 0)) }
        if reset.deleteRules { parts.append(L10n.tr("delete %lld rules", model.workspace.rules.count)) }
        if reset.uninstallService { parts.append(L10n.tr("uninstall the service")) }
        if reset.resetAliasesAndSettings { parts.append(L10n.tr("reset aliases and settings")) }
        return L10n.tr("This will %@.", parts.isEmpty ? L10n.tr("do nothing") : parts.joined(separator: ", ")) + (reset.backupFirst ? L10n.tr(" A snapshot is saved first.") : "")
    }
}

struct RestoreSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bundle: BackupBundle
    @State private var replace = true
    @State private var includeSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("Restore Backup")).font(.title2.weight(.semibold))
            KeyValueRow(key: L10n.tr("Created"), value: bundle.createdAt.formatted(date: .long, time: .standard), mono: false)
            KeyValueRow(key: L10n.tr("From"), value: "\(bundle.hostName) · BlueIPRouter \(bundle.appVersion)", mono: false)
            KeyValueRow(key: L10n.tr("Reason"), value: L10n.tr(bundle.reason), mono: false)
            Divider()
            Text(L10n.pluralRule(bundle.rules.count)).font(.headline)
            List(bundle.rules) { r in
                VStack(alignment: .leading) {
                    Text(r.name).fontWeight(.medium)
                    Text("\(r.destinations.joined(separator: ", ")) → \(model.describe(r.via))").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(height: 200)
            Picker(L10n.tr("Mode"), selection: $replace) {
                Text(L10n.tr("Replace current rules")).tag(true)
                Text(L10n.tr("Merge with current rules")).tag(false)
            }
            .pickerStyle(.radioGroup)
            Toggle(L10n.tr("Also restore interface aliases and settings"), isOn: $includeSettings)
            Text(L10n.tr("Restored rules show as unapplied changes until you press Apply.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("Restore")) {
                    model.restore(bundle, replace: replace, includeSettings: includeSettings)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
