import BlueIPRouterCore
import Foundation
import UserNotifications

/// macOS notifications (only when running as a bundled app).
enum Notifier {
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static func requestAuthorization() async -> Bool {
        guard available else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        guard available else { return .denied }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func post(_ title: String, _ body: String, id: String = UUID().uuidString) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

struct NotificationPrefs: Codable, Hashable {
    var publicIP = true
    var egress = true
    var ruleFailures = true
    var killSwitch = true
    var networkEvents = false
    var updates = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotificationPrefs()
        publicIP = (try? c.decodeIfPresent(Bool.self, forKey: .publicIP)) ?? d.publicIP
        egress = (try? c.decodeIfPresent(Bool.self, forKey: .egress)) ?? d.egress
        ruleFailures = (try? c.decodeIfPresent(Bool.self, forKey: .ruleFailures)) ?? d.ruleFailures
        killSwitch = (try? c.decodeIfPresent(Bool.self, forKey: .killSwitch)) ?? d.killSwitch
        networkEvents = (try? c.decodeIfPresent(Bool.self, forKey: .networkEvents)) ?? d.networkEvents
        updates = (try? c.decodeIfPresent(Bool.self, forKey: .updates)) ?? d.updates
    }

    /// Whether a helper event of this kind should produce a notification.
    func wants(_ e: BIREvent) -> Bool {
        if e.notify { return true }
        switch e.kind {
        case "tunnelUp", "tunnelDown", "egressChanged": return egress
        case "killSwitchArmed", "killSwitchDisarmed": return killSwitch
        case "ruleFailed": return ruleFailures
        case "networkChanged", "profileChanged", "interfaceUp", "interfaceDown": return networkEvents
        default: return false
        }
    }
}

// MARK: - Updates

struct AvailableUpdate: Hashable {
    var version: String
    var pageURL: URL
    var downloadURL: URL?
    var notes: String
}

enum UpdateChecker {
    /// "owner/name" of the GitHub repository, from Info.plist (set by scripts/build.sh) so forks check their own releases.
    static var repository: String {
        (Bundle.main.object(forInfoDictionaryKey: "BlueIPRouterRepository") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "ahorazahedi/BlueIPRouter"
    }

    static func latest() async throws -> AvailableUpdate? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("BlueIPRouter/\(BIR.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200, let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String, let page = (j["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw URLError(.badServerResponse)
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isNewer(version, than: BIR.version) else { return nil }
        let assets = j["assets"] as? [[String: Any]] ?? []
        let zip = assets.compactMap { $0["browser_download_url"] as? String }.first { $0.hasSuffix(".zip") }.flatMap(URL.init(string:))
        return AvailableUpdate(version: version, pageURL: page, downloadURL: zip, notes: j["body"] as? String ?? "")
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
