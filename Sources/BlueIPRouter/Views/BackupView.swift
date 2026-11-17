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
                PageHeader(title: "Backup & Restore", subtitle: "Save, move and roll back your routing setup")

                HStack(alignment: .top, spacing: 16) {
                    Card("Export", symbol: "square.and.arrow.up") {
                        Text("Saves all rules, interface aliases, settings and a snapshot of the current IPv4 routing table to a JSON file.")
                            .foregroundStyle(.secondary)
                        Button("Export Backup…") { model.exportBackup() }.buttonStyle(.borderedProminent)
                    }
                    Card("Import", symbol: "square.and.arrow.down") {
                        Text("Loads rules from a backup file. You can review them and then press Apply.")
                            .foregroundStyle(.secondary)
                        Button("Restore from File…") { pendingRestore = model.pickBackupFile() }
                    }
                }

                Card("Automatic snapshots", symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                     trailing: AnyView(Button("Snapshot Now") { model.autoBackup("Manual snapshot") })) {
                    Text("Taken after every successful Apply and before every restore or reset. Keeps the last \(model.workspace.settings.autoBackupLimit).")
                        .font(.callout).foregroundStyle(.secondary)
                    if model.backups.isEmpty { Text("No snapshots yet").foregroundStyle(.secondary) }
                    ForEach(model.backups) { b in
                        HStack {
                            Image(systemName: "doc.badge.clock").foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(b.createdAt.formatted(date: .abbreviated, time: .standard)).fontWeight(.medium)
                                Text("\(b.reason) · \(b.ruleCount) rule\(b.ruleCount == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([b.url]) }.buttonStyle(.borderless)
                            Button("Restore…") { pendingRestore = try? Storage.readBackup(b.url) }
                            Button(role: .destructive) { model.deleteBackup(b) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                        Divider()
                    }
                }

                Card("Reset to default", symbol: "arrow.counterclockwise.circle") {
                    Text("Puts the Mac's routing back to how it was before BlueIPRouter. Routes created by other apps (VPN clients, the system) are not touched.")
                        .foregroundStyle(.secondary)
                    Toggle("Take a snapshot first", isOn: $reset.backupFirst)
                    Toggle("Remove all routes installed by BlueIPRouter", isOn: $reset.removeRoutes)
                    Toggle("Delete all rules", isOn: $reset.deleteRules)
                    Toggle("Uninstall the background service and helper", isOn: $reset.uninstallService)
                    Toggle("Reset interface aliases and app settings", isOn: $reset.resetAliasesAndSettings)
                    Button("Reset to Default…", role: .destructive) { confirmReset = true }
                        .buttonStyle(.borderedProminent).tint(.red)
                }
            }
            .padding(24)
        }
        .sheet(item: $pendingRestore) { bundle in
            RestoreSheet(bundle: bundle).environment(model)
        }
        .confirmationDialog("Reset routing to default?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { Task { await model.reset(reset) } }
        } message: {
            Text(resetSummary)
        }
    }

    private var resetSummary: String {
        var parts: [String] = []
        if reset.removeRoutes { parts.append("remove \(model.net.helperStatus?.installedRoutes.count ?? 0) managed routes") }
        if reset.deleteRules { parts.append("delete \(model.workspace.rules.count) rules") }
        if reset.uninstallService { parts.append("uninstall the service") }
        if reset.resetAliasesAndSettings { parts.append("reset aliases and settings") }
        return "This will " + (parts.isEmpty ? "do nothing" : parts.joined(separator: ", ")) + "." + (reset.backupFirst ? " A snapshot is saved first." : "")
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
            Text("Restore Backup").font(.title2.weight(.semibold))
            KeyValueRow(key: "Created", value: bundle.createdAt.formatted(date: .long, time: .standard), mono: false)
            KeyValueRow(key: "From", value: "\(bundle.hostName) · BlueIPRouter \(bundle.appVersion)", mono: false)
            KeyValueRow(key: "Reason", value: bundle.reason, mono: false)
            Divider()
            Text("\(bundle.rules.count) rules").font(.headline)
            List(bundle.rules) { r in
                VStack(alignment: .leading) {
                    Text(r.name).fontWeight(.medium)
                    Text("\(r.destinations.joined(separator: ", ")) → \(model.describe(r.via))").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(height: 200)
            Picker("Mode", selection: $replace) {
                Text("Replace current rules").tag(true)
                Text("Merge with current rules").tag(false)
            }
            .pickerStyle(.radioGroup)
            Toggle("Also restore interface aliases and settings", isOn: $includeSettings)
            Text("Restored rules show as unapplied changes until you press Apply.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Restore") {
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
