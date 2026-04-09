import Foundation

enum RefreshIntervalPreset: String, Codable, CaseIterable {
    case manual
    case oneMinute
    case fiveMinutes
    case fifteenMinutes

    var displayName: String {
        switch self {
        case .manual:
            return AppLocalization.localized(en: "Manual", zh: "手动")
        case .oneMinute:
            return AppLocalization.localized(en: "1 minute", zh: "1 分钟")
        case .fiveMinutes:
            return AppLocalization.localized(en: "5 minutes", zh: "5 分钟")
        case .fifteenMinutes:
            return AppLocalization.localized(en: "15 minutes", zh: "15 分钟")
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .manual:
            return nil
        case .oneMinute:
            return 60
        case .fiveMinutes:
            return 300
        case .fifteenMinutes:
            return 900
        }
    }
}

enum StatusItemStyle: String, Codable, CaseIterable {
    case meter
    case text

    var displayName: String {
        switch self {
        case .meter:
            return AppLocalization.localized(en: "Meter", zh: "仪表")
        case .text:
            return AppLocalization.localized(en: "Text", zh: "文字")
        }
    }
}

enum ProfileHealthStatus: String, Codable, Equatable, Sendable {
    case healthy
    case readFailure
    case needsLogin
    case expired

    var label: String {
        switch self {
        case .healthy:
            return AppLocalization.localized(en: "Healthy", zh: "正常")
        case .readFailure:
            return AppLocalization.localized(en: "Read failed", zh: "读取失败")
        case .needsLogin:
            return AppLocalization.localized(en: "Sign in required", zh: "需要登录")
        case .expired:
            return AppLocalization.localized(en: "Expired", zh: "已过期")
        }
    }

    var isHealthy: Bool {
        self == .healthy
    }
}

struct AppSettings: Codable, Equatable {
    var refreshIntervalPreset: RefreshIntervalPreset
    var launchAtLoginEnabled: Bool
    var statusItemStyle: StatusItemStyle
    var appLanguage: AppLanguage
    var lastResolvedLanguage: ResolvedAppLanguage?
    var preferredAccountID: String?

    init(
        refreshIntervalPreset: RefreshIntervalPreset = .fiveMinutes,
        launchAtLoginEnabled: Bool = false,
        statusItemStyle: StatusItemStyle = .meter,
        appLanguage: AppLanguage = .system,
        lastResolvedLanguage: ResolvedAppLanguage? = nil,
        preferredAccountID: String? = nil
    ) {
        self.refreshIntervalPreset = refreshIntervalPreset
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.statusItemStyle = statusItemStyle
        self.appLanguage = appLanguage
        self.lastResolvedLanguage = lastResolvedLanguage
        self.preferredAccountID = preferredAccountID
    }

    private enum CodingKeys: String, CodingKey {
        case refreshIntervalPreset
        case launchAtLoginEnabled
        case statusItemStyle
        case appLanguage
        case lastResolvedLanguage
        case preferredAccountID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshIntervalPreset = try container.decodeIfPresent(
            RefreshIntervalPreset.self,
            forKey: .refreshIntervalPreset
        ) ?? .fiveMinutes
        launchAtLoginEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .launchAtLoginEnabled
        ) ?? false
        statusItemStyle = try container.decodeIfPresent(
            StatusItemStyle.self,
            forKey: .statusItemStyle
        ) ?? .meter
        appLanguage = try container.decodeIfPresent(
            AppLanguage.self,
            forKey: .appLanguage
        ) ?? .system
        lastResolvedLanguage = try container.decodeIfPresent(
            ResolvedAppLanguage.self,
            forKey: .lastResolvedLanguage
        )
        preferredAccountID = try container.decodeIfPresent(
            String.self,
            forKey: .preferredAccountID
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(refreshIntervalPreset, forKey: .refreshIntervalPreset)
        try container.encode(launchAtLoginEnabled, forKey: .launchAtLoginEnabled)
        try container.encode(statusItemStyle, forKey: .statusItemStyle)
        try container.encode(appLanguage, forKey: .appLanguage)
        try container.encodeIfPresent(lastResolvedLanguage, forKey: .lastResolvedLanguage)
        try container.encodeIfPresent(preferredAccountID, forKey: .preferredAccountID)
    }
}

