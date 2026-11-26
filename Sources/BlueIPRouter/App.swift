import AppKit
import BlueIPRouterCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest") { Task { await SelfTest.run() } ; return }
        if CommandLine.arguments.contains("--speedtest-quick") { Task { await SelfTest.quickSpeed() } ; return }
        if let i = CommandLine.arguments.firstIndex(of: "--render-dial"), i + 1 < CommandLine.arguments.count {
            Task { @MainActor in SelfTest.renderDial(to: CommandLine.arguments[i + 1]); exit(0) }
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// With the menu bar icon on, closing the window keeps the app running there.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !UIPrefs.menuBarEnabled }
}

@main
struct BlueIPRouterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @AppStorage(UIPrefs.menuBarKey) private var menuBarEnabled = true

    var body: some Scene {
        Window("BlueIPRouter", id: "main") {
            RootView()
                .environment(model)
                .id(model.languageVersion)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
                Button(L10n.tr("Check for Updates…")) { Task { await model.checkForUpdates(manual: true) } }
            }
            CommandGroup(after: .newItem) {
                Button(L10n.tr("New Routing Rule")) { model.selection = .rules; model.newRule() }
                    .keyboardShortcut("n")
            }
            CommandMenu(L10n.tr("Routing")) {
                Button(L10n.tr("Apply Changes")) { Task { await model.apply() } }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!model.hasPending)
                Button(L10n.tr("Refresh")) { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                Button(L10n.tr("Refresh Public IPs")) { Task { await model.refreshPublicIPs() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button(L10n.tr("Check Path…")) { model.selection = .pathCheck }
                    .keyboardShortcut("k")
                Button(L10n.tr("Flush DNS Cache")) { Task { await model.flushDNS() } }
            }
            CommandGroup(after: .help) {
                Button(L10n.tr("Setup Assistant…")) { model.showSetup = true }
            }
        }

        Window(L10n.tr("About BlueIPRouter"), id: "about") {
            AboutView(compact: true).environment(model).id(model.languageVersion).frame(width: 520)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra(isInserted: $menuBarEnabled) {
            MenuBarView().environment(model).id(model.languageVersion)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model).id(model.languageVersion).frame(width: 520)
        }
    }
}
