import AppKit
import BlueIPRouterCore
import SwiftUI

/// Startup options: background service at boot, app at login, menu bar icon.
struct StartupCard: View {
    @Environment(AppModel.self) private var model
    @AppStorage(UIPrefs.menuBarKey) private var menuBarEnabled = true
    @AppStorage(MenuBarLabelStyle.key) private var labelStyle = MenuBarLabelStyle.icon.rawValue

    var body: some View {
        Card("Startup", symbol: "power", trailing: AnyView(Button("Setup Assistant…") { model.showSetup = true })) {
            StartupRow(symbol: "gearshape.2", title: "Routes and kill switch at boot",
                       detail: "The background service runs as root from boot, even when the app is closed or nobody is logged in.",
                       isOn: model.backgroundServiceRunning) { on in Task { await model.setService(enabled: on) } }
            Divider()
            StartupRow(symbol: "person.crop.circle.badge.checkmark", title: "Open BlueIPRouter at login",
                       detail: model.loginItemNeedsApproval
                           ? "Waiting for your approval in System Settings › General › Login Items."
                           : "Starts the app when you log in, so the dashboard and menu bar icon are ready.",
                       isOn: model.openAtLogin) { on in model.setOpenAtLogin(on) }
            Divider()
            StartupRow(symbol: "menubar.rectangle", title: "Menu bar icon",
                       detail: "Shows status, public IP and quick actions in the menu bar, and keeps the app running when its window is closed.",
                       isOn: menuBarEnabled) { on in menuBarEnabled = on }
            if menuBarEnabled {
                Picker("Show in the menu bar", selection: $labelStyle) {
                    ForEach(MenuBarLabelStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .padding(.leading, 40)
                Text("Can't see it? On Macs with a notch, macOS hides menu bar icons that don't fit. Hold ⌘ and drag other icons out of the menu bar, or use a narrower style.")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 40)
            }
        }
    }
}

struct StartupRow: View {
    var symbol: String
    var title: String
    var detail: String
    var isOn: Bool
    var set: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: set)).toggleStyle(.switch).labelsHidden()
        }
    }
}

/// First-run checklist so a new user can set everything up from the UI.
struct SetupAssistant: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UIPrefs.menuBarKey) private var menuBarEnabled = true

    var body: some View {
        let imports = model.importCandidates.count
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to BlueIPRouter").font(.title.weight(.semibold))
                    Text("Set up how routing starts. Everything here can be changed later in Persistence.")
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 14) {
                step(done: model.backgroundServiceRunning, symbol: "gearshape.2",
                     title: "Install the background service",
                     detail: "Applies your rules and kill switch at boot and keeps repairing them. Asks for your administrator password once.") {
                    Button(model.backgroundServiceRunning ? "Installed" : "Install…") { Task { await model.setService(enabled: true) } }
                        .disabled(model.backgroundServiceRunning)
                }
                step(done: model.openAtLogin, symbol: "person.crop.circle.badge.checkmark",
                     title: "Open the app at login", detail: "Optional. Routing works without the app running.") {
                    Toggle("", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) })).toggleStyle(.switch).labelsHidden()
                }
                step(done: menuBarEnabled, symbol: "menubar.rectangle",
                     title: "Show the menu bar icon", detail: "Status and quick actions; the app keeps running when the window is closed.") {
                    Toggle("", isOn: $menuBarEnabled).toggleStyle(.switch).labelsHidden()
                }
                step(done: imports == 0, symbol: "square.and.arrow.down",
                     title: imports == 0 ? "No unmanaged static routes found" : "Import \(imports) existing static route\(imports == 1 ? "" : "s")",
                     detail: "Routes added by hand or by scripts can become rules, so they survive reboots.") {
                    if imports > 0 { Button("Review…") { model.showImport = true; dismiss() } }
                }
                step(done: !model.workspace.rules.isEmpty, symbol: "arrow.triangle.branch",
                     title: "Create your first rule", detail: "Send a domain or IP through the interface you choose.") {
                    Button("New Rule…") { dismiss(); model.selection = .rules; model.newRule() }
                }
            }
            HStack {
                Text("You can reopen this from Help › Setup Assistant.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    model.workspace.setupCompleted = true
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 640)
    }

    private func step<Action: View>(done: Bool, symbol: String, title: String, detail: String,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : symbol)
                .font(.title2).foregroundStyle(done ? Color.green : Color.accentColor).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// What the menu bar item shows next to (or instead of) the icon.
enum MenuBarLabelStyle: String, CaseIterable, Identifiable {
    case icon, flag, flagAndIP, speed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .icon: return "Icon"
        case .flag: return "Country flag"
        case .flagAndIP: return "Flag and public IP"
        case .speed: return "Download / upload speed"
        }
    }
    static let key = "menuBarLabelStyle"
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @AppStorage(MenuBarLabelStyle.key) private var style = MenuBarLabelStyle.icon.rawValue

    var body: some View {
        let pub = model.publicIPs.first { $0.id == "default" }?.v4
        let armed = model.net.helperStatus?.killSwitch?.active == true
        switch MenuBarLabelStyle(rawValue: style) ?? .icon {
        case .icon:
            Image(systemName: armed ? "arrow.triangle.branch.circle.fill" : "arrow.triangle.branch")
        case .flag:
            if let flag = pub?.flag { Text(flag) } else { Image(systemName: "arrow.triangle.branch") }
        case .flagAndIP:
            if let pub { Text("\(pub.flag ?? "") \(pub.ip)") } else { Image(systemName: "arrow.triangle.branch") }
        case .speed:
            let r = model.internetRate
            Text("↓\(shortRate(r.rx)) ↑\(shortRate(r.tx))").monospacedDigit()
        }
    }
}

