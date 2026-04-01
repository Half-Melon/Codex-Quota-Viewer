import Foundation

struct ProviderProfile: Equatable, Identifiable {
    enum Source: String, Codable, Equatable {
        case current
        case vault
    }

    let id: String
    let displayName: String
    let source: Source
    let runtimeMaterial: ProfileRuntimeMaterial
    let authMode: CodexAuthMode
    let providerID: String?
    let threadProviderID: String?
    let providerDisplayName: String?
    let baseURLHost: String?
    let model: String?
    let snapshot: CodexSnapshot?
    let healthStatus: ProfileHealthStatus
    let errorMessage: String?
    let isCurrent: Bool
    let managedFileURLs: [URL]
    let lastUsedAt: Date?
    let quotaFetchedAt: Date?

    init(
        id: String,
        displayName: String,
        source: Source,
        runtimeMaterial: ProfileRuntimeMaterial,
        authMode: CodexAuthMode,
        providerID: String?,
        threadProviderID: String? = nil,
        providerDisplayName: String?,
        baseURLHost: String?,
        model: String?,
        snapshot: CodexSnapshot?,
        healthStatus: ProfileHealthStatus,
        errorMessage: String?,
        isCurrent: Bool,
        managedFileURLs: [URL] = [],
        lastUsedAt: Date? = nil,
        quotaFetchedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.source = source
        self.runtimeMaterial = runtimeMaterial
        self.authMode = authMode
        self.providerID = providerID
        self.threadProviderID = threadProviderID ?? providerID
        self.providerDisplayName = providerDisplayName
        self.baseURLHost = baseURLHost
        self.model = model
        self.snapshot = snapshot
        self.healthStatus = healthStatus
        self.errorMessage = errorMessage
        self.isCurrent = isCurrent
        self.managedFileURLs = managedFileURLs
        self.lastUsedAt = lastUsedAt
        self.quotaFetchedAt = quotaFetchedAt ?? snapshot?.fetchedAt
    }

    var modeLabel: String {
        authMode.displayLabel
    }

    var providerLabel: String {
        if let providerDisplayName,
           !providerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return providerDisplayName
        }

        if let providerID,
           !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return providerID
        }

        return "default"
    }

    var switchSubtitle: String {
        let parts = [
            modeLabel,
            providerLabel == "default" ? nil : providerLabel,
            baseURLHost,
            model,
        ]
        .compactMap { value -> String? in
            guard let value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return value
        }

        return parts.joined(separator: " · ")
    }
}

func buildProviderProfile(
    id: String,
    fallbackDisplayName: String,
    source: ProviderProfile.Source,
    runtimeMaterial: ProfileRuntimeMaterial,
    snapshot: CodexSnapshot?,
    healthStatus: ProfileHealthStatus,
    errorMessage: String?,
    isCurrent: Bool,
    managedFileURLs: [URL] = [],
    lastUsedAt: Date? = nil,
    quotaFetchedAt: Date? = nil
) -> ProviderProfile {
    let canonicalRuntimeMaterial = canonicalRuntimeMaterialForStorage(runtimeMaterial)
    let summary = summarizeRuntimeConfig(canonicalRuntimeMaterial.configData)
    let inferredAuthMode = snapshot?.account.type == "apiKey"
        ? CodexAuthMode.apiKey
        : resolveAuthMode(authData: canonicalRuntimeMaterial.authData)
    let preferredName = snapshot?.account.email?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = preferredName?.isEmpty == false
        ? preferredName!
        : fallbackDisplayName

    return ProviderProfile(
        id: id,
        displayName: displayName,
        source: source,
        runtimeMaterial: canonicalRuntimeMaterial,
        authMode: inferredAuthMode == .unknown ? .chatgpt : inferredAuthMode,
        providerID: summary.providerID,
        threadProviderID: summary.threadProviderID,
        providerDisplayName: summary.providerName,
        baseURLHost: displayHost(from: summary.baseURL),
        model: summary.model,
        snapshot: snapshot,
        healthStatus: healthStatus,
        errorMessage: errorMessage,
        isCurrent: isCurrent,
        managedFileURLs: managedFileURLs,
        lastUsedAt: lastUsedAt,
        quotaFetchedAt: quotaFetchedAt
    )
}

struct ProviderCount: Equatable {
    let providerID: String
    let count: Int
}

