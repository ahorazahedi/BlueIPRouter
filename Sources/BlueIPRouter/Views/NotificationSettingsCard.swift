import BlueIPRouterCore
import SwiftUI
import UserNotifications

struct NotificationSettingsCard: View {
    @Environment(AppModel.self) private var model
    @State private var status: UNAuthorizationStatus = .notDetermined

    var body: some View {
        @Bindable var model = model
        Card("Notifications", symbol: "bell.badge") {
            if status == .denied {
                Label("Notifications are turned off for BlueIPRouter in System Settings.", systemImage: "bell.slash")
                    .foregroundStyle(.orange)
                Button("Open Notification Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            }
            Toggle("Public IP or country changes", isOn: $model.workspace.settings.notifications.publicIP)
            Toggle("VPN tunnel connects or drops, or internet traffic switches interface", isOn: $model.workspace.settings.notifications.egress)
            Toggle("Kill switch is armed or turned off", isOn: $model.workspace.settings.notifications.killSwitch)
            Toggle("A routing rule fails", isOn: $model.workspace.settings.notifications.ruleFailures)
            Toggle("Network, interface and profile changes", isOn: $model.workspace.settings.notifications.networkEvents)
            Toggle("A new version is available", isOn: $model.workspace.settings.notifications.updates)
            Text("Triggers with “Send a notification” always notify. Events come from the background service, so they are also recorded while the app is closed and shown when it next runs.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Send Test Notification") { Notifier.post("BlueIPRouter", "Notifications are working.") }
        }
        .task { status = await Notifier.authorizationStatus() }
    }
}