/// Status panel shown from the menu bar item: public IP like `myip`, paths, rules and quick actions.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MenuBarLabelStyle.key) private var style = MenuBarLabelStyle.icon.rawValue

    var body: some View {
        let d = model.publicIPs.first { $0.id == "default" }
        let egress = model.net.internetRoute?.interface
        let ks = model.net.helperStatus?.killSwitch
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("BlueIPRouter").font(.headline)
                Spacer()
                Pill(text: model.backgroundServiceRunning ? "Service on" : "Service off",
                     color: model.backgroundServiceRunning ? .green : .secondary)
            }

            // Public identity (default path)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let flag = d?.v4?.flag { Text(flag).font(.system(size: 28)) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Public IPv4").font(.caption).foregroundStyle(.secondary)
                        Text(d?.v4?.ip ?? (model.publicIPLoading ? "Checking…" : "—"))
                            .font(.title2.monospaced().weight(.semibold)).textSelection(.enabled)
                    }
                    Spacer()
                    if let ip = d?.v4?.ip {
                        Button { copy(ip) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy")
                    }
                }
                if let v4 = d?.v4 {
                    detail("mappin.and.ellipse", v4.location)
                    detail("building.2", v4.org ?? "")
                    detail("clock", v4.timezone ?? "")
                }
                detail("6.circle", d?.v6.map { "IPv6 \($0.ip)" } ?? "IPv6 not available")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))

            speedSection

            VStack(alignment: .leading, spacing: 6) {
                row("arrow.up.right", "Internet via", egress.map { "\(model.displayName($0)) (\($0))" } ?? "—")
                if let lan = model.localInterface {
                    row("laptopcomputer", "Local IP", "\(lan.ipv4 ?? "—") · \(lan.name)")
                    if let wifi = model.publicIPs.first(where: { $0.id == lan.name })?.v4 {
                        row("wifi", "Direct public IP", "\(wifi.flag ?? "") \(wifi.ip)")
                    }
                }
                row("square.stack.3d.up", "Profile", model.net.helperStatus?.profile?.name ?? "None")
                row("arrow.triangle.branch", "Managed routes", "\(model.net.helperStatus?.installedRoutes.count ?? 0)")
                row("hand.raised", "Kill switch", ks?.active == true ? "Armed" : "Off")
                let failing = model.net.helperStatus?.rules.filter { $0.state == .failed || $0.state == .partial }.count ?? 0
                if failing > 0 { row("exclamationmark.triangle", "Rules with problems", "\(failing)") }
            }

            if model.hasPending {
                Button("Apply \(model.pendingCount) Change\(model.pendingCount == 1 ? "" : "s")") { Task { await model.apply() } }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            }
            if let u = model.availableUpdate {
                Button("Download version \(u.version)") { NSWorkspace.shared.open(u.downloadURL ?? u.pageURL) }
                    .frame(maxWidth: .infinity)
            }

            Divider()
            HStack(spacing: 8) {
                Button("Open BlueIPRouter") { open(nil) }
                Button("Check a Path…") { open(.pathCheck) }
                Button { open(.speedTest) } label: { Image(systemName: "speedometer") }.help("Run a speed test")
                Spacer()
                Button { Task { await model.refresh(); await model.refreshPublicIPs() } } label: {
                    if model.publicIPLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .help("Refresh")
                Menu {
                    Picker("Show in menu bar", selection: $style) {
                        ForEach(MenuBarLabelStyle.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Divider()
                    Button("Quit BlueIPRouter") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Options (the background service keeps running if you quit)")
            }
        }
        .padding(14)
        .frame(width: 340)
        .task { await model.start() }
    }

    /// Live download/upload for the interface carrying internet traffic and for the local link.
    private var speedSection: some View {
        let egress = model.net.internetRoute?.interface
        let lan = model.localInterface?.name
        let names = [egress, lan].compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                speedTile("arrow.down.circle.fill", "Download", model.internetRate.rx, .blue)
                speedTile("arrow.up.circle.fill", "Upload", model.internetRate.tx, .green)
            }
            ForEach(names, id: \.self) { n in
                HStack {
                    Text("\(model.displayName(n)) (\(n))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text("↓ \(formatRate(model.rates[n]?.rx))  ↑ \(formatRate(model.rates[n]?.tx))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func speedTile(_ symbol: String, _ title: String, _ value: Double, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(formatRate(value)).font(.callout.monospacedDigit().weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.10)))
    }

    private func open(_ item: SidebarItem?) {
        if let item { model.selection = item }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @ViewBuilder
    private func detail(_ symbol: String, _ text: String) -> some View {
        if !text.isEmpty {
            Label(text, systemImage: symbol).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func row(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(title).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospaced()).lineLimit(1)
        }
    }
}

/// Compact rate for the menu bar ("1.2M", "340K").
func shortRate(_ bytesPerSecond: Double) -> String {
    let b = max(0, bytesPerSecond)
    if b >= 1_048_576 { return String(format: "%.1fM", b / 1_048_576) }
    if b >= 1024 { return String(format: "%.0fK", b / 1024) }
    return String(format: "%.0fB", b)
}
