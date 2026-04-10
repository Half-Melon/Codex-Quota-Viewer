import Foundation

struct VaultQuotaSnapshotRecord: Codable, Equatable, Sendable {
    let accountID: String
    let snapshot: CodexSnapshot?
    let healthStatus: ProfileHealthStatus
    let errorSummary: String?
    let failureDisposition: QuotaFailureDisposition?
    let fetchedAt: Date
    let authMode: CodexAuthMode
    let isCurrent: Bool

    init(
        accountID: String,
        snapshot: CodexSnapshot?,
        healthStatus: ProfileHealthStatus,
        errorSummary: String?,
        failureDisposition: QuotaFailureDisposition? = nil,
        fetchedAt: Date,
        authMode: CodexAuthMode,
        isCurrent: Bool
    ) {
        self.accountID = accountID
        self.snapshot = snapshot
        self.healthStatus = healthStatus
        self.errorSummary = errorSummary
        self.failureDisposition = failureDisposition
        self.fetchedAt = fetchedAt
        self.authMode = authMode
        self.isCurrent = isCurrent
    }
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

    var hasProfiles: Bool {
        sections.contains { !$0.profiles.isEmpty }
    }

    var isAPIOnly: Bool {
        chatGPTCount == 0 && apiCount > 0
    }
}

struct QuotaOverviewRowQuotaTexts: Equatable {
    let primaryRemainingText: String
    let secondaryRemainingText: String
    let primaryResetText: String
    let secondaryResetText: String
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

func quotaOverviewRowQuotaTexts(for profile: ProviderProfile) -> QuotaOverviewRowQuotaTexts {
    let windowsByLabel = Dictionary(
        uniqueKeysWithValues: quotaDisplayWindows(for: profile).map { ($0.label, $0.window) }
    )
    let primaryLabel = "5h"
    let secondaryLabel = "1w"
    let primaryWindow = windowsByLabel[primaryLabel]
    let secondaryWindow = windowsByLabel[secondaryLabel]

    return QuotaOverviewRowQuotaTexts(
        primaryRemainingText: quotaOverviewRowRemainingText(label: primaryLabel, window: primaryWindow),
        secondaryRemainingText: quotaOverviewRowRemainingText(label: secondaryLabel, window: secondaryWindow),
        primaryResetText: quotaOverviewRowResetText(label: primaryLabel, window: primaryWindow),
        secondaryResetText: quotaOverviewRowResetText(label: secondaryLabel, window: secondaryWindow)
    )
}

func allAccountsMenuText(
    for profile: ProviderProfile,
    refreshIntervalPreset: RefreshIntervalPreset,
    now: Date = Date()
) -> String {
    if profile.authMode == .apiKey {
        return joinedNonEmptyParts([
            profile.displayName,
            profile.providerLabel == "default"
                ? AppLocalization.localized(en: "API Key", zh: "API 密钥")
                : profile.providerLabel,
            profile.baseURLHost,
            profile.model,
        ])
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
        trailing = summaries.isEmpty ? AppLocalization.quotaUnavailableLabel() : joinedNonEmptyParts(summaries.map { Optional($0) })
    }

    return "\(profile.displayName) · \(trailing)"
}

@MainActor
final class VaultQuotaRefreshCoordinator {
    typealias SnapshotFetcher = (ProfileRuntimeMaterial, TimeInterval) async throws -> CodexSnapshot
    typealias UpdateHandler = @MainActor ([VaultQuotaSnapshotRecord]) -> Void
    typealias CompletionHandler = @MainActor ([VaultQuotaSnapshotRecord]) -> Void

    enum RefreshPolicy: Equatable, Sendable {
        case currentOnly

        case menuOpenSelective(staleAfter: TimeInterval)
        case manualFull

        var requestScopeKey: String {
            switch self {
            case .currentOnly:
                return "currentOnly"
            case .menuOpenSelective(let staleAfter):
                return "menuOpenSelective:\(Int(staleAfter.rounded()))"
            case .manualFull:
                return "manualFull"
            }
        }

