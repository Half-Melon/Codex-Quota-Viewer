import Foundation

enum ProfileRefreshIntent: Equatable {
    case currentOnly
    case menuOpenSelective(refreshCurrentAccount: Bool)
    case manualFull

    var shouldRefreshCurrentAccount: Bool {
        switch self {
        case .currentOnly:
            return true
        case .menuOpenSelective(let refreshCurrentAccount):
            return refreshCurrentAccount
        case .manualFull:
            return true
        }
    }

    func refreshPolicy(
        refreshIntervalPreset: RefreshIntervalPreset
    ) -> VaultQuotaRefreshCoordinator.RefreshPolicy {
        switch self {
        case .currentOnly:
            return .currentOnly
        case .menuOpenSelective:
            return .menuOpenSelective(staleAfter: staleThreshold(for: refreshIntervalPreset))
        case .manualFull:
            return .manualFull
        }
    }

    func merged(with other: Self) -> Self {
        switch (self, other) {
        case (.currentOnly, .currentOnly):
            return .currentOnly
        case (.manualFull, _), (_, .manualFull):
            return .manualFull
        case (.menuOpenSelective(let refreshCurrentAccount), .currentOnly):
            return .menuOpenSelective(refreshCurrentAccount: refreshCurrentAccount)
        case (.currentOnly, .menuOpenSelective(let refreshCurrentAccount)):
            return .menuOpenSelective(refreshCurrentAccount: refreshCurrentAccount)
        case (.menuOpenSelective(let lhs), .menuOpenSelective(let rhs)):
            return .menuOpenSelective(refreshCurrentAccount: lhs || rhs)
        }
    }

    var logLabel: String {
        switch self {
        case .currentOnly:
            return "currentOnly"
        case .menuOpenSelective(let refreshCurrentAccount):
            return "menuOpenSelective(current=\(refreshCurrentAccount))"
        case .manualFull:
            return "manualFull"
        }
    }
}

@MainActor
final class ProfileRefreshController {
    typealias SettingsProvider = () -> AppSettings
    typealias SettingsSaver = (AppSettings, FileDataWriting) throws -> Void
    typealias SettingsApplier = (AppSettings) -> Void
    typealias CurrentProfileBuilder = (
        ProfileRuntimeMaterial?,
        CodexSnapshot?,
        ProfileHealthStatus?,
        String?,
        Date?
    ) -> ProviderProfile?
    typealias LocalizedErrorNoticeBuilder = (
        MenuNoticeKind,
        String,
        String,
        Error
    ) -> MenuNotice
    typealias SafeSwitchNoticePresenter = (MenuNotice, MenuNoticeLifetime) -> Void
    typealias StatusNoticeSetter = (MenuNotice) -> Void
    typealias StateChangeHandler = () -> Void

    private let store: ProfileStore
    private let vaultStore: VaultAccountStore
    private let currentSnapshotFetcher: CurrentSnapshotFetcher
    private let vaultBootstrapCoordinator: VaultBootstrapCoordinator
    private let quotaRefreshCoordinator: VaultQuotaRefreshCoordinator
    private let quotaCacheStore: VaultQuotaCacheStore
    private let settingsProvider: SettingsProvider
    private let saveSettings: SettingsSaver
    private let applySettings: SettingsApplier
    private let currentProfileBuilder: CurrentProfileBuilder
    private let localizedErrorNotice: LocalizedErrorNoticeBuilder
    private let userFacingMessage: (Error) -> String
    private let presentSafeSwitchNotice: SafeSwitchNoticePresenter
    private let setStatusNotice: StatusNoticeSetter
    private let onStateChanged: StateChangeHandler

    private var isFetchingCurrent = false
    private var pendingRefreshIntent: ProfileRefreshIntent?
    private var refreshTimer: Timer?
    private var pendingVaultPresentationRefresh: DispatchWorkItem?

    private(set) var currentRuntimeMaterial: ProfileRuntimeMaterial?
    private(set) var currentSnapshot: CodexSnapshot?
    private(set) var currentHealthStatus: ProfileHealthStatus?
    private(set) var currentError: String?
    private(set) var currentProviderProfile: ProviderProfile?
    private(set) var vaultSnapshot: AccountVaultSnapshot?
    private(set) var vaultQuotaRecords: [String: VaultQuotaSnapshotRecord] = [:]
    private(set) var lastRefreshAt: Date?
    private(set) var refreshProgress: RefreshProgress?

