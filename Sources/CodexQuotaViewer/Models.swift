import Foundation

enum RefreshIntervalPreset: String, Codable, CaseIterable {
    case manual
    case oneMinute
    case fiveMinutes
    case fifteenMinutes

    var displayName: String {
        switch self {
        case .manual:
            return "Manual"
        case .oneMinute:
            return "1 minute"
        case .fiveMinutes:
            return "5 minutes"
        case .fifteenMinutes:
            return "15 minutes"
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
            return "Meter"
        case .text:
            return "Text"
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
            return "Healthy"
        case .readFailure:
            return "Read failed"
        case .needsLogin:
            return "Sign in required"
        case .expired:
            return "Expired"
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

    init(
        refreshIntervalPreset: RefreshIntervalPreset = .fiveMinutes,
        launchAtLoginEnabled: Bool = false,
        statusItemStyle: StatusItemStyle = .meter
    ) {
        self.refreshIntervalPreset = refreshIntervalPreset
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.statusItemStyle = statusItemStyle
    }

    private enum CodingKeys: String, CodingKey {
        case refreshIntervalPreset
        case launchAtLoginEnabled
        case statusItemStyle
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
    }
}

struct CodexSnapshot: Equatable {
    let account: CodexAccount
    let rateLimits: RateLimitSnapshot
    let fetchedAt: Date
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
            return email
        }
        return type == "apiKey" ? "API Key" : "Not signed in"
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
