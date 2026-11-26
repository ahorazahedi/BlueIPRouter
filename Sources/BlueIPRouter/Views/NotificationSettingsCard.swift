import BlueIPRouterCore
import SwiftUI
import UserNotifications

struct NotificationSettingsCard: View {
    @Environment(AppModel.self) private var model
    @State private var status: UNAuthorizationStatus = .notDetermined

    var body: some View {
        @Bindable var model = model
        Card(L10n.tr("Notifications"), symbol: "bell.badge") {
            if status == .denied {
                Label(L10n.tr("Notifications are turned off for BlueIPRouter in System Settings."), systemImage: "bell.slash")
                    .foregroundStyle(.orange)
                Button(L10n.tr("Open Notification Settings")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            }
            Toggle(L10n.tr("Public IP or country changes"), isOn: $model.workspace.settings.notifications.publicIP)
            Toggle(L10n.tr("VPN tunnel connects or drops, or internet traffic switches interface"), isOn: $model.workspace.settings.notifications.egress)
            Toggle(L10n.tr("Kill switch is armed or turned off"), isOn: $model.workspace.settings.notifications.killSwitch)
            Toggle(L10n.tr("A routing rule fails"), isOn: $model.workspace.settings.notifications.ruleFailures)
            Toggle(L10n.tr("Network, interface and profile changes"), isOn: $model.workspace.settings.notifications.networkEvents)
            Toggle(L10n.tr("A new version is available"), isOn: $model.workspace.settings.notifications.updates)
            Text(L10n.tr("Triggers with “Send a notification” always notify. Events come from the background service, so they are also recorded while the app is closed and shown when it next runs."))
                .font(.caption).foregroundStyle(.secondary)
            Button(L10n.tr("Send Test Notification")) { Notifier.post("BlueIPRouter", L10n.tr("Notifications are working.")) }
        }
        .task { status = await Notifier.authorizationStatus() }
    }
}
