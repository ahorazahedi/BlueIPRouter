import BlueIPRouterCore
import SwiftUI

struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, symbol: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || trailing != nil {
                HStack(spacing: 8) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                    if let title { Text(title).font(.headline) }
                    Spacer()
                    trailing
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct Pill: View {
    var text: String
    var color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var detail: String
    var symbol: String
    var tint: Color
    /// Optional emoji shown at the top right (e.g. a country flag).
    var badge: String? = nil
    var badgeHelp: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
                Spacer()
                if let badge {
                    Text(badge).font(.system(size: 30)).help(badgeHelp ?? "")
                }
            }
            Text(title).font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled)
            Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct KeyValueRow: View {
    var key: String
    var value: String
    var mono = true

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(mono ? .body.monospaced() : .body)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct Banner: View {
    var symbol: String
    var tint: Color
    var title: String
    var message: String
    var actions: AnyView

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.35)))
    }
}

struct PendingBanner: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDiscard = false

    var body: some View {
        if model.hasPending {
            let changes = model.pendingChanges
            let items = changes.prefix(4).map { "\($0.kind.title): \($0.rule.name)" } + (model.killSwitchPending ? [L10n.tr("Kill switch settings")] : [])
                + (model.automationPending ? [L10n.tr("Profiles, triggers or DNS")] : [])
            Banner(symbol: "exclamationmark.arrow.triangle.2.circlepath", tint: .orange,
                   title: L10n.tr("Unapplied: %@", L10n.pluralChange(model.pendingCount)),
                   message: items.joined(separator: " · ") + (model.liveButUnmanaged.isEmpty ? "" :
                       "\n" + L10n.tr("The routes of %lld of these already exist on this Mac (added outside BlueIPRouter). Applying takes them over without interrupting traffic and makes them persistent.", model.liveButUnmanaged.count)),
                   actions: AnyView(HStack {
                       Button(L10n.tr("Discard…")) { confirmDiscard = true }
                       Button(L10n.tr("Apply Changes")) { Task { await model.apply() } }.buttonStyle(.borderedProminent)
                   }))
                .confirmationDialog(L10n.tr("Discard unapplied changes (%@)?", L10n.pluralChange(model.pendingCount)), isPresented: $confirmDiscard) {
                    Button(L10n.tr("Discard Changes"), role: .destructive) { model.discardChanges() }
                } message: {
                    Text(L10n.tr("Your edits go back to what is applied on this Mac. This cannot be undone."))
                }
        }
    }
}

func ruleStateView(_ status: RuleStatus?, rule: RouteRule, pending: Bool, live: LiveCount? = nil) -> Pill {
    if pending {
        if let live, live.allLive { return Pill(text: L10n.tr("Live · not managed"), color: .blue, symbol: "bolt.horizontal.circle") }
        if let live, live.live > 0 { return Pill(text: L10n.tr("Partly live %lld/%lld", live.live, live.expected), color: .orange, symbol: "clock") }
        return Pill(text: L10n.tr("Not applied"), color: .orange, symbol: "clock")
    }
    guard let status else { return Pill(text: L10n.tr("Unknown"), color: .secondary, symbol: "questionmark") }
    switch status.state {
    case .applied: return Pill(text: L10n.tr("Active · %lld", status.routes.count), color: .green, symbol: "checkmark.circle.fill")
    case .partial: return Pill(text: L10n.tr("Partial %lld/%lld", status.routes.count, status.expected), color: .yellow, symbol: "exclamationmark.triangle.fill")
    case .failed: return Pill(text: L10n.tr("Failed"), color: .red, symbol: "xmark.circle.fill")
    case .waiting: return Pill(text: L10n.tr("Waiting"), color: .blue, symbol: "hourglass")
    case .disabled: return Pill(text: L10n.tr("Disabled"), color: .secondary, symbol: "pause.circle")
    }
}

func formatRate(_ bytesPerSecond: Double?) -> String {
    guard let b = bytesPerSecond else { return "—" }
    return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .binary) + L10n.tr("/s")
}

func formatBytes(_ v: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .binary) }
