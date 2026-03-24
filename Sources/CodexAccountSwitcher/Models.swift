import Foundation

struct CodexProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var cachedSnapshot: CachedProfileSnapshot?
    let createdAt: Date
    var updatedAt: Date
}

struct CachedProfileSnapshot: Codable, Equatable {
    let account: CodexAccount
    let rateLimits: RateLimitSnapshot
    let fetchedAt: Date
}

enum RefreshIntervalPreset: String, Codable, CaseIterable {
    case manual
    case oneMinute
    case fiveMinutes
    case fifteenMinutes

    var displayName: String {
        switch self {
        case .manual:
            return "手动"
        case .oneMinute:
            return "1 分钟"
        case .fiveMinutes:
            return "5 分钟"
        case .fifteenMinutes:
            return "15 分钟"
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
            return "双条"
        case .text:
            return "文本"
        }
    }
}

enum ProfileHealthStatus: String, Codable, Equatable {
    case healthy
    case readFailure
    case needsLogin
    case expired

    var label: String {
        switch self {
        case .healthy:
            return "正常"
        case .readFailure:
            return "读取失败"
        case .needsLogin:
            return "需要重新登录"
        case .expired:
            return "过期"
        }
    }

    var isHealthy: Bool {
        self == .healthy
    }
}

struct AppSettings: Codable {
    var lastActiveProfileID: UUID?
    var storageVersion: Int
    var refreshIntervalPreset: RefreshIntervalPreset
    var launchAtLoginEnabled: Bool
    var statusItemStyle: StatusItemStyle
    var autoOpenCodexAfterSwitch: Bool

    static let currentStorageVersion = 2

    init(
        lastActiveProfileID: UUID?,
        storageVersion: Int = 0,
        refreshIntervalPreset: RefreshIntervalPreset = .fiveMinutes,
        launchAtLoginEnabled: Bool = false,
        statusItemStyle: StatusItemStyle = .meter,
        autoOpenCodexAfterSwitch: Bool = true
    ) {
        self.lastActiveProfileID = lastActiveProfileID
        self.storageVersion = storageVersion
        self.refreshIntervalPreset = refreshIntervalPreset
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.statusItemStyle = statusItemStyle
        self.autoOpenCodexAfterSwitch = autoOpenCodexAfterSwitch
    }

    private enum CodingKeys: String, CodingKey {
        case lastActiveProfileID
        case storageVersion
        case refreshIntervalPreset
        case launchAtLoginEnabled
        case statusItemStyle
        case autoOpenCodexAfterSwitch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastActiveProfileID = try container.decodeIfPresent(UUID.self, forKey: .lastActiveProfileID)
        storageVersion = try container.decodeIfPresent(Int.self, forKey: .storageVersion) ?? 0
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
        autoOpenCodexAfterSwitch = try container.decodeIfPresent(
            Bool.self,
            forKey: .autoOpenCodexAfterSwitch
        ) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(lastActiveProfileID, forKey: .lastActiveProfileID)
        try container.encode(storageVersion, forKey: .storageVersion)
        try container.encode(refreshIntervalPreset, forKey: .refreshIntervalPreset)
        try container.encode(launchAtLoginEnabled, forKey: .launchAtLoginEnabled)
        try container.encode(statusItemStyle, forKey: .statusItemStyle)
        try container.encode(autoOpenCodexAfterSwitch, forKey: .autoOpenCodexAfterSwitch)
    }
}

struct CodexSnapshot: Equatable {
    let account: CodexAccount
    let rateLimits: RateLimitSnapshot
    let fetchedAt: Date
}

extension CodexSnapshot {
    var cached: CachedProfileSnapshot {
        CachedProfileSnapshot(account: account, rateLimits: rateLimits, fetchedAt: fetchedAt)
    }
}

struct CodexAccount: Codable, Equatable {
    let type: String
    let email: String?
    let planType: String?
}

struct RateLimitSnapshot: Codable, Equatable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let planType: String?
}

struct RateLimitWindow: Codable, Equatable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int?
}

extension CodexAccount {
    var displayLabel: String {
        if let email, !email.isEmpty {
            if let planType, !planType.isEmpty {
                return "\(email) · \(planType)"
            }
            return email
        }
        return type == "apiKey" ? "API Key" : "未登录"
    }

    var normalizedEmail: String? {
        email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func matchesIdentity(_ other: CodexAccount) -> Bool {
        if type != other.type {
            return false
        }

        if normalizedEmail != other.normalizedEmail {
            return false
        }

        return planType == other.planType
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

func resolveActiveProfileID(
    lastActiveProfileID: UUID?,
    profiles: [CodexProfile],
    currentSnapshot: CodexSnapshot?
) -> UUID? {
    if let lastActiveProfileID,
       profiles.contains(where: { $0.id == lastActiveProfileID }) {
        return lastActiveProfileID
    }

    guard let email = currentSnapshot?.account.normalizedEmail else {
        return nil
    }

    let matches = profiles.filter {
        $0.cachedSnapshot?.account.normalizedEmail == email
    }

    return matches.count == 1 ? matches[0].id : nil
}

func classifyProfileHealth(from error: Error) -> ProfileHealthStatus {
    if let credentialError = error as? CredentialStoreError {
        switch credentialError {
        case .itemNotFound, .keychainError:
            return .readFailure
        }
    }

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
