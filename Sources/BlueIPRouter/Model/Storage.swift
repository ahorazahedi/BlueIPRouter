import BlueIPRouterCore
import Foundation

/// Service used to look up location and ISP for a public IP (the IP itself comes from api.ipify.org / api6.ipify.org).
enum GeoProvider: String, Codable, CaseIterable, Identifiable {
    case ipinfo, ipwhois

    var id: String { rawValue }
    var label: String {
        switch self {
        case .ipinfo: return "ipinfo.io"
        case .ipwhois: return "ipwho.is"
        }
    }
}

struct AppSettings: Codable, Hashable {
    var refreshSeconds: Double = 5
    var serviceIntervalSeconds: Int = 60
    var geoProvider: GeoProvider = .ipinfo
    var autoBackupLimit: Int = 25
    var showSystemInterfaces: Bool = false
    var hideLinkLayerRoutes: Bool = true

    init() {}

    /// Tolerates missing or unknown keys so older or newer settings files still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        refreshSeconds = (try? c.decodeIfPresent(Double.self, forKey: .refreshSeconds)) ?? d.refreshSeconds
        serviceIntervalSeconds = (try? c.decodeIfPresent(Int.self, forKey: .serviceIntervalSeconds)) ?? d.serviceIntervalSeconds
        geoProvider = (try? c.decodeIfPresent(GeoProvider.self, forKey: .geoProvider)) ?? d.geoProvider
        autoBackupLimit = (try? c.decodeIfPresent(Int.self, forKey: .autoBackupLimit)) ?? d.autoBackupLimit
        showSystemInterfaces = (try? c.decodeIfPresent(Bool.self, forKey: .showSystemInterfaces)) ?? d.showSystemInterfaces
        hideLinkLayerRoutes = (try? c.decodeIfPresent(Bool.self, forKey: .hideLinkLayerRoutes)) ?? d.hideLinkLayerRoutes
    }
}

/// The user's editable state. Rules here are the draft; the root files hold what is applied.
struct Workspace: Codable {
    var rules: [RouteRule] = []
    var aliases: [String: String] = [:]
    var settings = AppSettings()
    var killSwitch = KillSwitchConfig()
    var setupCompleted = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = try c.decodeIfPresent([RouteRule].self, forKey: .rules) ?? []
        aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        settings = (try? c.decodeIfPresent(AppSettings.self, forKey: .settings)) ?? AppSettings()
        killSwitch = (try? c.decodeIfPresent(KillSwitchConfig.self, forKey: .killSwitch)) ?? KillSwitchConfig()
        setupCompleted = (try? c.decodeIfPresent(Bool.self, forKey: .setupCompleted)) ?? false
    }
}

struct BackupBundle: Codable, Identifiable {
    var format = "BlueIPRouter.backup"
    var formatVersion = 1
    var createdAt: Date
    var appVersion: String
    var hostName: String
    var reason: String
    var rules: [RouteRule]
    var aliases: [String: String]
    var settings: AppSettings
    var routingSnapshot: [RouteEntry]
    var killSwitch: KillSwitchConfig?

    var id: Date { createdAt }
}

struct BackupFile: Identifiable, Hashable {
    var url: URL
    var createdAt: Date
    var reason: String
    var ruleCount: Int
    var id: URL { url }
}

enum Storage {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("BlueIPRouter", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var workspaceURL: URL { appSupport.appendingPathComponent("workspace.json") }
    static var stagingDir: URL {
        let u = appSupport.appendingPathComponent("staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var backupsDir: URL {
        let u = appSupport.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func loadWorkspace() -> Workspace? {
        guard let data = try? Data(contentsOf: workspaceURL) else { return nil }
        return try? BIRJSON.decoder.decode(Workspace.self, from: data)
    }

    static func save(_ workspace: Workspace) {
        guard let data = try? BIRJSON.encoder.encode(workspace) else { return }
        try? data.write(to: workspaceURL, options: .atomic)
    }

    static func write(_ bundle: BackupBundle, to url: URL) throws {
        try BIRJSON.encoder.encode(bundle).write(to: url, options: .atomic)
    }

    static func readBackup(_ url: URL) throws -> BackupBundle {
        let bundle = try BIRJSON.decoder.decode(BackupBundle.self, from: Data(contentsOf: url))
        guard bundle.format == "BlueIPRouter.backup" else {
            throw NSError(domain: "BlueIPRouter", code: 1, userInfo: [NSLocalizedDescriptionKey: "This file is not a BlueIPRouter backup."])
        }
        return bundle
    }

    static func saveAutoBackup(_ bundle: BackupBundle, limit: Int) {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let safeReason = bundle.reason.lowercased().replacingOccurrences(of: " ", with: "-").filter { $0.isLetter || $0 == "-" }
        let url = backupsDir.appendingPathComponent("\(f.string(from: bundle.createdAt))-\(safeReason).json")
        try? write(bundle, to: url)
        let all = listBackups()
        if all.count > limit {
            for old in all.suffix(from: limit) { try? FileManager.default.removeItem(at: old.url) }
        }
    }

    static func listBackups() -> [BackupFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let b = try? readBackup(url) else { return nil }
            return BackupFile(url: url, createdAt: b.createdAt, reason: b.reason, ruleCount: b.rules.count)
        }.sorted { $0.createdAt > $1.createdAt }
    }
}
