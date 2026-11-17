import AppKit
import BlueIPRouterCore
import SwiftUI

/// Startup options: background service at boot, app at login, menu bar icon.
struct StartupCard: View {
    @Environment(AppModel.self) private var model
    @AppStorage(UIPrefs.menuBarKey) private var menuBarEnabled = true

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

/// Compact status window shown from the menu bar icon.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let pub = model.publicIPs.first { $0.id == "default" }
        let egress = model.net.internetRoute?.interface
        let ks = model.net.helperStatus?.killSwitch
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("BlueIPRouter").font(.headline)
                Spacer()
                Pill(text: model.backgroundServiceRunning ? "Service on" : "Service off",
                     color: model.backgroundServiceRunning ? .green : .secondary)
            }
            Divider()
            row("globe", "Public IPv4", pub?.v4?.ip ?? "—", pub?.v4.map { [$0.location, $0.org ?? ""].filter { !$0.isEmpty }.joined(separator: " · ") })
            row("arrow.up.right", "Internet via", egress.map { "\(model.displayName($0)) (\($0))" } ?? "—", nil)
            if let lan = model.localInterface {
                row("laptopcomputer", "Local IP", lan.ipv4 ?? "—", "\(model.displayName(lan.name)) · router \(lan.router ?? "—")")
            }
            row("arrow.triangle.branch", "Managed routes", "\(model.net.helperStatus?.installedRoutes.count ?? 0)", nil)
            row("hand.raised", "Kill switch", ks?.active == true ? "Armed" : "Off", nil)
            if model.hasPending {
                Button("Apply \(model.pendingCount) Change\(model.pendingCount == 1 ? "" : "s")") { Task { await model.apply() } }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                Button("Open BlueIPRouter") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button { Task { await model.refresh(); await model.refreshPublicIPs() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit the app (the background service keeps running)")
            }
        }
        .padding(14)
        .frame(width: 320)
        .task { await model.start() }
    }

    private func row(_ symbol: String, _ title: String, _ value: String, _ detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                if let detail, !detail.isEmpty { Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
            }
            Spacer()
            Text(value).font(.callout.monospaced()).lineLimit(1)
        }
    }
}
