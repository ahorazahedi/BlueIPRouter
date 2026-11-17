import Foundation
import ServiceManagement

/// "Open at login" for the app itself, through the system Login Items list (no scripts or plists).
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }
    static var needsApproval: Bool { status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

enum UIPrefs {
    static let menuBarKey = "menuBarEnabled"
    /// Show the menu bar icon and keep running when the window is closed (default on).
    static var menuBarEnabled: Bool { UserDefaults.standard.object(forKey: menuBarKey) as? Bool ?? true }
}