    init(
        store: ProfileStore,
        vaultStore: VaultAccountStore,
        currentSnapshotFetcher: CurrentSnapshotFetcher,
        vaultBootstrapCoordinator: VaultBootstrapCoordinator,
        quotaRefreshCoordinator: VaultQuotaRefreshCoordinator,
        quotaCacheStore: VaultQuotaCacheStore,
        settingsProvider: @escaping SettingsProvider,
        saveSettings: @escaping SettingsSaver,
        applySettings: @escaping SettingsApplier,
        currentProfileBuilder: @escaping CurrentProfileBuilder,
        localizedErrorNotice: @escaping LocalizedErrorNoticeBuilder,
        userFacingMessage: @escaping (Error) -> String,
        presentSafeSwitchNotice: @escaping SafeSwitchNoticePresenter,
        setStatusNotice: @escaping StatusNoticeSetter,
        onStateChanged: @escaping StateChangeHandler
    ) {
        self.store = store
        self.vaultStore = vaultStore
        self.currentSnapshotFetcher = currentSnapshotFetcher
        self.vaultBootstrapCoordinator = vaultBootstrapCoordinator
        self.quotaRefreshCoordinator = quotaRefreshCoordinator
        self.quotaCacheStore = quotaCacheStore
        self.settingsProvider = settingsProvider
        self.saveSettings = saveSettings
        self.applySettings = applySettings
        self.currentProfileBuilder = currentProfileBuilder
        self.localizedErrorNotice = localizedErrorNotice
        self.userFacingMessage = userFacingMessage
        self.presentSafeSwitchNotice = presentSafeSwitchNotice
        self.setStatusNotice = setStatusNotice
        self.onStateChanged = onStateChanged
    }

    var isRefreshing: Bool {
        isFetchingCurrent || quotaRefreshCoordinator.isRefreshing
    }

