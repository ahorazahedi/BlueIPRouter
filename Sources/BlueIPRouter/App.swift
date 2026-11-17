import AppKit
import BlueIPRouterCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest") { Task { await SelfTest.run() } ; return }
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
                .frame(minWidth: 1100, minHeight: 720)
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Routing Rule") { model.selection = .rules; model.newRule() }
                    .keyboardShortcut("n")
            }
            CommandMenu("Routing") {
                Button("Apply Changes") { Task { await model.apply() } }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!model.hasPending)
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                Button("Refresh Public IPs") { Task { await model.refreshPublicIPs() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Check Path…") { model.selection = .pathCheck }
                    .keyboardShortcut("k")
                Button("Flush DNS Cache") { Task { await model.flushDNS() } }
            }
            CommandGroup(after: .help) {
                Button("Setup Assistant…") { model.showSetup = true }
            }
        }

        MenuBarExtra(isInserted: $menuBarEnabled) {
            MenuBarView().environment(model)
        } label: {
            Image(systemName: model.net.helperStatus?.killSwitch?.active == true ? "arrow.triangle.branch.circle.fill" : "arrow.triangle.branch")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model).frame(width: 520)
        }
    }
}
