import AppKit
import BlueIPRouterCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest") { Task { await SelfTest.run() } ; return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct BlueIPRouterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

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
        }

        Settings {
            SettingsView().environment(model).frame(width: 520)
        }
    }
}