        var retryConfiguration: RetryConfiguration? {
            switch self {
            case .currentOnly:
                return nil
            case .menuOpenSelective:
                return RetryConfiguration(initialTimeout: 6, retryTimeout: 12)
            case .manualFull:
                return RetryConfiguration(initialTimeout: 10, retryTimeout: 15)
            }
        }
    }

    struct Request {
        let currentProfile: ProviderProfile?
        let vaultAccounts: [VaultAccountRecord]
        let cachedRecords: [VaultQuotaSnapshotRecord]
        let refreshPolicy: RefreshPolicy

        init(
            currentProfile: ProviderProfile?,
            vaultAccounts: [VaultAccountRecord],
            cachedRecords: [VaultQuotaSnapshotRecord],
            refreshPolicy: RefreshPolicy = .manualFull
        ) {
            self.currentProfile = currentProfile
            self.vaultAccounts = vaultAccounts
            self.cachedRecords = cachedRecords
            self.refreshPolicy = refreshPolicy
        }
    }

    struct RetryConfiguration: Sendable {
        let initialTimeout: TimeInterval
        let retryTimeout: TimeInterval
    }

    private struct FetchTarget: Sendable {
        let accountID: String
        let runtimeMaterial: ProfileRuntimeMaterial
        let authMode: CodexAuthMode
    }

    private final class SnapshotFetcherBox: @unchecked Sendable {
        let fetch: SnapshotFetcher

        init(fetch: @escaping SnapshotFetcher) {
            self.fetch = fetch
        }
    }

    private let snapshotFetcherBox: SnapshotFetcherBox
    private let maxConcurrentChatGPTRefreshes: Int
    private let nowProvider: @Sendable () -> Date
    private var activeTask: Task<Void, Never>?
    private var activeRequest: Request?
    private var pendingRequest: Request?
    private var pendingHandler: UpdateHandler?
    private var pendingCompletionHandler: CompletionHandler?
    private var pendingPresentationRefresh = DeferredPresentationRefreshState()

    init(
        maxConcurrentChatGPTRefreshes: Int = 3,
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        snapshotFetcher: @escaping SnapshotFetcher
    ) {
        self.maxConcurrentChatGPTRefreshes = max(1, maxConcurrentChatGPTRefreshes)
        self.nowProvider = nowProvider
        snapshotFetcherBox = SnapshotFetcherBox(fetch: snapshotFetcher)
    }

    var isRefreshing: Bool {
        activeTask != nil
    }

    func requestRefresh(
        _ request: Request,
        onUpdate: @escaping UpdateHandler,
        onComplete: CompletionHandler? = nil
    ) {
        if let activeRequest {
            if requestScopeKey(activeRequest) == requestScopeKey(request) {
                pendingPresentationRefresh.requestRefresh()
                pendingHandler = onUpdate
                pendingCompletionHandler = onComplete
                return
            }

            pendingRequest = request
            pendingHandler = onUpdate
            pendingCompletionHandler = onComplete
            pendingPresentationRefresh = DeferredPresentationRefreshState()
            return
        }

        activeRequest = request
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(request, onUpdate: onUpdate, onComplete: onComplete)
        }
    }

