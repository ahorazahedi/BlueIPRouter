import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, ru, en

    public static let defaultsKey = "bir.language"

    public var id: String { rawValue }

    public static var stored: AppLanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let val = AppLanguage(rawValue: raw) else { return .system }
            return val
        }
        set {
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            } else {
                UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            }
        }
    }

    public static var effectiveCode: String {
        switch stored {
        case .ru: return "ru"
        case .en: return "en"
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            return preferred.hasPrefix("ru") ? "ru" : "en"
        }
    }

    public static var isRussian: Bool { effectiveCode == "ru" }
}

/// Lightweight localization helper for BlueIPRouterCore so helper binaries without bundles never crash.
public enum CoreL10n {
    public static func tr(_ en: String, _ ru: String, _ args: CVarArg...) -> String {
        let isRussian = AppLanguage.isRussian
        let fmt = isRussian ? ru : en
        guard !args.isEmpty else { return fmt }
        let locale = Locale(identifier: isRussian ? "ru_RU" : "en_US")
        return String(format: fmt, locale: locale, arguments: args)
    }
}
