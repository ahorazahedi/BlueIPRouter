import BlueIPRouterCore
import SwiftUI

/// Addresses, networks or domains blocked completely — on every interface, the VPN tunnel included.
struct BlockListView: View {
    @Environment(AppModel.self) private var model
    @State private var newValue = ""
    @State private var newNote = ""
    @State private var selection = Set<UUID>()

    private var entries: [BlockEntry] { model.workspace.automation.blocked }
    private var live: BlockListStatus? { model.net.helperStatus?.blockList }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: L10n.tr("Block List"), subtitle: L10n.tr("Stop every connection to an address, network or domain — through any interface, the VPN included"))
            PendingBanner()
            statusCard
            addBar
            if entries.isEmpty {
                ContentUnavailableView {
                    Label(L10n.tr("Nothing blocked"), systemImage: "nosign")
                } description: {
                    Text(L10n.tr("Add an IP (203.0.113.10), a network (203.0.113.0/24 or 2001:db8::/32) or a domain (ads.example.com). You can also block from Connections or Path Check."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(entries, selection: $selection) {
                    TableColumn(L10n.tr("On")) { e in
                        Toggle("", isOn: Binding(get: { e.enabled }, set: { v in update(e.id) { $0.enabled = v } }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    .width(44)
                    TableColumn(L10n.tr("Blocked")) { e in
                        HStack(spacing: 6) {
                            Text(e.value).font(.body.monospaced())
                            if !e.isValid { Pill(text: L10n.tr("Invalid"), color: .red) }
                        }
                    }
                    .width(min: 180, ideal: 260)
                    TableColumn(L10n.tr("Type")) { e in Text(kind(e)).foregroundStyle(.secondary) }.width(80)
                    TableColumn(L10n.tr("Resolves to / covers")) { e in
                        Text(coverage(e)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .width(min: 160, ideal: 260)
                    TableColumn(L10n.tr("Note")) { e in Text(e.note).foregroundStyle(.secondary) }
                    TableColumn(L10n.tr("Status")) { e in statusPill(e) }.width(min: 90, ideal: 110)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first, let e = entries.first(where: { $0.id == id }), case .cidr(let c)? = KSEntry.parse(e.value) {
                        Button(L10n.tr("Check Path")) { model.openPathCheck(String(c.split(separator: "/").first ?? "")) }
                    }
                    Button(L10n.tr("Delete"), role: .destructive) { model.workspace.automation.blocked.removeAll { ids.contains($0.id) } }
                }
                .onDeleteCommand { model.workspace.automation.blocked.removeAll { selection.contains($0.id) } }
            }
        }
        .padding(24)
    }

    private var statusCard: some View {
        let active = live?.active == true
        let pending = model.automationPending
        return Card {
            HStack(spacing: 14) {
                Image(systemName: active ? "nosign" : "circle.slash")
                    .font(.system(size: 28)).foregroundStyle(active ? .red : .secondary)
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 12).fill((active ? Color.red : .secondary).opacity(0.12)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(active ? L10n.tr("Blocking %@", L10n.pluralRange(live!.denied.count))
                                : (entries.contains(where: \.enabled) ? L10n.tr("Not applied yet") : L10n.tr("Off")))
                        .font(.title2.weight(.semibold))
                    Text(L10n.tr("Outgoing connections are refused immediately (apps see “connection refused”) and replies are dropped. Applies to this Mac on every interface, including the VPN tunnel. Uses the pf firewall, kept by the background service across reboots."))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(L10n.tr("Blocking a domain also blocks every subdomain (www., uk., mail. …) by making their lookups fail. Browsers using their own encrypted DNS (Chrome/Firefox “Secure DNS”) can bypass that part; turn it off or block their addresses too. Pages already open may keep working until reloaded."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(live?.errors ?? [], id: \.self) { Label($0, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red) }
                }
                Spacer()
                if pending || model.daemonOutdated {
                    Button(pending ? L10n.tr("Apply") : L10n.tr("Update Service")) { Task { await model.apply(title: L10n.tr("update the block list")) } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var addBar: some View {
        let parsed = KSEntry.parse(newValue)
        return HStack(spacing: 8) {
            TextField(L10n.tr("IP, network or domain to block"), text: $newValue)
                .textFieldStyle(.roundedBorder).font(.body.monospaced())
                .onSubmit(add)
            TextField(L10n.tr("Note (optional)"), text: $newNote).textFieldStyle(.roundedBorder).frame(width: 220)
            Button(L10n.tr("Block")) { add() }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(parsed == nil)
        }
    }

    private func add() {
        let v = newValue.trimmingCharacters(in: .whitespaces).lowercased()
        guard KSEntry.parse(v) != nil else { return }
        model.block(v, note: newNote)
        newValue = ""
        newNote = ""
    }

    private func update(_ id: UUID, _ change: (inout BlockEntry) -> Void) {
        if let i = model.workspace.automation.blocked.firstIndex(where: { $0.id == id }) { change(&model.workspace.automation.blocked[i]) }
    }

    private func kind(_ e: BlockEntry) -> String {
        switch KSEntry.parse(e.value) {
        case .domain: return L10n.tr("Domain")
        case .cidr(let c): return c.hasSuffix("/32") || c.hasSuffix("/128") ? L10n.tr("Address") : L10n.tr("Network")
        case nil: return "—"
        }
    }

    private func coverage(_ e: BlockEntry) -> String {
        switch KSEntry.parse(e.value) {
        case .cidr(let c): return c
        case .domain:
            return L10n.tr("the domain and all its subdomains (lookups fail), plus its current IPs")
        case nil: return ""
        }
    }

    private func statusPill(_ e: BlockEntry) -> Pill {
        guard e.enabled else { return Pill(text: L10n.tr("Off"), color: .secondary) }
        if model.automationPending { return Pill(text: L10n.tr("Not applied"), color: .orange, symbol: "clock") }
        if live?.active == true { return Pill(text: L10n.tr("Blocked"), color: .red, symbol: "nosign") }
        return Pill(text: L10n.tr("Inactive"), color: .secondary)
    }
}