    private func run(
        _ request: Request,
        onUpdate: @escaping UpdateHandler,
        onComplete: CompletionHandler?
    ) async {
        let activeAccountIDs = Set(request.vaultAccounts.map(\.id))
        var recordsByID = Dictionary(
            uniqueKeysWithValues: request.cachedRecords
                .filter { activeAccountIDs.contains($0.accountID) }
                .map { ($0.accountID, $0) }
        )
        let now = nowProvider()
        var reusedCurrentAccountIDs = Set<String>()

        if let currentProfile = request.currentProfile {
            for record in request.vaultAccounts where shouldReuseCurrentSnapshot(for: record, currentProfile: currentProfile) {
                recordsByID[record.id] = VaultQuotaSnapshotRecord(
                    accountID: record.id,
                    snapshot: currentProfile.snapshot,
                    healthStatus: currentProfile.healthStatus,
                    errorSummary: currentProfile.errorMessage,
                    failureDisposition: currentProfile.quotaFailureDisposition,
                    fetchedAt: currentProfile.quotaFetchedAt ?? now,
                    authMode: currentProfile.authMode,
                    isCurrent: true
                )
                reusedCurrentAccountIDs.insert(record.id)
            }
            onUpdate(sortedQuotaRecords(recordsByID.values))
        }

        guard request.refreshPolicy != .currentOnly else {
            completeRefresh(
                finalRecords: sortedQuotaRecords(recordsByID.values),
                onUpdate: onUpdate,
                onComplete: onComplete
            )
            return
        }

        let placeholderFetchedAt = Date()
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
                    failureDisposition: nil,
                    fetchedAt: placeholderFetchedAt,
                    authMode: .apiKey,
                    isCurrent: false
                )
                onUpdate(sortedQuotaRecords(recordsByID.values))
            }
        }

        let chatGPTTargets = request.vaultAccounts.compactMap { record -> FetchTarget? in
            guard !reusedCurrentAccountIDs.contains(record.id),
                  record.metadata.authMode != .apiKey,
                  shouldRefreshSavedAccount(
                    record,
                    cachedRecord: recordsByID[record.id],
                    refreshPolicy: request.refreshPolicy,
                    now: now
                  ) else {
                return nil
            }

            return FetchTarget(
                accountID: record.id,
                runtimeMaterial: record.runtimeMaterial,
                authMode: record.metadata.authMode
            )
        }

        let snapshotFetcherBox = snapshotFetcherBox
        var targetIterator = chatGPTTargets.makeIterator()
        await withTaskGroup(of: VaultQuotaSnapshotRecord.self) { group in
            for _ in 0..<min(maxConcurrentChatGPTRefreshes, chatGPTTargets.count) {
                guard let target = targetIterator.next() else {
                    break
                }
                group.addTask {
                    await Self.fetchQuotaSnapshotRecord(
                        for: target,
                        using: snapshotFetcherBox,
                        retryConfiguration: request.refreshPolicy.retryConfiguration
                    )
                }
            }

            while let record = await group.next() {
                recordsByID[record.accountID] = record
                onUpdate(sortedQuotaRecords(recordsByID.values))

                guard let nextTarget = targetIterator.next() else {
                    continue
                }

                group.addTask {
                    await Self.fetchQuotaSnapshotRecord(
                        for: nextTarget,
                        using: snapshotFetcherBox,
                        retryConfiguration: request.refreshPolicy.retryConfiguration
                    )
                }
            }
        }

        completeRefresh(
            finalRecords: sortedQuotaRecords(recordsByID.values),
            onUpdate: onUpdate,
            onComplete: onComplete
        )
    }

    private func completeRefresh(
        finalRecords: [VaultQuotaSnapshotRecord],
        onUpdate: @escaping UpdateHandler,
        onComplete: CompletionHandler?
    ) {
        let hasPresentationOnlyFollowUp = pendingPresentationRefresh.takePendingRefresh()
        activeTask = nil
        activeRequest = nil

        if let pendingRequest {
            onComplete?(finalRecords)
            let nextHandler = pendingHandler ?? onUpdate
            let nextCompletionHandler = pendingCompletionHandler ?? onComplete
            self.pendingRequest = nil
            self.pendingHandler = nil
            self.pendingCompletionHandler = nil
            requestRefresh(
                pendingRequest,
                onUpdate: nextHandler,
                onComplete: nextCompletionHandler
            )
            return
        }

        if hasPresentationOnlyFollowUp {
            let nextHandler = pendingHandler ?? onUpdate
            let nextCompletionHandler = pendingCompletionHandler ?? onComplete
            pendingHandler = nil
            pendingCompletionHandler = nil
            nextHandler(finalRecords)
            nextCompletionHandler?(finalRecords)
            return
        }

        onComplete?(finalRecords)
        pendingHandler = nil
        pendingCompletionHandler = nil
    }

    private func requestScopeKey(_ request: Request) -> String {
        let currentID = request.currentProfile?.id ?? ""
        let accountIDs = request.vaultAccounts.map(\.id).sorted().joined(separator: "|")
        return "\(request.refreshPolicy.requestScopeKey)::\(currentID)::\(accountIDs)"
    }

    nonisolated private static func fetchQuotaSnapshotRecord(
        for target: FetchTarget,
        using snapshotFetcherBox: SnapshotFetcherBox,
        retryConfiguration: RetryConfiguration?
    ) async -> VaultQuotaSnapshotRecord {
        do {
            let snapshot = try await fetchSnapshot(
                for: target.runtimeMaterial,
                using: snapshotFetcherBox,
                retryConfiguration: retryConfiguration
            )
            return VaultQuotaSnapshotRecord(
                accountID: target.accountID,
                snapshot: snapshot,
                healthStatus: .healthy,
                errorSummary: nil,
                failureDisposition: nil,
                fetchedAt: snapshot.fetchedAt,
                authMode: .chatgpt,
                isCurrent: false
            )
        } catch {
            let failureDisposition = classifyQuotaFailureDisposition(from: error)
            return VaultQuotaSnapshotRecord(
                accountID: target.accountID,
                snapshot: nil,
                healthStatus: classifyProfileHealth(from: error),
                errorSummary: userFacingErrorMessage(error),
                failureDisposition: failureDisposition,
                fetchedAt: Date(),
                authMode: target.authMode,
                isCurrent: false
            )
        }
    }

    nonisolated private static func fetchSnapshot(
        for runtimeMaterial: ProfileRuntimeMaterial,
        using snapshotFetcherBox: SnapshotFetcherBox,
        retryConfiguration: RetryConfiguration?
    ) async throws -> CodexSnapshot {
        let initialTimeout = retryConfiguration?.initialTimeout ?? 10

        do {
            return try await snapshotFetcherBox.fetch(runtimeMaterial, initialTimeout)
        } catch {
            guard let retryConfiguration,
                  classifyQuotaFailureDisposition(from: error) == .transient else {
                throw error
            }
            return try await snapshotFetcherBox.fetch(runtimeMaterial, retryConfiguration.retryTimeout)
        }
    }
}