struct CodexSnapshot: Codable, Equatable, Sendable {
    let account: CodexAccount
    let rateLimits: RateLimitSnapshot
    let fetchedAt: Date
}

struct CodexAccount: Codable, Equatable, Sendable {
    let type: String
    let email: String?
    let planType: String?
}

struct RateLimitSnapshot: Codable, Equatable, Sendable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let planType: String?
}

struct RateLimitWindow: Codable, Equatable, Sendable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int?
}

struct QuotaDisplayWindow: Equatable {
    let label: String
    let window: RateLimitWindow
}

extension CodexAccount {
    var displayLabel: String {
        if let email, !email.isEmpty {
            return email
        }
        return type == "apiKey"
            ? AppLocalization.localized(en: "API Key", zh: "API 密钥")
            : AppLocalization.localized(en: "Not signed in", zh: "未登录")
    }
}

extension RateLimitWindow {
    var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }

    var remainingPercentText: String {
        "\(Int(remainingPercent.rounded()))%"
    }

    var resetDate: Date? {
        guard let resetsAt else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(resetsAt))
    }
}

func quotaDisplayWindows(from snapshot: CodexSnapshot?) -> [QuotaDisplayWindow] {
    guard let snapshot else {
        return []
    }

    return quotaDisplayWindows(from: snapshot.rateLimits)
}

func quotaDisplayWindows(from rateLimits: RateLimitSnapshot) -> [QuotaDisplayWindow] {
    let rawWindows = [
        (index: 0, window: rateLimits.primary),
        (index: 1, window: rateLimits.secondary),
    ]
    .compactMap { entry -> (index: Int, window: RateLimitWindow)? in
        guard let window = entry.window else {
            return nil
        }
        return (index: entry.index, window: window)
    }
    .sorted { lhs, rhs in
        let lhsDuration = lhs.window.windowDurationMins ?? Int.max
        let rhsDuration = rhs.window.windowDurationMins ?? Int.max
        if lhsDuration != rhsDuration {
            return lhsDuration < rhsDuration
        }
        return lhs.index < rhs.index
    }

    return rawWindows.enumerated().map { offset, entry in
        QuotaDisplayWindow(
            label: quotaWindowLabel(
                durationMins: entry.window.windowDurationMins,
                position: offset,
                total: rawWindows.count
            ),
            window: entry.window
        )
    }
}

private func quotaWindowLabel(
    durationMins: Int?,
    position: Int,
    total: Int
) -> String {
    guard let durationMins, durationMins > 0 else {
        if total == 1 {
            return AppLocalization.localized(en: "quota", zh: "额度")
        }
        return AppLocalization.localized(en: "quota \(position + 1)", zh: "额度 \(position + 1)")
    }

    if durationMins % 10_080 == 0 {
        return "\(durationMins / 10_080)w"
    }
    if durationMins % 1_440 == 0 {
        return "\(durationMins / 1_440)d"
    }
    if durationMins % 60 == 0 {
        return "\(durationMins / 60)h"
    }
    return "\(durationMins)m"
}

func classifyProfileHealth(from error: Error) -> ProfileHealthStatus {
    if let rpcError = error as? CodexRPCError {
        switch rpcError {
        case .notLoggedIn:
            return .needsLogin
        case .rpc(let message), .invalidResponse(let message):
            let lowered = message.lowercased()
            if lowered.contains("expired") || lowered.contains("session expired") || lowered.contains("token expired") {
                return .expired
            }
            if lowered.contains("401")
                || lowered.contains("unauthorized")
                || lowered.contains("forbidden")
                || lowered.contains("login")
                || lowered.contains("sign in") {
                return .needsLogin
            }
            return .readFailure
        case .timeout, .missingExecutable:
            return .readFailure
        }
    }

    return .readFailure
}