    func replaceCachedQuotaRecords(_ records: [VaultQuotaSnapshotRecord]) {
        vaultQuotaRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.accountID, $0) })
    }

    func prepareInitialState(currentRuntimeMaterial: ProfileRuntimeMaterial?) {
        self.currentRuntimeMaterial = currentRuntimeMaterial
        currentProviderProfile = currentProfileBuilder(
            currentRuntimeMaterial,
            currentSnapshot,
            currentHealthStatus,
            currentError,
            lastRefreshAt
        )
        refreshVaultProfiles(
            currentRuntimeMaterial: currentRuntimeMaterial,
            scheduleQuotaRefresh: false,
            reloadSnapshot: true
        )
    }

    func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        guard let interval = settingsProvider().refreshIntervalPreset.interval else {
            AppLog.refresh.debug("Refresh timer disabled")
            return
        }

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCurrentProfileOnly()
            }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        AppLog.refresh.debug("Scheduled refresh timer interval=\(interval, privacy: .public)")
    }

    func refreshCurrentProfileOnly() {
        performProfileRefresh(.currentOnly)
    }

    func refreshSavedAccountsOnMenuOpen() {
        performProfileRefresh(
            .menuOpenSelective(
                refreshCurrentAccount: shouldAutoRefreshWhenMenuOpens(settingsProvider().refreshIntervalPreset)
            )
        )
    }

    func refreshAllProfiles() {
        performProfileRefresh(.manualFull)
    }

    private func performProfileRefresh(_ intent: ProfileRefreshIntent) {
        guard !isRefreshing else {
            pendingRefreshIntent = pendingRefreshIntent?.merged(with: intent) ?? intent
            AppLog.refresh.debug("Queued refresh intent=\(intent.logLabel, privacy: .public)")
            return
        }

        isFetchingCurrent = true
        pendingRefreshIntent = nil
        refreshProgress = nil

        if intent.shouldRefreshCurrentAccount {
            currentError = nil
            currentHealthStatus = currentSnapshot == nil ? nil : .healthy
        }
        onStateChanged()
        AppLog.refresh.info("Starting refresh intent=\(intent.logLabel, privacy: .public)")

        Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                self.isFetchingCurrent = false
                if !self.quotaRefreshCoordinator.isRefreshing {
                    self.refreshProgress = nil
                }
                self.onStateChanged()
                AppLog.refresh.info("Finished current-refresh stage intent=\(intent.logLabel, privacy: .public)")
                self.startNextPendingRefreshIfNeeded()
            }

            let currentRuntimeMaterial = try? self.store.currentRuntimeMaterial()
            self.currentRuntimeMaterial = currentRuntimeMaterial

            if intent.shouldRefreshCurrentAccount {
                do {
                    self.currentSnapshot = try await self.currentSnapshotFetcher.fetch(
                        currentRuntimeMaterial: currentRuntimeMaterial,
                        codexHomeURL: self.store.currentAuthURL.deletingLastPathComponent()
                    )
                    self.currentHealthStatus = .healthy
                    self.currentError = nil
                    AppLog.refresh.debug("Fetched current snapshot successfully")
                } catch {
                    self.currentSnapshot = nil
                    self.currentHealthStatus = classifyProfileHealth(from: error)
                    self.currentError = self.userFacingMessage(error)
                    AppLog.refresh.error("Current snapshot refresh failed: \(self.currentError ?? "", privacy: .public)")
                }

                self.lastRefreshAt = Date()
                self.currentProviderProfile = self.currentProfileBuilder(
                    currentRuntimeMaterial,
                    self.currentSnapshot,
                    self.currentHealthStatus,
                    self.currentError,
                    self.lastRefreshAt
                )
                self.bootstrapVaultAccounts(currentRuntimeMaterial: currentRuntimeMaterial)
                self.onStateChanged()
            } else {
                self.currentProviderProfile = self.currentProfileBuilder(
                    currentRuntimeMaterial,
                    self.currentSnapshot,
                    self.currentHealthStatus,
                    self.currentError,
                    self.lastRefreshAt
                )
            }

            self.refreshVaultProfiles(
                currentRuntimeMaterial: currentRuntimeMaterial,
                scheduleQuotaRefresh: true,
                refreshPolicy: intent.refreshPolicy(refreshIntervalPreset: self.settingsProvider().refreshIntervalPreset),
                reloadSnapshot: intent.shouldRefreshCurrentAccount
            )
        }
    }

    private func startNextPendingRefreshIfNeeded() {
        guard !isRefreshing,
              let nextIntent = pendingRefreshIntent else {
            return
        }

        pendingRefreshIntent = nil
        performProfileRefresh(nextIntent)
    }

    private func bootstrapVaultAccounts(currentRuntimeMaterial: ProfileRuntimeMaterial?) {
        do {
            let outcome = try vaultBootstrapCoordinator.bootstrap(
                currentRuntimeMaterial: currentRuntimeMaterial,
                currentSnapshot: currentSnapshot,
                settings: settingsProvider(),
                saveSettings: saveSettings,
                userFacingMessage: userFacingMessage
            )
            applySettings(outcome.settings)
            if let statusNotice = outcome.statusNotice {
                setStatusNotice(statusNotice)
                AppLog.refresh.info("Bootstrap emitted status notice")
            }
            if let safeSwitchNotice = outcome.safeSwitchNotice {
                presentSafeSwitchNotice(
                    safeSwitchNotice,
                    .persistent
                )
                AppLog.refresh.info("Bootstrap emitted safe-switch notice")
            }
        } catch {
            presentSafeSwitchNotice(
                MenuNotice(
                    kind: .error,
                    message: userFacingMessage(error)
                ),
                .persistent
            )
            AppLog.refresh.error("Bootstrap failed: \(self.userFacingMessage(error), privacy: .public)")
        }
    }

    private func refreshVaultProfiles(
        currentRuntimeMaterial: ProfileRuntimeMaterial?,
        scheduleQuotaRefresh: Bool,
        refreshPolicy: VaultQuotaRefreshCoordinator.RefreshPolicy = .manualFull,
        reloadSnapshot: Bool = true
    ) {
        if reloadSnapshot || vaultSnapshot == nil {
            do {
                vaultSnapshot = try vaultStore.loadSnapshot()
            } catch {
                vaultSnapshot = nil
                presentSafeSwitchNotice(
                    localizedErrorNotice(
                        .error,
                        "Failed to read saved accounts",
                        "读取已保存账号失败",
                        error
                    ),
                    .persistent
                )
                AppLog.refresh.error("Failed to load vault snapshot: \(self.userFacingMessage(error), privacy: .public)")
            }
        }

        onStateChanged()

        guard scheduleQuotaRefresh, let vaultSnapshot else {
            return
        }

        quotaRefreshCoordinator.requestRefresh(
            .init(
                currentProfile: currentProviderProfile,
                vaultAccounts: vaultSnapshot.accounts,
                cachedRecords: Array(vaultQuotaRecords.values),
                refreshPolicy: refreshPolicy
            ),
            onProgress: { [weak self] progress in
                guard let self else { return }
                self.refreshProgress = progress
                self.onStateChanged()
                AppLog.refresh.debug(
                    "Quota refresh progress \(progress.completedCount, privacy: .public)/\(progress.totalCount, privacy: .public)"
                )
            },
            onUpdate: { [weak self] records in
                guard let self else { return }
                self.applyQuotaRefreshRecords(records)
                self.scheduleVaultPresentationRefresh()
            },
            onComplete: { [weak self] records in
                guard let self else { return }
                self.applyQuotaRefreshRecords(records)
                do {
                    try self.quotaCacheStore.save(records)
                } catch {
                    self.setStatusNotice(
                        self.localizedErrorNotice(
                            .warning,
                            "Quota cache could not be updated",
                            "额度缓存无法更新",
                            error
                        )
                    )
                    AppLog.refresh.error("Failed to save quota cache: \(self.userFacingMessage(error), privacy: .public)")
                }
                self.refreshProgress = nil
                self.scheduleVaultPresentationRefresh(delay: 0)
                self.startNextPendingRefreshIfNeeded()
            }
        )
    }

    private func applyQuotaRefreshRecords(_ records: [VaultQuotaSnapshotRecord]) {
        vaultQuotaRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.accountID, $0) })
    }

    private func scheduleVaultPresentationRefresh(delay: TimeInterval = 0.3) {
        pendingVaultPresentationRefresh?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingVaultPresentationRefresh = nil
            self?.onStateChanged()
        }
        pendingVaultPresentationRefresh = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