private func shouldRefreshSavedAccount(
    _ record: VaultAccountRecord,
    cachedRecord: VaultQuotaSnapshotRecord?,
    refreshPolicy: VaultQuotaRefreshCoordinator.RefreshPolicy,
    now: Date
) -> Bool {
    switch refreshPolicy {
    case .currentOnly:
        return false
    case .manualFull:
        return true
    case .menuOpenSelective(let staleAfter):
        guard let cachedRecord else {
            return true
        }

        if cachedRecord.healthStatus == .expired {
            return true
        }

        if cachedRecord.healthStatus == .readFailure,
           cachedRecord.failureDisposition == .transient {
            return true
        }

        if now.timeIntervalSince(cachedRecord.fetchedAt) > staleAfter {
            return true
        }

        return false
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

private func quotaOverviewRowRemainingText(label: String, window: RateLimitWindow?) -> String {
    guard let window else {
        return "\(label) -"
    }

    return "\(label) \(window.remainingPercentText)"
}

private func quotaOverviewRowResetText(label: String, window: RateLimitWindow?) -> String {
    guard let window,
          let date = window.resetDate else {
        return "\(label) -"
    }

    let formatter = DateFormatter()
    formatter.locale = AppLocalization.locale
    switch quotaResetDateStyle(for: window) {
    case .time:
        formatter.dateFormat = "HH:mm"
    case .monthDay:
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
    }

    return "\(label) \(formatter.string(from: date))"
}

private func quotaResetScheduleText(for profile: ProviderProfile) -> String {
    let windows = quotaDisplayWindows(for: profile)
    guard !windows.isEmpty else {
        return AppLocalization.quotaUnavailableLabel()
    }

    let texts = windows.map { quotaWindow in
        quotaResetText(
            window: quotaWindow.window,
            label: quotaWindow.label,
            style: quotaResetDateStyle(for: quotaWindow.window)
        )
    }
    return joinedNonEmptyParts(texts.map(Optional.some))
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