enum LocalThreadSyncStatus: Equatable {
    case healthy(expectedProvider: String?)
    case repairNeeded(expectedProvider: String?, rolloutProviders: [ProviderCount], threadProviders: [ProviderCount])
    case unavailable(String)

    var label: String {
        switch self {
        case .healthy:
            return AppLocalization.localized(en: "Healthy", zh: "正常")
        case .repairNeeded:
            return AppLocalization.localized(en: "Needs Repair", zh: "需要修复")
        case .unavailable:
            return AppLocalization.localized(en: "Unknown", zh: "未知")
        }
    }

    var detail: String {
        switch self {
        case .healthy(let expectedProvider):
            guard let expectedProvider,
                  !expectedProvider.isEmpty else {
                return AppLocalization.localized(
                    en: "Local thread metadata is aligned.",
                    zh: "本地线程元数据已对齐。"
                )
            }
            return AppLocalization.localized(
                en: "Provider aligned: \(expectedProvider)",
                zh: "Provider 已对齐：\(expectedProvider)"
            )
        case .repairNeeded(let expectedProvider, let rolloutProviders, let threadProviders):
            let expectedText = expectedProvider?.isEmpty == false
                ? expectedProvider!
                : AppLocalization.localized(en: "unknown", zh: "未知")
            return AppLocalization.localized(
                en: "Expected \(expectedText) · Rollout \(describeProviderCounts(rolloutProviders)) · Threads \(describeProviderCounts(threadProviders))",
                zh: "预期 \(expectedText) · Rollout \(describeProviderCounts(rolloutProviders)) · Threads \(describeProviderCounts(threadProviders))"
            )
        case .unavailable(let message):
            return message
        }
    }
}

enum SafeSwitchPrimaryAction: Equatable {
    case switchSafely
    case repairNow
    case rollbackLastChange
}

struct SafeSwitchRecommendation: Equatable {
    let message: String
    let action: SafeSwitchPrimaryAction
}

struct SafeSwitchCenterState: Equatable {
    let currentProfile: ProviderProfile?
    let availableTargets: [ProviderProfile]
    let codexIsRunning: Bool
    let localThreadSyncStatus: LocalThreadSyncStatus
    let latestRestorePoint: RestorePointManifest?
    let recommendation: SafeSwitchRecommendation?
}

struct StatusEvaluator {
    func currentState(
        currentProfile: ProviderProfile?,
        availableTargets: [ProviderProfile],
        codexIsRunning: Bool,
        localThreadSyncStatus: LocalThreadSyncStatus,
        latestRestorePoint: RestorePointManifest?
    ) -> SafeSwitchCenterState {
        let recommendation: SafeSwitchRecommendation?

        switch localThreadSyncStatus {
        case .repairNeeded:
            recommendation = SafeSwitchRecommendation(
                message: AppLocalization.localized(
                    en: "Local thread metadata does not match the current provider. Repair is recommended before you continue.",
                    zh: "本地线程元数据与当前 provider 不一致。建议先执行修复，再继续操作。"
                ),
                action: .repairNow
            )
        case .healthy, .unavailable:
            if currentProfile == nil {
                recommendation = nil
            } else if availableTargets.isEmpty {
                recommendation = nil
            } else if latestRestorePoint == nil {
                recommendation = SafeSwitchRecommendation(
                    message: AppLocalization.localized(
                        en: "The first safe switch will create a restore point automatically.",
                        zh: "第一次安全切换会自动创建还原点。"
                    ),
                    action: .switchSafely
                )
            } else {
                recommendation = nil
            }
        }

        return SafeSwitchCenterState(
            currentProfile: currentProfile,
            availableTargets: availableTargets,
            codexIsRunning: codexIsRunning,
            localThreadSyncStatus: localThreadSyncStatus,
            latestRestorePoint: latestRestorePoint,
            recommendation: recommendation
        )
    }
}

func describeProviderCounts(_ counts: [ProviderCount]) -> String {
    guard !counts.isEmpty else {
        return AppLocalization.localized(en: "none", zh: "无")
    }

    return counts
        .map { entry in
            let provider = entry.providerID.isEmpty ? "(empty)" : entry.providerID
            return "\(provider):\(entry.count)"
        }
        .joined(separator: ", ")
}
