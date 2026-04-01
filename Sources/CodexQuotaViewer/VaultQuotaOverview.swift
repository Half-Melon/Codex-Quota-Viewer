import Foundation

struct VaultQuotaSnapshotRecord: Codable, Equatable {
    let accountID: String
    let snapshot: CodexSnapshot?
    let healthStatus: ProfileHealthStatus
    let errorSummary: String?
    let fetchedAt: Date
    let authMode: CodexAuthMode
    let isCurrent: Bool
}

final class VaultQuotaCacheStore {
    private let cacheURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(cacheURL: URL) {
        self.cacheURL = cacheURL

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> [VaultQuotaSnapshotRecord] {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            return []
        }

        return try decoder.decode([VaultQuotaSnapshotRecord].self, from: Data(contentsOf: cacheURL))
    }

    func save(_ records: [VaultQuotaSnapshotRecord]) throws {
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(records).write(to: cacheURL, options: .atomic)
    }
}

enum QuotaTileState: Equatable {
    case healthy
    case lowQuota
    case signInRequired
    case expired
    case stale
    case readFailure
}

struct QuotaTileViewModel: Equatable {
    let profile: ProviderProfile
    let primaryText: String
    let secondaryText: String
    let state: QuotaTileState
}

struct AllAccountsSectionModel: Equatable {
    let title: String
    let profiles: [ProviderProfile]
}

struct QuotaOverviewState: Equatable {
    let chatGPTCount: Int
    let apiCount: Int
    let boardTiles: [QuotaTileViewModel]
    let sections: [AllAccountsSectionModel]
}

private enum QuotaProfilePriority: Int, Comparable {
    case healthy = 0
    case limited = 1
    case stale = 2
    case signInRequired = 3
    case expired = 4
    case readFailure = 5

