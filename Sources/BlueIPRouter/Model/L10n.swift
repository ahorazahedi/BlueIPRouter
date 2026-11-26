import BlueIPRouterCore
import Foundation

enum L10n {
    private static let resourceBundle: Bundle = {
        let name = "BlueIPRouter_BlueIPRouter.bundle"
        if let resURL = Bundle.main.resourceURL?.appendingPathComponent(name),
           let b = Bundle(url: resURL) {
            return b
        }
        let mainPath = Bundle.main.bundleURL.appendingPathComponent(name)
        if let b = Bundle(url: mainPath) {
            return b
        }
        if let resURL = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resURL.appendingPathComponent("ru.lproj").path) {
            return Bundle.main
        }
        return Bundle.module
    }()

    private static func bundle(for code: String) -> Bundle {
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let b = Bundle(path: path) {
            return b
        }
        if let path = resourceBundle.path(forResource: code, ofType: "lproj"),
           let b = Bundle(path: path) {
            return b
        }
        return resourceBundle
    }

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let code = AppLanguage.effectiveCode
        let b = bundle(for: code)
        let template = b.localizedString(forKey: key, value: key, table: nil)
        guard !args.isEmpty else { return template }
        let locale = Locale(identifier: code == "ru" ? "ru_RU" : "en_US")
        return String(format: template, locale: locale, arguments: args)
    }

    /// Russian has three plural forms; picks the one matching the count.
    private static func russianPlural(_ count: Int, one: String, few: String, many: String) -> String {
        let n = abs(count) % 100
        let n1 = n % 10
        if n > 10 && n < 20 { return "\(count) \(many)" }
        if n1 == 1 { return "\(count) \(one)" }
        if n1 >= 2 && n1 <= 4 { return "\(count) \(few)" }
        return "\(count) \(many)"
    }

    static func pluralRule(_ count: Int) -> String {
        if !AppLanguage.isRussian { return count == 1 ? "1 rule" : "\(count) rules" }
        return russianPlural(count, one: "правило", few: "правила", many: "правил")
    }

    static func pluralChange(_ count: Int) -> String {
        if !AppLanguage.isRussian { return count == 1 ? "1 change" : "\(count) changes" }
        return russianPlural(count, one: "изменение", few: "изменения", many: "изменений")
    }

    static func pluralRoute(_ count: Int) -> String {
        if !AppLanguage.isRussian { return count == 1 ? "1 route" : "\(count) routes" }
        return russianPlural(count, one: "маршрут", few: "маршрута", many: "маршрутов")
    }

    static func pluralRange(_ count: Int) -> String {
        if !AppLanguage.isRussian { return count == 1 ? "1 range" : "\(count) ranges" }
        return russianPlural(count, one: "диапазон", few: "диапазона", many: "диапазонов")
    }
}
