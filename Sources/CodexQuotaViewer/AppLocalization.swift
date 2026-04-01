import Foundation

enum AppLanguage: String, Codable, CaseIterable {
    case system
    case en
    case zh

    var displayName: String {
        switch self {
        case .system:
            return AppLocalization.localized(en: "Follow System", zh: "跟随系统")
        case .en:
            return "English"
        case .zh:
            return "中文"
        }
    }
}

enum ResolvedAppLanguage: String, Codable, CaseIterable {
    case en
    case zh

    var localeIdentifier: String {
        switch self {
        case .en:
            return "en_US"
        case .zh:
            return "zh_CN"
        }
    }

    var webValue: String {
        rawValue
    }
}

struct SessionManagerUIConfig: Codable, Equatable {
    let language: ResolvedAppLanguage
}

func resolveAppLanguage(
    _ language: AppLanguage,
    preferredLanguages: [String] = Locale.preferredLanguages
) -> ResolvedAppLanguage {
    switch language {
    case .en:
        return .en
    case .zh:
        return .zh
    case .system:
        let preferred = preferredLanguages.first?.lowercased() ?? ""
        return preferred.hasPrefix("zh") ? .zh : .en
    }
}

private final class AppLocalizationStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var configuredLanguage: AppLanguage = .system
    private var preferredLanguages: [String] = Locale.preferredLanguages

    func set(language: AppLanguage, preferredLanguages: [String]) {
        lock.lock()
        configuredLanguage = language
        self.preferredLanguages = preferredLanguages
        lock.unlock()
    }

    func resolvedLanguage() -> ResolvedAppLanguage {
        lock.lock()
        let language = configuredLanguage
        let preferredLanguages = self.preferredLanguages
        lock.unlock()
        return resolveAppLanguage(language, preferredLanguages: preferredLanguages)
    }
}

private let appLocalizationStorage = AppLocalizationStorage()

enum AppLocalization {
    static func setPreferredLanguage(
        _ language: AppLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        appLocalizationStorage.set(language: language, preferredLanguages: preferredLanguages)
    }

    static var resolvedLanguage: ResolvedAppLanguage {
        appLocalizationStorage.resolvedLanguage()
    }

    static var locale: Locale {
        Locale(identifier: resolvedLanguage.localeIdentifier)
    }

    static func localized(en: String, zh: String) -> String {
        switch resolvedLanguage {
        case .en:
            return en
        case .zh:
            return zh
        }
    }

    static func sectionTitle(en: String, zh: String, count: Int) -> String {
        localized(
            en: "\(en) (\(count))",
            zh: "\(zh) (\(count))"
        )
    }

    static func accountVaultSummary(savedCount: Int) -> String {
        localized(
            en: "Local vault: \(savedCount) saved account(s)",
            zh: "本地账号仓：已保存 \(savedCount) 个账号"
        )
    }

    static func compactCurrentAccountName(_ name: String, isSelected: Bool) -> String {
        if isSelected {
            return localized(en: "\(name) · Selected", zh: "\(name) · 已选中")
        }
        return name
    }

    static func quotaUnavailableLabel() -> String {
        localized(en: "Quota --", zh: "额度 --")
    }

    static func statusPlaceholderSummary() -> String {
        localized(en: "5h- 1w-", zh: "5小时- 1周-")
    }

    static func currentAccountFallbackName() -> String {
        localized(en: "Current Account", zh: "当前账号")
    }
}