    static func < (lhs: QuotaProfilePriority, rhs: QuotaProfilePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

private enum QuotaSectionKind {
    case availableQuota
    case exhaustedQuota
    case apiAccounts
    case needsAttention
}

func buildQuotaOverviewState(
    currentProfile: ProviderProfile?,
    vaultProfiles: [ProviderProfile],
    refreshIntervalPreset: RefreshIntervalPreset,
    now: Date = Date()
) -> QuotaOverviewState {
    let mergedProfiles = mergedQuotaProfiles(currentProfile: currentProfile, vaultProfiles: vaultProfiles)
    let chatGPTProfiles = mergedProfiles.filter { $0.authMode != .apiKey }
    let apiProfiles = mergedProfiles.filter { $0.authMode == .apiKey }

    let boardCandidates = prioritizedChatGPTProfiles(
        chatGPTProfiles,
        refreshIntervalPreset: refreshIntervalPreset,
        now: now
    )
    let boardProfiles = Array(boardCandidates.prefix(5))

    let boardTiles = boardProfiles.map {
        QuotaTileViewModel(
            profile: $0,
            primaryText: quotaTilePrimaryText(for: $0),
            secondaryText: quotaTileSecondaryText(for: $0),
            state: quotaTileState(for: $0, refreshIntervalPreset: refreshIntervalPreset, now: now)
        )
    }

    let sections = buildAllAccountsSections(
        from: mergedProfiles,
        refreshIntervalPreset: refreshIntervalPreset,
        now: now
    )

    return QuotaOverviewState(
        chatGPTCount: chatGPTProfiles.count,
        apiCount: apiProfiles.count,
        boardTiles: boardTiles,
        sections: sections
    )
}

func quotaTileState(
    for profile: ProviderProfile,
    refreshIntervalPreset: RefreshIntervalPreset,
    now: Date = Date()
) -> QuotaTileState {
    switch profile.healthStatus {
    case .needsLogin:
        return .signInRequired
    case .expired:
        return .expired
    case .readFailure:
        return .readFailure
    case .healthy:
        break
    }

    if isLowQuota(profile) {
        return .lowQuota
    }

    if let fetchedAt = profile.quotaFetchedAt,
       now.timeIntervalSince(fetchedAt) > staleThreshold(for: refreshIntervalPreset) {
        return .stale
    }

    return .healthy
}

func quotaTilePrimaryText(for profile: ProviderProfile) -> String {
    switch profile.healthStatus {
    case .needsLogin:
        return AppLocalization.localized(en: "Sign in required", zh: "需要登录")
    case .expired:
        return AppLocalization.localized(en: "Session expired", zh: "会话已过期")
    case .readFailure:
        return AppLocalization.localized(en: "Read failed", zh: "读取失败")
    case .healthy:
        return quotaDisplayWindows(for: profile)
            .first
            .map(compactQuotaWindowText)
            ?? AppLocalization.quotaUnavailableLabel()
    }
}

func quotaTileSecondaryText(for profile: ProviderProfile) -> String {
    switch profile.healthStatus {
    case .needsLogin:
        return AppLocalization.localized(en: "Refresh after login", zh: "登录后再刷新")
    case .expired:
        return AppLocalization.localized(en: "Sign in again to refresh", zh: "重新登录后刷新")
    case .readFailure:
        return condensedQuotaErrorText(profile.errorMessage)
    case .healthy:
        if isLowQuota(profile) {
            return quotaResetScheduleText(for: profile)
        }
        return quotaDisplayWindows(for: profile)
            .dropFirst()
            .first
            .map(compactQuotaWindowText)
            ?? ""
    }
}

func allAccountsMenuText(
    for profile: ProviderProfile,
    refreshIntervalPreset: RefreshIntervalPreset,
    now: Date = Date()
) -> String {
    if profile.authMode == .apiKey {
        let parts = [
            profile.displayName,
            profile.providerLabel == "default"
                ? AppLocalization.localized(en: "API Key", zh: "API 密钥")
                : profile.providerLabel,
            profile.baseURLHost,
            profile.model,
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

    let state = quotaTileState(for: profile, refreshIntervalPreset: refreshIntervalPreset, now: now)
    let trailing: String
    switch state {
    case .signInRequired:
        trailing = AppLocalization.localized(en: "Sign in required", zh: "需要登录")
    case .expired:
        trailing = AppLocalization.localized(en: "Expired", zh: "已过期")
    case .readFailure:
        trailing = condensedQuotaErrorText(profile.errorMessage)
    case .stale:
        trailing = AppLocalization.localized(en: "Stale", zh: "数据过旧")
    case .lowQuota:
        trailing = quotaResetScheduleText(for: profile)
    case .healthy:
        let summaries = quotaDisplayWindows(for: profile).map(compactQuotaWindowText)
        trailing = summaries.isEmpty ? AppLocalization.quotaUnavailableLabel() : summaries.joined(separator: " · ")
    }

    return "\(profile.displayName) · \(trailing)"
}

@MainActor
final class VaultQuotaRefreshCoordinator {
    typealias SnapshotFetcher = (ProfileRuntimeMaterial) async throws -> CodexSnapshot
    typealias UpdateHandler = @MainActor ([VaultQuotaSnapshotRecord]) -> Void

    struct Request {
        let currentProfile: ProviderProfile?
        let vaultAccounts: [VaultAccountRecord]
        let cachedRecords: [VaultQuotaSnapshotRecord]
    }

    private let snapshotFetcher: SnapshotFetcher
    private var activeTask: Task<Void, Never>?
    private var pendingRequest: Request?
    private var pendingHandler: UpdateHandler?

    init(snapshotFetcher: @escaping SnapshotFetcher) {
        self.snapshotFetcher = snapshotFetcher
    }

    var isRefreshing: Bool {
        activeTask != nil
    }

    func requestRefresh(
        _ request: Request,
        onUpdate: @escaping UpdateHandler
    ) {
        if activeTask != nil {
            pendingRequest = request
            pendingHandler = onUpdate
            return
        }

        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(request, onUpdate: onUpdate)
        }
    }

    private func run(
        _ request: Request,
        onUpdate: @escaping UpdateHandler
    ) async {
        let activeAccountIDs = Set(request.vaultAccounts.map(\.id))
        var recordsByID = Dictionary(
            uniqueKeysWithValues: request.cachedRecords
                .filter { activeAccountIDs.contains($0.accountID) }
                .map { ($0.accountID, $0) }
        )
        let now = Date()
        var reusedCurrentAccountIDs = Set<String>()

        if let currentProfile = request.currentProfile {
            for record in request.vaultAccounts where shouldReuseCurrentSnapshot(for: record, currentProfile: currentProfile) {
                recordsByID[record.id] = VaultQuotaSnapshotRecord(
                    accountID: record.id,
                    snapshot: currentProfile.snapshot,
                    healthStatus: currentProfile.healthStatus,
                    errorSummary: currentProfile.errorMessage,
                    fetchedAt: currentProfile.quotaFetchedAt ?? now,
                    authMode: currentProfile.authMode,
                    isCurrent: true
                )
                reusedCurrentAccountIDs.insert(record.id)
            }
            onUpdate(sortedQuotaRecords(recordsByID.values))
        }

        for record in request.vaultAccounts {
            if reusedCurrentAccountIDs.contains(record.id) {
                continue
            }

            if record.metadata.authMode == .apiKey {
                recordsByID[record.id] = VaultQuotaSnapshotRecord(
                    accountID: record.id,
                    snapshot: nil,
                    healthStatus: .healthy,
                    errorSummary: AppLocalization.localized(
                        en: "Official quota unavailable",
                        zh: "官方额度不可用"
                    ),
                    fetchedAt: now,
                    authMode: .apiKey,
                    isCurrent: false
                )
                onUpdate(sortedQuotaRecords(recordsByID.values))
                continue
            }

            do {
                let snapshot = try await snapshotFetcher(record.runtimeMaterial)
                recordsByID[record.id] = VaultQuotaSnapshotRecord(
                    accountID: record.id,
                    snapshot: snapshot,
                    healthStatus: .healthy,
                    errorSummary: nil,
                    fetchedAt: snapshot.fetchedAt,
                    authMode: .chatgpt,
                    isCurrent: false
                )
            } catch {
                recordsByID[record.id] = VaultQuotaSnapshotRecord(
                    accountID: record.id,
                    snapshot: nil,
                    healthStatus: classifyProfileHealth(from: error),
                    errorSummary: userFacingErrorMessage(error),
                    fetchedAt: Date(),
                    authMode: record.metadata.authMode,
                    isCurrent: false
                )
            }

            onUpdate(sortedQuotaRecords(recordsByID.values))
        }

        activeTask = nil

        if let pendingRequest {
            let nextHandler = pendingHandler ?? onUpdate
            self.pendingRequest = nil
            self.pendingHandler = nil
            requestRefresh(pendingRequest, onUpdate: nextHandler)
        }
    }
}

private func mergedQuotaProfiles(
    currentProfile: ProviderProfile?,
    vaultProfiles: [ProviderProfile]
) -> [ProviderProfile] {
    var orderedIDs: [String] = []
    var profilesByID: [String: ProviderProfile] = [:]

    for profile in [currentProfile].compactMap({ $0 }) + vaultProfiles {
        if let existing = profilesByID[profile.id] {
            profilesByID[profile.id] = preferredMergedQuotaProfile(existing, profile)
            continue
        }

        orderedIDs.append(profile.id)
        profilesByID[profile.id] = profile
    }

    return orderedIDs.compactMap { profilesByID[$0] }
}

private func prioritizedChatGPTProfiles(
    _ profiles: [ProviderProfile],
    refreshIntervalPreset: RefreshIntervalPreset,
    now: Date
) -> [ProviderProfile] {
    profiles.sorted { lhs, rhs in
        let lhsPriority = quotaProfilePriority(for: lhs, refreshIntervalPreset: refreshIntervalPreset, now: now)
        let rhsPriority = quotaProfilePriority(for: rhs, refreshIntervalPreset: refreshIntervalPreset, now: now)

        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        let lhsLastUsed = lhs.lastUsedAt ?? .distantPast
        let rhsLastUsed = rhs.lastUsedAt ?? .distantPast
        if lhsLastUsed != rhsLastUsed {
            return lhsLastUsed > rhsLastUsed
        }

        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
}

private func buildAllAccountsSections(
    from profiles: [ProviderProfile],
    refreshIntervalPreset: RefreshIntervalPreset,
    now: Date
) -> [AllAccountsSectionModel] {
    let chatGPTProfiles = profiles.filter { $0.authMode != .apiKey }
    let apiProfiles = profiles.filter { $0.authMode == .apiKey }

    let availableProfiles = prioritizedChatGPTProfiles(
        chatGPTProfiles.filter {
            quotaSectionKind(for: $0, refreshIntervalPreset: refreshIntervalPreset, now: now) == .availableQuota
        },
        refreshIntervalPreset: refreshIntervalPreset,
        now: now
    )
    let exhaustedProfiles = prioritizedChatGPTProfiles(
        chatGPTProfiles.filter {
            quotaSectionKind(for: $0, refreshIntervalPreset: refreshIntervalPreset, now: now) == .exhaustedQuota
        },
        refreshIntervalPreset: refreshIntervalPreset,
        now: now
    )
    let signInProfiles = prioritizedChatGPTProfiles(
        chatGPTProfiles.filter {
            quotaSectionKind(for: $0, refreshIntervalPreset: refreshIntervalPreset, now: now) == .needsAttention
        },
        refreshIntervalPreset: refreshIntervalPreset,
        now: now
    )
    let sortedAPIProfiles = apiProfiles.sorted { lhs, rhs in
        let lhsLastUsed = lhs.lastUsedAt ?? .distantPast
        let rhsLastUsed = rhs.lastUsedAt ?? .distantPast
        if lhsLastUsed != rhsLastUsed {
            return lhsLastUsed > rhsLastUsed
        }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    var sections: [AllAccountsSectionModel] = []
    if !availableProfiles.isEmpty {
        sections.append(
            AllAccountsSectionModel(
                title: AppLocalization.localized(en: "Available Quota", zh: "可用额度"),
                profiles: availableProfiles
            )
        )
    }
    if !exhaustedProfiles.isEmpty {
        sections.append(
            AllAccountsSectionModel(
                title: AppLocalization.localized(en: "Quota Exhausted", zh: "额度已用尽"),
                profiles: exhaustedProfiles
            )
        )
    }
    if !sortedAPIProfiles.isEmpty {
        sections.append(
            AllAccountsSectionModel(
                title: AppLocalization.localized(en: "API Accounts", zh: "API 账号"),
                profiles: sortedAPIProfiles
            )
        )
    }
    if !signInProfiles.isEmpty {
        sections.append(
            AllAccountsSectionModel(
                title: AppLocalization.localized(en: "Needs Attention", zh: "需要处理"),
                profiles: signInProfiles
            )
        )
    }
    return sections
}

private func quotaSectionKind(
    for profile: ProviderProfile,
    refreshIntervalPreset: RefreshIntervalPreset,
    now: Date
) -> QuotaSectionKind {
    if profile.authMode == .apiKey {
        return .apiAccounts
    }

    switch quotaTileState(for: profile, refreshIntervalPreset: refreshIntervalPreset, now: now) {
    case .healthy:
        return .availableQuota
    case .lowQuota:
        return .exhaustedQuota
    case .signInRequired, .expired, .stale, .readFailure:
        return .needsAttention
    }
}

private func quotaProfilePriority(
    for profile: ProviderProfile,
    refreshIntervalPreset: RefreshIntervalPreset,
    now: Date
) -> QuotaProfilePriority {
    switch quotaTileState(for: profile, refreshIntervalPreset: refreshIntervalPreset, now: now) {
    case .healthy:
        return .healthy
    case .lowQuota:
        return .limited
    case .stale:
        return .stale
    case .signInRequired:
        return .signInRequired
    case .expired:
        return .expired
    case .readFailure:
        return .readFailure
    }
}

private func shouldReuseCurrentSnapshot(
    for record: VaultAccountRecord,
    currentProfile: ProviderProfile
) -> Bool {
    if record.id == currentProfile.id {
        return true
    }

    return stableRuntimeIdentityMatches(record.runtimeMaterial, currentProfile.runtimeMaterial)
}

private func sortedQuotaRecords<S: Sequence>(_ records: S) -> [VaultQuotaSnapshotRecord]
where S.Element == VaultQuotaSnapshotRecord {
    records.sorted { lhs, rhs in
        if lhs.isCurrent != rhs.isCurrent {
            return lhs.isCurrent && !rhs.isCurrent
        }
        return lhs.accountID < rhs.accountID
    }
}

private func isLowQuota(_ profile: ProviderProfile) -> Bool {
    guard profile.authMode != .apiKey else {
        return false
    }

    let windows = quotaDisplayWindows(for: profile)
    guard !windows.isEmpty else {
        return false
    }

    return windows.contains { $0.window.remainingPercent <= 0 }
}

private func quotaDisplayWindows(for profile: ProviderProfile) -> [QuotaDisplayWindow] {
    quotaDisplayWindows(from: profile.snapshot)
}

private func compactQuotaWindowText(_ quotaWindow: QuotaDisplayWindow) -> String {
    "\(quotaWindow.label) \(quotaWindow.window.remainingPercentText)"
}

private func quotaResetScheduleText(for profile: ProviderProfile) -> String {
    let windows = quotaDisplayWindows(for: profile)
    guard !windows.isEmpty else {
        return AppLocalization.quotaUnavailableLabel()
    }

    return windows
        .map { quotaWindow in
            quotaResetText(
                window: quotaWindow.window,
                label: quotaWindow.label,
                style: quotaResetDateStyle(for: quotaWindow.window)
            )
        }
        .joined(separator: " · ")
}

private enum QuotaResetDateStyle {
    case time
    case monthDay
}

private func quotaResetDateStyle(for window: RateLimitWindow) -> QuotaResetDateStyle {
    if let duration = window.windowDurationMins,
       duration >= 1_440 {
        return .monthDay
    }
    return .time
}

private func quotaResetText(window: RateLimitWindow?, label: String, style: QuotaResetDateStyle) -> String {
    guard let date = window?.resetDate else {
        return "\(label) --"
    }

    let formatter = DateFormatter()
    formatter.locale = AppLocalization.locale
    switch style {
    case .time:
        formatter.dateFormat = "HH:mm"
    case .monthDay:
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
    }

    return "\(label) \(formatter.string(from: date))"
}

private func preferredMergedQuotaProfile(
    _ existing: ProviderProfile,
    _ candidate: ProviderProfile
) -> ProviderProfile {
    if candidate.isCurrent && !existing.isCurrent {
        return candidate
    }

    if existing.snapshot == nil && candidate.snapshot != nil {
        return candidate
    }

    if existing.healthStatus != .healthy && candidate.healthStatus == .healthy {
        return candidate
    }

    let existingFetchedAt = existing.quotaFetchedAt ?? .distantPast
    let candidateFetchedAt = candidate.quotaFetchedAt ?? .distantPast
    if candidateFetchedAt > existingFetchedAt {
        return candidate
    }

    return existing
}

private func condensedQuotaErrorText(_ message: String?) -> String {
    guard let message else {
        return AppLocalization.localized(en: "Refresh failed", zh: "刷新失败")
    }

    let lowered = message.lowercased()
    if lowered.contains("sign in") || lowered.contains("not signed in") || lowered.contains("unauthorized") {
        return AppLocalization.localized(en: "Sign in required", zh: "需要登录")
    }
    if lowered.contains("expired") {
        return AppLocalization.localized(en: "Session expired", zh: "会话已过期")
    }
    if lowered.contains("timed out") || lowered.contains("timeout") {
        return AppLocalization.localized(en: "Request timed out", zh: "请求超时")
    }
    return AppLocalization.localized(en: "Refresh failed", zh: "刷新失败")
}
