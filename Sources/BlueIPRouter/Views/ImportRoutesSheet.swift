import BlueIPRouterCore
import SwiftUI

/// Lists static routes created outside BlueIPRouter and turns the chosen ones into rules.
struct ImportRoutesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var chosen = Set<String>()
    @State private var persistent = true

    var body: some View {
        let candidates = model.importCandidates
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("Import Static Routes")).font(.title2.weight(.semibold))
            Text(L10n.tr("These routes were added outside BlueIPRouter (by hand, a script or another tool). Imported routes become rules, grouped by next hop. The live routes stay as they are, so nothing goes down while you switch."))
                .foregroundStyle(.secondary)
            if candidates.isEmpty {
                ContentUnavailableView(L10n.tr("No static routes to import"), systemImage: "checkmark.circle",
                                       description: Text(L10n.tr("Every static route is already managed by a rule or belongs to the system or a VPN client.")))
                    .frame(maxWidth: .infinity).frame(height: 220)
            } else {
                Table(candidates, selection: $chosen) {
                    TableColumn(L10n.tr("Destination")) { c in Text(c.destination).font(.body.monospaced()) }
                    TableColumn(L10n.tr("Gateway")) { c in Text(c.entry.gateway).font(.body.monospaced()) }
                    TableColumn(L10n.tr("Interface")) { c in Text("\(model.displayName(c.entry.netif)) (\(c.entry.netif))") }
                    TableColumn(L10n.tr("Becomes rule via")) { c in Text(model.describe(c.via)).foregroundStyle(.secondary) }
                }
                .frame(height: 260)
                HStack {
                    Button(L10n.tr("Select All")) { chosen = Set(candidates.map(\.id)) }
                    Button(L10n.tr("Select None")) { chosen = [] }
                    Spacer()
                    Picker("", selection: $persistent) {
                        Text(L10n.tr("Persistent")).tag(true)
                        Text(L10n.tr("Until reboot")).tag(false)
                    }
                    .pickerStyle(.segmented).frame(width: 220).labelsHidden()
                }
            }
            HStack {
                Text(L10n.tr("Review the new rules, then press Apply.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("Import (%@)", L10n.pluralRoute(chosen.count))) {
                    model.importRoutes(candidates.filter { chosen.contains($0.id) }, persistent: persistent)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 760)
        .onAppear { chosen = Set(candidates.map(\.id)) }
    }
}
