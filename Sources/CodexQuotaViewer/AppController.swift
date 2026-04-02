import AppKit
import Foundation

private enum UsageDateStyle {
    case time
    case monthDay
}

enum MenuNoticeKind: Equatable {
    case info
    case warning
    case error
}

struct MenuNotice: Equatable {
    let kind: MenuNoticeKind
    let message: String
}

enum ProfileIndicatorKind: Equatable {
    case error
    case neutral
    case apiKey
    case limited
    case healthy
}

func userFacingErrorMessage(_ error: Error) -> String {
    if let localized = error as? LocalizedError,
       let description = localized.errorDescription {
        return description
    }
    return error.localizedDescription
}

func shouldAutoRefreshWhenMenuOpens(_ refreshIntervalPreset: RefreshIntervalPreset) -> Bool {
    refreshIntervalPreset.interval != nil
}

func staleThreshold(for refreshIntervalPreset: RefreshIntervalPreset) -> TimeInterval {
    if let interval = refreshIntervalPreset.interval {
        return interval * 1.5
    }

    return 30 * 60
}

func isSnapshotDataStale(
    lastRefreshAt: Date?,
    refreshIntervalPreset: RefreshIntervalPreset,
    now: Date = Date()
) -> Bool {
    guard let lastRefreshAt else {
        return false
    }

    return now.timeIntervalSince(lastRefreshAt) > staleThreshold(for: refreshIntervalPreset)
}

func resolveProfileIndicatorKind(
    snapshot: CodexSnapshot?,
    health: ProfileHealthStatus
) -> ProfileIndicatorKind {
    guard health.isHealthy else {
        return .error
    }

    guard let snapshot else {
        return .neutral
    }

    if snapshot.account.type == "apiKey" {
        return .apiKey
    }

    let windows = quotaDisplayWindows(from: snapshot)
    guard !windows.isEmpty else {
        return .neutral
    }

    if windows.contains(where: { $0.window.remainingPercent <= 0 }) {
        return .limited
    }

    return .healthy
}

@MainActor
final class AppController: NSObject, NSMenuDelegate {
    private let store = ProfileStore()
    private lazy var vaultStore = VaultAccountStore(
        accountsRootURL: store.accountsRootURL,
        indexURL: store.accountsIndexURL
    )
    private let rpcClient = CodexRPCClient()
    private let launchAtLoginManager = LaunchAtLoginManager()
    private let statusItemRenderer = StatusItemRenderer()
    private let desktopController = CodexDesktopController()
    private let threadSyncInspector = LocalThreadSyncInspector()
    private let statusEvaluator = StatusEvaluator()
    private let apiAccountPromptController = APIAccountPromptController()
    private lazy var currentSnapshotFetcher = CurrentSnapshotFetcher(
        fetchFromRuntimeMaterial: { [rpcClient] runtimeMaterial in
            try await rpcClient.fetchSnapshot(
                authData: runtimeMaterial.authData,
                configData: runtimeMaterial.configData
            )
        },
        fetchFromCodexHome: { [rpcClient] codexHomeURL in
            try await rpcClient.fetchSnapshot(codexHomeURL: codexHomeURL)
        }
    )
    private lazy var quotaCacheStore = VaultQuotaCacheStore(cacheURL: store.quotaCacheURL)
    private lazy var backupManager = BackupManager(
        backupsRootURL: store.baseURL.appendingPathComponent("SwitchBackups", isDirectory: true)
    )
    private lazy var repairClient = SessionManagerRepairClient(launcher: sessionManagerLauncher)
    private lazy var switchOrchestrator = SwitchOrchestrator(
        store: store,
        backupManager: backupManager,
        rolloutSynchronizer: RolloutProviderSynchronizer(),
        repairClient: repairClient,
        desktopController: desktopController
    )
    private lazy var rollbackManager = RollbackManager(
        backupManager: backupManager,
        desktopController: desktopController
    )
    private lazy var accountOnboardingCoordinator = AccountOnboardingCoordinator(
        vaultStore: vaultStore,
        backupManager: backupManager,
        protectedFilesProvider: { [weak self] accountIDs in
            guard let self else { return [] }
            return try self.protectedMutationFileURLs(forAccountIDs: accountIDs)
        }
    )
    private lazy var currentRuntimeCaptureCoordinator = CurrentRuntimeCaptureCoordinator(
        vaultStore: vaultStore,
        backupManager: backupManager,
        protectedFilesProvider: { [weak self] accountIDs in
            guard let self else { return [] }
            return try self.protectedMutationFileURLs(forAccountIDs: accountIDs)
        }
    )
    private lazy var vaultBootstrapCoordinator = VaultBootstrapCoordinator(
        vaultStore: vaultStore,
        backupManager: backupManager,
        currentRuntimeCaptureCoordinator: currentRuntimeCaptureCoordinator,
        protectedFilesProvider: { [weak self] accountIDs in
            guard let self else { return [] }
            return try self.protectedMutationFileURLs(forAccountIDs: accountIDs)
        }
    )
    private lazy var quotaRefreshCoordinator = VaultQuotaRefreshCoordinator(
        snapshotFetcher: { [rpcClient] runtimeMaterial in
            try await rpcClient.fetchSnapshot(
                authData: runtimeMaterial.authData,
                configData: runtimeMaterial.configData
            )
        }
    )
    private lazy var sessionManagerLauncher = SessionManagerLauncher(
        uiConfigURL: store.sessionManagerUIConfigURL,
        defaultLanguageProvider: { [weak self] in
            guard let self else { return nil }
            return self.store.loadSessionManagerUIConfig()?.language ?? self.settings.lastResolvedLanguage
        }
    )
    private lazy var sessionManagerCoordinator = SessionManagerCoordinator(
        store: store,
        launcher: sessionManagerLauncher
    )

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var settings = AppSettings()
    private var currentSnapshot: CodexSnapshot?
    private var currentHealthStatus: ProfileHealthStatus?
    private var currentError: String?
    private var currentProviderProfile: ProviderProfile?
    private var vaultSnapshot: AccountVaultSnapshot?
    private var vaultProfiles: [ProviderProfile] = []
    private var availableSwitchTargets: [ProviderProfile] = []
    private var quotaOverviewState: QuotaOverviewState?
    private var vaultQuotaRecords: [String: VaultQuotaSnapshotRecord] = [:]
    private var safeSwitchCenterState: SafeSwitchCenterState?
    private var statusNotice: MenuNotice?
    private var loadWarningNotice: String?
    private var sessionManagerNotice: MenuNoticeEntry?
    private var safeSwitchNotice: MenuNoticeEntry?
    private var localizationNotice: MenuNotice?
    private var refreshState = RefreshRequestState()
    private var isLaunchingSessionManager = false
    private var foregroundOperationState = ForegroundOperationState()
    private var lastRefreshAt: Date?
    private var refreshTimer: Timer?
    private let settingsPresenter = SettingsPresenter()
    private var menuTrackingGate = MenuTrackingGate()
    private var pendingMenuRefreshReason: String?
    private var deferredMenuPresentations = DeferredMenuPresentationQueue()
    private var foregroundPresentationDepth = 0
    private var pendingVaultPresentationRefresh: DispatchWorkItem?
    private var pendingNoticeExpiryRefresh: DispatchWorkItem?

    func start() {
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.title = "CX"

        loadReadOnlyState()
        synchronizeLocalizationState()
        let currentRuntimeMaterial = try? store.currentRuntimeMaterial()
        currentProviderProfile = makeCurrentProviderProfile(currentRuntimeMaterial: currentRuntimeMaterial)
        refreshVaultProfiles(currentRuntimeMaterial: currentRuntimeMaterial, scheduleQuotaRefresh: false)
        applySettingsSideEffects(showErrorsInStatus: false)
        rebuildMenu()
        refreshAllProfiles()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuTrackingGate.beginTracking()
        guard shouldAutoRefreshWhenMenuOpens(settings.refreshIntervalPreset) else {
            return
        }
        refreshAllProfiles()
    }

    func menuDidClose(_ menu: NSMenu) {
        let shouldRebuild = menuTrackingGate.finishTracking()
        let deferredPresentations = deferredMenuPresentations.drain()

        if shouldRebuild {
            pendingMenuRefreshReason = nil
            rebuildMenu(force: true)
        } else {
            pendingMenuRefreshReason = nil
        }

        for presentation in deferredPresentations {
            switch presentation {
            case .settings:
                presentSettingsWindow()
            }
        }
    }

    private func loadReadOnlyState() {
        let settingsResult = store.loadSettingsResult()
        settings = settingsResult.settings
        var issues = settingsResult.issues.map(\.message)
        do {
            let cachedRecords = try quotaCacheStore.load()
            vaultQuotaRecords = Dictionary(uniqueKeysWithValues: cachedRecords.map { ($0.accountID, $0) })
        } catch {
            vaultQuotaRecords = [:]
            issues.append(
                AppLocalization.localized(
                    en: "Quota cache is corrupted: \(store.quotaCacheURL.lastPathComponent)",
                    zh: "额度缓存已损坏：\(store.quotaCacheURL.lastPathComponent)"
                )
            )
        }
        loadWarningNotice = issues.isEmpty ? nil : issues.joined(separator: "; ")
        statusNotice = nil
        localizationNotice = nil
    }

    private func applySettingsSideEffects(showErrorsInStatus: Bool) {
        synchronizeLocalizationState()
        scheduleRefreshTimer()
        do {
            try launchAtLoginManager.sync(enabled: settings.launchAtLoginEnabled)
        } catch {
            if showErrorsInStatus {
                statusNotice = MenuNotice(kind: .error, message: userFacingMessage(for: error))
            }
        }
        refreshSettingsUI()
    }

    private func synchronizeLocalizationState() {
        let result = sessionManagerCoordinator.synchronizeLocalizationState(settings: settings)
        settings = result.settings
        localizationNotice = result.notice
    }

    private func refreshSettingsUI() {
        installApplicationMainMenu(app: NSApp)
        settingsPresenter.update(
            settings: settings,
            accountPanelState: buildSettingsAccountPanelState(
                vaultSnapshot: vaultSnapshot,
                vaultProfiles: vaultProfiles,
                currentProviderProfile: currentProviderProfile,
                refreshIntervalPreset: settings.refreshIntervalPreset,
                actionsEnabled: !isPerformingSafeSwitchOperation
            )
        )
        updateStatusTitle()
        rebuildMenu(reason: "settings-ui")
    }

    private func refreshSettingsAccountPanel() {
        settingsPresenter.update(
            settings: settings,
            accountPanelState: buildSettingsAccountPanelState(
                vaultSnapshot: vaultSnapshot,
                vaultProfiles: vaultProfiles,
                currentProviderProfile: currentProviderProfile,
                refreshIntervalPreset: settings.refreshIntervalPreset,
                actionsEnabled: !isPerformingSafeSwitchOperation
            )
        )
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        guard let interval = settings.refreshIntervalPreset.interval else {
            return
        }

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAllProfiles()
            }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshAllProfiles() {
        guard refreshState.begin() else { return }

        currentError = nil
        currentHealthStatus = currentSnapshot == nil ? nil : .healthy
        updateStatusTitle()
        rebuildMenu(reason: "refresh-begin")

        Task {
            defer {
                let shouldRefreshAgain = refreshState.finish()
                updateStatusTitle()
                rebuildMenu(reason: "refresh-end")
                if shouldRefreshAgain {
                    refreshAllProfiles()
                }
            }

            let currentRuntimeMaterial = try? store.currentRuntimeMaterial()

            do {
                currentSnapshot = try await currentSnapshotFetcher.fetch(
                    currentRuntimeMaterial: currentRuntimeMaterial,
                    codexHomeURL: store.currentAuthURL.deletingLastPathComponent()
                )
                currentHealthStatus = .healthy
            } catch {
                currentSnapshot = nil
                currentHealthStatus = classifyProfileHealth(from: error)
                currentError = userFacingMessage(for: error)
            }

            lastRefreshAt = Date()
            currentProviderProfile = makeCurrentProviderProfile(currentRuntimeMaterial: currentRuntimeMaterial)
            bootstrapVaultAccounts(currentRuntimeMaterial: currentRuntimeMaterial)
            updateStatusTitle()
            rebuildMenu(reason: "refresh-current")

            refreshVaultProfiles(currentRuntimeMaterial: currentRuntimeMaterial, scheduleQuotaRefresh: true)
        }
    }

    private func rebuildMenu(force: Bool = false, reason: String? = nil) {
        if !force && !menuTrackingGate.requestRebuild() {
            if pendingMenuRefreshReason == nil {
                pendingMenuRefreshReason = reason
            }
            return
        }

        pendingMenuRefreshReason = nil
        menu.removeAllItems()

        if let notice = visibleMenuNotice() {
            addNoticeItem(notice)
            menu.addItem(.separator())
        }

        addQuotaOverviewSection()

        menu.addItem(.separator())
        let maintenanceItem = NSMenuItem(
            title: AppLocalization.localized(en: "Maintenance", zh: "维护"),
            action: nil,
            keyEquivalent: ""
        )
        maintenanceItem.submenu = makeMaintenanceMenu()
        menu.addItem(maintenanceItem)

        addActionItem(
            title: AppLocalization.localized(en: "Settings…", zh: "设置…"),
            action: #selector(openSettingsTapped),
            enabled: true
        )
        addActionItem(
            title: AppLocalization.localized(en: "Quit", zh: "退出"),
            action: #selector(quitTapped),
            enabled: true
        )
    }

    private func visibleMenuNotice() -> MenuNotice? {
        CodexQuotaViewer.visibleMenuNotice(
            safeSwitchNotice: safeSwitchNotice,
            isForegroundOperationActive: isPerformingSafeSwitchOperation,
            sessionManagerNotice: sessionManagerNotice,
            isLaunchingSessionManager: isLaunchingSessionManager,
            localizationNotice: localizationNotice,
            statusNotice: statusNotice,
            currentError: currentError,
            loadWarningNotice: loadWarningNotice
        )
    }

    private var isRefreshing: Bool {
        refreshState.isRefreshing
    }

    private var isPerformingSafeSwitchOperation: Bool {
        foregroundOperationState.isBusy
    }

    private func presentSafeSwitchNotice(
        _ notice: MenuNotice,
        lifetime: MenuNoticeLifetime,
        now: Date = Date()
    ) {
        safeSwitchNotice = makeMenuNoticeEntry(notice, lifetime: lifetime, now: now)
    }

    private func presentSessionManagerNotice(
        _ notice: MenuNotice,
        lifetime: MenuNoticeLifetime,
        now: Date = Date()
    ) {
        sessionManagerNotice = makeMenuNoticeEntry(notice, lifetime: lifetime, now: now)
    }

    private func makeMenuNoticeEntry(
        _ notice: MenuNotice,
        lifetime: MenuNoticeLifetime,
        now: Date
    ) -> MenuNoticeEntry {
        let entry: MenuNoticeEntry
        switch lifetime {
        case .operationBound:
            entry = .operationBound(notice)
        case .timed(let duration):
            entry = .timed(notice, now: now, duration: duration)
        case .persistent:
            entry = .persistent(notice)
        }

        scheduleNoticeExpiryRefreshIfNeeded(for: entry, now: now)
        return entry
    }

    private func scheduleNoticeExpiryRefreshIfNeeded(
        for entry: MenuNoticeEntry,
        now: Date
    ) {
        pendingNoticeExpiryRefresh?.cancel()
        pendingNoticeExpiryRefresh = nil

        guard let expiresAt = entry.expiresAt else {
            return
        }

        let delay = max(0, expiresAt.timeIntervalSince(now))
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingNoticeExpiryRefresh = nil
            self?.rebuildMenu(reason: "notice-expired")
        }
        pendingNoticeExpiryRefresh = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func beginForegroundOperation(_ operation: ForegroundOperation) -> Bool {
        foregroundOperationState.begin(operation)
    }

    private func beginOrHandoffChatGPTOperation(useDeviceAuth: Bool) -> Bool {
        if useDeviceAuth {
            if foregroundOperationState.activeOperation == .chatGPTBrowserLogin {
                foregroundOperationState.handoff(to: .chatGPTDeviceLogin)
                return true
            }
            return foregroundOperationState.begin(.chatGPTDeviceLogin)
        }

        return foregroundOperationState.begin(.chatGPTBrowserLogin)
    }

    private func endForegroundOperation(_ operation: ForegroundOperation) {
        foregroundOperationState.end(operation)
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }

        switch settings.statusItemStyle {
        case .text:
            button.image = statusItemRenderer.makeBrandImage(for: button.effectiveAppearance)
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleNone

            let title: String
            if let currentSnapshot {
                title = currentStatusSummary(for: currentSnapshot)
            } else if isRefreshing {
                title = AppLocalization.localized(en: "Refreshing", zh: "刷新中")
            } else if currentError != nil {
                title = AppLocalization.localized(en: "Read failed", zh: "读取失败")
            } else {
                title = AppLocalization.statusPlaceholderSummary()
            }

            statusItem.length = NSStatusItem.variableLength
            button.title = title

        case .meter:
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyUpOrDown
            statusItem.length = NSStatusItem.squareLength

            if currentSnapshot?.account.type == "apiKey" {
                button.image = statusItemRenderer.makeBrandImage(for: button.effectiveAppearance)
            } else {
                let windows = quotaDisplayWindows(from: currentSnapshot)
                let primaryRemaining = windows.first?.window.remainingPercent ?? 0
                let secondaryRemaining = windows.dropFirst().first?.window.remainingPercent ?? 0
                button.image = statusItemRenderer.makeMeterImage(
                    primaryRemaining: primaryRemaining / 100,
                    secondaryRemaining: secondaryRemaining / 100,
                    state: currentMeterIconState()
                )
            }
        }
    }

    private func currentMeterIconState() -> MeterIconState {
        if currentError != nil {
            return .degraded
        }

        if isDataStale {
            return .stale
        }

        return .normal
    }

    private var isDataStale: Bool {
        isSnapshotDataStale(
            lastRefreshAt: lastRefreshAt,
            refreshIntervalPreset: settings.refreshIntervalPreset
        )
    }

    private func addDisabledItem(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addNoticeItem(_ notice: MenuNotice) {
        addDisabledItem(notice.message)
    }

    private func addActionItem(title: String, action: Selector, enabled: Bool) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    private func addQuotaOverviewSection() {
        if let quotaOverviewState,
           !quotaOverviewState.boardTiles.isEmpty {
            for tile in quotaOverviewState.boardTiles {
                menu.addItem(makeQuotaOverviewRowItem(for: tile))
            }
        } else {
            addDisabledItem(AppLocalization.localized(en: "No saved accounts", zh: "暂无已保存账号"))
        }

        let allAccountsItem = NSMenuItem(
            title: AppLocalization.localized(en: "All Accounts", zh: "全部账号"),
            action: nil,
            keyEquivalent: ""
        )
        allAccountsItem.submenu = makeAllAccountsMenu()
        menu.addItem(allAccountsItem)
    }

    private func makeQuotaOverviewRowItem(for tile: QuotaTileViewModel) -> NSMenuItem {
        let item = NSMenuItem(
            title: tile.profile.displayName,
            action: tile.profile.isCurrent ? nil : #selector(activateSavedAccountTapped(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = tile.profile.id
        item.isEnabled = !tile.profile.isCurrent && !isPerformingSafeSwitchOperation
        item.view = AccountMenuRowView(
            model: AccountMenuRowModel(
                name: tile.profile.displayName,
                primaryUsageText: tile.primaryText,
                secondaryUsageText: tile.secondaryText,
                indicatorColor: quotaOverviewIndicatorColor(for: tile.state),
                isCurrent: tile.profile.isCurrent,
                isEnabled: !tile.profile.isCurrent && !isPerformingSafeSwitchOperation
            )
        )
        return item
    }

    private func quotaOverviewIndicatorColor(for state: QuotaTileState) -> NSColor {
        switch state {
        case .healthy:
            return .systemGreen
        case .lowQuota:
            return .systemYellow
        case .stale:
            return .systemOrange
        case .signInRequired, .expired, .readFailure:
            return .systemRed
        }
    }

    private func makeAllAccountsMenu() -> NSMenu {
        let submenu = NSMenu()

        guard let quotaOverviewState,
              !quotaOverviewState.sections.isEmpty else {
            let emptyItem = NSMenuItem(
                title: AppLocalization.localized(en: "No saved accounts", zh: "暂无已保存账号"),
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
            return submenu
        }

        for (sectionIndex, section) in quotaOverviewState.sections.enumerated() {
            let header = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            submenu.addItem(header)

            for profile in section.profiles {
                let presentation = buildAllAccountsMenuItemPresentation(
                    for: profile,
                    refreshIntervalPreset: settings.refreshIntervalPreset,
                    isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation
                )
                let item = NSMenuItem(
                    title: presentation.title,
                    action: presentation.triggersDirectSwitch ? #selector(activateSavedAccountTapped(_:)) : nil,
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = profile.id
                item.state = presentation.showsCheckmark ? .on : .off
                item.isEnabled = presentation.isEnabled
                submenu.addItem(item)
            }

            if sectionIndex < quotaOverviewState.sections.count - 1 {
                submenu.addItem(.separator())
            }
        }

        return submenu
    }

    private func makeMaintenanceMenu() -> NSMenu {
        let submenu = NSMenu()

        let refreshItem = NSMenuItem(
            title: isRefreshing
                ? AppLocalization.localized(en: "Refreshing…", zh: "刷新中…")
                : AppLocalization.localized(en: "Refresh All", zh: "全部刷新"),
            action: #selector(refreshTapped),
            keyEquivalent: ""
        )
        refreshItem.target = self
        refreshItem.isEnabled = !isRefreshing && !isPerformingSafeSwitchOperation
        submenu.addItem(refreshItem)

        let sessionManagerItem = NSMenuItem(
            title: isLaunchingSessionManager
                ? AppLocalization.localized(en: "Opening Session Manager…", zh: "正在打开 Session Manager…")
                : AppLocalization.localized(en: "Open Session Manager", zh: "打开 Session Manager"),
            action: #selector(manageSessionsTapped),
            keyEquivalent: ""
        )
        sessionManagerItem.target = self
        sessionManagerItem.isEnabled = !isLaunchingSessionManager && !isPerformingSafeSwitchOperation
        submenu.addItem(sessionManagerItem)

        submenu.addItem(.separator())

        let repairItem = NSMenuItem(
            title: AppLocalization.localized(en: "Repair Now", zh: "立即修复"),
            action: #selector(repairNowTapped),
            keyEquivalent: ""
        )
        repairItem.target = self
        repairItem.isEnabled = !isPerformingSafeSwitchOperation
        submenu.addItem(repairItem)

        let rollbackItem = NSMenuItem(
            title: AppLocalization.localized(en: "Rollback Last Change", zh: "回滚上次变更"),
            action: #selector(rollbackLastChangeTapped),
            keyEquivalent: ""
        )
        rollbackItem.target = self
        rollbackItem.isEnabled = !isPerformingSafeSwitchOperation && safeSwitchCenterState?.latestRestorePoint != nil
        submenu.addItem(rollbackItem)

        return submenu
    }

    private func accountUsageSummary(
        window: RateLimitWindow?,
        label: String,
        dateStyle: UsageDateStyle
    ) -> String {
        guard let window else { return "\(label) -  -" }
        let resetText = formatUsageResetDate(window.resetDate, style: dateStyle)
        return "\(label) \(window.remainingPercentText)  \(resetText)"
    }

    private func quotaUsageSummaryLines(for snapshot: CodexSnapshot) -> [String] {
        quotaDisplayWindows(from: snapshot).map { quotaWindow in
            let dateStyle: UsageDateStyle
            if let duration = quotaWindow.window.windowDurationMins,
               duration >= 1_440 {
                dateStyle = .monthDay
            } else {
                dateStyle = .time
            }

            return accountUsageSummary(
                window: quotaWindow.window,
                label: quotaWindow.label,
                dateStyle: dateStyle
            )
        }
    }

    private func condensedProfileErrorText(
        message: String?,
        fallback: String
    ) -> String {
        guard let message else { return fallback }
        let lowered = message.lowercased()

        if lowered.contains("unauthorized") || lowered.contains("sign in") || lowered.contains("not signed in") {
            return AppLocalization.localized(en: "Sign in required", zh: "需要登录")
        }
        if lowered.contains("expired") {
            return AppLocalization.localized(en: "Session expired", zh: "会话已过期")
        }
        if lowered.contains("timeout") || lowered.contains("timed out") {
            return AppLocalization.localized(en: "Request timed out", zh: "请求超时")
        }
        return fallback
    }

    private func indicatorColor(
        snapshot: CodexSnapshot?,
        health: ProfileHealthStatus
    ) -> NSColor {
        switch resolveProfileIndicatorKind(snapshot: snapshot, health: health) {
        case .error:
            return .systemRed
        case .neutral:
            return .secondaryLabelColor
        case .apiKey:
            return .systemBlue
        case .limited:
            return .systemYellow
        case .healthy:
            return .systemGreen
        }
    }

    private func makeCurrentProviderProfile(
        currentRuntimeMaterial: ProfileRuntimeMaterial?
    ) -> ProviderProfile? {
        guard let currentRuntimeMaterial else {
            return nil
        }

        let matchingVaultRecord = matchingVaultRecord(for: currentRuntimeMaterial)
        let fallbackName = currentSnapshot?.account.displayLabel
            ?? matchingVaultRecord?.metadata.displayName
            ?? AppLocalization.currentAccountFallbackName()

        return buildProviderProfile(
            id: matchingVaultRecord?.id ?? stableAccountRecordID(for: currentRuntimeMaterial),
            fallbackDisplayName: fallbackName,
            source: .current,
            runtimeMaterial: currentRuntimeMaterial,
            snapshot: currentSnapshot,
            healthStatus: currentHealthStatus ?? (currentError == nil ? .healthy : .readFailure),
            errorMessage: currentError,
            isCurrent: true,
            quotaFetchedAt: currentSnapshot?.fetchedAt ?? lastRefreshAt
        )
    }

    private func refreshSafeSwitchCenterState() {
        let latestRestorePoint = try? backupManager.latestRestorePoint()
        let threadSyncStatus = threadSyncInspector.inspect(
            store: store,
            expectedProviderID: currentExpectedProviderID
        )
        safeSwitchCenterState = statusEvaluator.currentState(
            currentProfile: currentProviderProfile,
            availableTargets: availableSwitchTargets,
            codexIsRunning: desktopController.isRunning,
            localThreadSyncStatus: threadSyncStatus,
            latestRestorePoint: latestRestorePoint
        )
    }

    private var currentExpectedProviderID: String? {
        if let providerID = currentProviderProfile?.threadProviderID,
           !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return providerID
        }

        if currentProviderProfile?.authMode == .chatgpt {
            return "openai"
        }

        return nil
    }

    private func confirmSafeSwitch(
        targetProfile: ProviderProfile,
        preview: SwitchOperationPreview
    ) -> Bool {
        runForegroundModalPresentation {
            let alert = NSAlert()
            alert.messageText = AppLocalization.localized(
                en: "Switch safely to \(targetProfile.displayName)?",
                zh: "要安全切换到 \(targetProfile.displayName) 吗？"
            )
            alert.informativeText = [
                AppLocalization.localized(
                    en: "Current: \(currentProviderProfile?.displayName ?? AppLocalization.currentAccountFallbackName())",
                    zh: "当前：\(currentProviderProfile?.displayName ?? AppLocalization.currentAccountFallbackName())"
                ),
                AppLocalization.localized(en: "Target: \(targetProfile.displayName)", zh: "目标：\(targetProfile.displayName)"),
                AppLocalization.localized(en: "Provider: \(targetProfile.providerLabel)", zh: "Provider：\(targetProfile.providerLabel)"),
                AppLocalization.localized(en: "Files to back up: \(preview.filesToBackup.count)", zh: "需备份文件：\(preview.filesToBackup.count)"),
                AppLocalization.localized(en: "Rollouts to update: \(preview.rolloutFilesToUpdate.count)", zh: "需更新 rollout：\(preview.rolloutFilesToUpdate.count)"),
                preview.codexWasRunning
                    ? AppLocalization.localized(en: "Codex will be closed and reopened automatically.", zh: "Codex 会自动关闭并重新打开。")
                    : AppLocalization.localized(en: "Codex is not running, so no reopen is needed.", zh: "Codex 当前未运行，无需重新打开。"),
            ].joined(separator: "\n")
            alert.addButton(withTitle: AppLocalization.localized(en: "Switch Safely", zh: "安全切换"))
            alert.addButton(withTitle: AppLocalization.localized(en: "Cancel", zh: "取消"))
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    private func confirmRollback(restorePoint: RestorePointManifest) -> Bool {
        runForegroundModalPresentation {
            let alert = NSAlert()
            alert.messageText = AppLocalization.localized(en: "Rollback the latest safe switch?", zh: "要回滚最近一次安全切换吗？")
            alert.informativeText = [
                AppLocalization.localized(en: "Restore point: \(restorePoint.id)", zh: "还原点：\(restorePoint.id)"),
                AppLocalization.localized(en: "Summary: \(restorePoint.summary)", zh: "摘要：\(restorePoint.summary)"),
                AppLocalization.localized(en: "Files: \(restorePoint.files.count)", zh: "文件数：\(restorePoint.files.count)"),
                restorePoint.codexWasRunning
                    ? AppLocalization.localized(en: "Codex will be closed and reopened automatically.", zh: "Codex 会自动关闭并重新打开。")
                    : AppLocalization.localized(en: "Codex was not running when this backup was created.", zh: "创建这份备份时 Codex 并未运行。"),
            ].joined(separator: "\n")
            alert.addButton(withTitle: AppLocalization.localized(en: "Rollback", zh: "回滚"))
            alert.addButton(withTitle: AppLocalization.localized(en: "Cancel", zh: "取消"))
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    @objc
    private func refreshTapped() {
        refreshAllProfiles()
    }

    @objc
    private func activateSavedAccountTapped(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else {
            return
        }
        activateSavedAccount(identifier: identifier)
    }

    private func activateSavedAccount(identifier: String) {
        guard let targetProfile = availableSwitchTargets.first(where: { $0.id == identifier }) else {
            return
        }
        switchSafely(to: targetProfile)
    }

    @objc
    private func addChatGPTAccountTapped() {
        startChatGPTAccountFlow(useDeviceAuth: false)
    }

    @objc
    private func addAPIAccountTapped() {
        guard !isPerformingSafeSwitchOperation,
              let fields = apiAccountPromptController.prompt(
                runModalPresentation: { [weak self] body in
                    guard let self else { return nil }
                    return self.runForegroundModalPresentation(body)
                },
                userFacingMessage: { [weak self] error in
                    self?.userFacingMessage(for: error) ?? error.localizedDescription
                }
              ),
              beginForegroundOperation(.apiOnboarding) else {
            return
        }

        presentSafeSwitchNotice(
            MenuNotice(
                kind: .info,
                message: AppLocalization.localized(en: "Detecting API settings…", zh: "正在探测 API 配置…")
            ),
            lifetime: .operationBound
        )
        rebuildMenu(reason: "api-detect-start")

        Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                self.endForegroundOperation(.apiOnboarding)
                self.refreshAllProfiles()
            }

            do {
                let result = try await self.accountOnboardingCoordinator.addAPIAccount(
                    apiKey: fields.apiKey,
                    rawBaseURL: fields.baseURL,
                    overrideDisplayName: fields.displayName,
                    overrideModel: fields.model
                )
                let suffix = result.warningMessage.map { " \($0)" } ?? ""
                self.presentSafeSwitchNotice(
                    MenuNotice(
                        kind: result.warningMessage == nil ? .info : .warning,
                        message: AppLocalization.localized(
                            en: "Added \(result.record.metadata.displayName). Restore point \(result.restorePoint.id) is ready.\(suffix)",
                            zh: "已添加 \(result.record.metadata.displayName)。还原点 \(result.restorePoint.id) 已创建。\(suffix)"
                        )
                    ),
                    lifetime: result.warningMessage == nil ? .timed(4) : .persistent
                )
            } catch {
                self.presentSafeSwitchNotice(
                    MenuNotice(
                        kind: .error,
                        message: AppLocalization.localized(
                            en: "Add API account failed: \(self.userFacingMessage(for: error))",
                            zh: "添加 API 账号失败：\(self.userFacingMessage(for: error))"
                        )
                    ),
                    lifetime: .persistent
                )
            }
        }
    }

    @objc
    private func renameSavedAccountTapped(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else {
            return
        }
        renameSavedAccount(identifier: identifier)
    }

    private func renameSavedAccount(identifier: String) {
        guard let record = vaultSnapshot?.accounts.first(where: { $0.id == identifier }),
              let updatedName = promptForText(
                title: AppLocalization.localized(en: "Rename Account", zh: "重命名账号"),
                message: AppLocalization.localized(
                    en: "Update the saved display name for \(record.metadata.displayName).",
                    zh: "修改 \(record.metadata.displayName) 的保存显示名。"
                ),
                defaultValue: record.metadata.displayName
              ) else {
            return
        }

        do {
            let restorePoint = try backupManager.createRestorePoint(
                reason: "rename-account",
                summary: "Rename account \(record.metadata.displayName)",
                files: try protectedMutationFileURLs(forAccountIDs: [identifier]),
                codexWasRunning: false
            )
            let writer = ProtectedFileMutationContext(restorePoint: restorePoint)
            _ = try vaultStore.renameAccount(id: identifier, newDisplayName: updatedName, writer: writer)
            presentSafeSwitchNotice(
                MenuNotice(
                    kind: .info,
                    message: AppLocalization.localized(
                        en: "Renamed account to \(updatedName). Restore point \(restorePoint.id) is ready.",
                        zh: "账号已重命名为 \(updatedName)。还原点 \(restorePoint.id) 已创建。"
                    )
                ),
                lifetime: .timed(4)
            )
        } catch {
            presentSafeSwitchNotice(
                MenuNotice(
                    kind: .error,
                    message: AppLocalization.localized(
                        en: "Rename failed: \(userFacingMessage(for: error))",
                        zh: "重命名失败：\(userFacingMessage(for: error))"
                    )
                ),
                lifetime: .persistent
            )
        }

        refreshAllProfiles()
    }

    @objc
    private func forgetSavedAccountTapped(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else {
            return
        }
        forgetSavedAccount(identifier: identifier)
    }

    private func forgetSavedAccount(identifier: String) {
        guard let record = vaultSnapshot?.accounts.first(where: { $0.id == identifier }),
              confirmForgetAccount(record: record) else {
            return
        }

        do {
            let restorePoint = try backupManager.createRestorePoint(
                reason: "forget-account",
                summary: "Forget account \(record.metadata.displayName)",
                files: try protectedMutationFileURLs(forAccountIDs: [identifier]),
                codexWasRunning: false
            )
            let writer = ProtectedFileMutationContext(restorePoint: restorePoint)
            try vaultStore.forgetAccount(id: identifier, writer: writer)
            if settings.preferredAccountID == identifier {
                settings.preferredAccountID = nil
                try store.saveSettings(settings, writer: writer)
            }
            presentSafeSwitchNotice(
                MenuNotice(
                    kind: .info,
                    message: AppLocalization.localized(
                        en: "Forgot \(record.metadata.displayName). Restore point \(restorePoint.id) is ready.",
                        zh: "已移除 \(record.metadata.displayName)。还原点 \(restorePoint.id) 已创建。"
                    )
                ),
                lifetime: .timed(4)
            )
        } catch {
            presentSafeSwitchNotice(
                MenuNotice(
                    kind: .error,
                    message: AppLocalization.localized(
                        en: "Forget account failed: \(userFacingMessage(for: error))",
                        zh: "移除账号失败：\(userFacingMessage(for: error))"
                    )
                ),
                lifetime: .persistent
            )
        }

        refreshAllProfiles()
    }

    private func switchSafely(to targetProfile: ProviderProfile) {
        guard beginForegroundOperation(.safeSwitch) else {
            return
        }

        let preview: SwitchOperationPreview
        do {
            preview = try switchOrchestrator.preview(targetProfile: targetProfile)
        } catch {
            endForegroundOperation(.safeSwitch)
            presentSafeSwitchNotice(
                MenuNotice(kind: .error, message: userFacingMessage(for: error)),
                lifetime: .persistent
            )
            rebuildMenu()
            return
        }

        guard confirmSafeSwitch(targetProfile: targetProfile, preview: preview) else {
            endForegroundOperation(.safeSwitch)
            return
        }

        presentSafeSwitchNotice(
            MenuNotice(
                kind: .info,
                message: AppLocalization.localized(
                    en: "Switching to \(targetProfile.displayName)…",
                    zh: "正在切换到 \(targetProfile.displayName)…"
                )
            ),
            lifetime: .operationBound
        )
        rebuildMenu()

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let result = try await self.switchOrchestrator.perform(targetProfile: targetProfile)
                if targetProfile.source == .vault {
                    let writer = ProtectedFileMutationContext(restorePoint: result.restorePoint)
                    do {
                        _ = try self.vaultStore.noteAccountUsed(id: targetProfile.id, writer: writer)
                    } catch {
                        self.statusNotice = MenuNotice(
                            kind: .warning,
                            message: AppLocalization.localized(
                                en: "Switched successfully, but the saved account usage timestamp could not be updated: \(self.userFacingMessage(for: error))",
                                zh: "切换已完成，但无法更新账号最近使用时间：\(self.userFacingMessage(for: error))"
                            )
                        )
                    }
                    self.settings.preferredAccountID = targetProfile.id
                    do {
                        try self.store.saveSettings(self.settings, writer: writer)
                    } catch {
                        self.statusNotice = MenuNotice(
                            kind: .warning,
                            message: AppLocalization.localized(
                                en: "Switched successfully, but the preferred account could not be saved: \(self.userFacingMessage(for: error))",
                                zh: "切换已完成，但无法保存默认账号：\(self.userFacingMessage(for: error))"
                            )
                        )
                    }
                }
                self.presentSafeSwitchNotice(
                    MenuNotice(
                        kind: .info,
                        message: AppLocalization.localized(
                            en: "Switched to \(targetProfile.displayName). Restore point \(result.restorePoint.id) is ready.",
                            zh: "已切换到 \(targetProfile.displayName)。还原点 \(result.restorePoint.id) 已创建。"
                        )
                    ),
                    lifetime: .timed(4)
                )
            } catch {
                self.presentSafeSwitchNotice(
                    MenuNotice(
                        kind: .error,
                        message: AppLocalization.localized(
                            en: "Safe switch failed: \(self.userFacingMessage(for: error)). Use “Rollback Last Change” if needed.",
                            zh: "安全切换失败：\(self.userFacingMessage(for: error))。如有需要，请使用“回滚上次变更”。"
                        )
                    ),
                    lifetime: .persistent
                )
            }

            self.endForegroundOperation(.safeSwitch)
            self.refreshAllProfiles()
        }
    }

    @objc
    private func repairNowTapped() {
        guard beginForegroundOperation(.repair) else {
            return
        }

        presentSafeSwitchNotice(
            MenuNotice(
                kind: .info,
                message: AppLocalization.localized(en: "Repairing local thread metadata…", zh: "正在修复本地线程元数据…")
            ),
            lifetime: .operationBound
        )
        rebuildMenu()

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let result = try await self.switchOrchestrator.repairCurrentThreads()
                let summary = result.repairSummary
                self.presentSafeSwitchNotice(
                    MenuNotice(
                        kind: .info,
                        message: AppLocalization.localized(
                            en: "Repair complete. Restore point \(result.restorePoint.id) is ready. Threads updated: \(summary.updatedThreads + summary.createdThreads), recent index updates: \(summary.updatedSessionIndexEntries).",
                            zh: "修复完成。还原点 \(result.restorePoint.id) 已创建。线程更新 \(summary.updatedThreads + summary.createdThreads) 条，recent 索引更新 \(summary.updatedSessionIndexEntries) 条。"
                        )
                    ),
                    lifetime: .timed(4)
                )
            } catch {
                self.presentSafeSwitchNotice(
                    MenuNotice(
                        kind: .error,
                        message: AppLocalization.localized(
                            en: "Repair failed: \(self.userFacingMessage(for: error))",
                            zh: "修复失败：\(self.userFacingMessage(for: error))"
                        )
                    ),
                    lifetime: .persistent
                )
            }

            self.endForegroundOperation(.repair)
            self.refreshAllProfiles()
        }
    }

    @objc
    private func rollbackLastChangeTapped() {
        guard let restorePoint = safeSwitchCenterState?.latestRestorePoint,
              beginForegroundOperation(.rollback) else {
            return
        }

        guard confirmRollback(restorePoint: restorePoint) else {
            endForegroundOperation(.rollback)
            return
        }

        presentSafeSwitchNotice(
            MenuNotice(
                kind: .info,
                message: AppLocalization.localized(en: "Rolling back the latest safe switch…", zh: "正在回滚最近一次安全切换…")
            ),
            lifetime: .operationBound
        )
        rebuildMenu()

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let manifest = try await self.rollbackManager.rollbackLatest()
                self.presentSafeSwitchNotice(
                    MenuNotice(
                        kind: .info,
                        message: AppLocalization.localized(
                            en: "Rollback complete. Restored \(manifest.id).",
                            zh: "回滚完成。已恢复 \(manifest.id)。"
                        )
                    ),
                    lifetime: .timed(4)
                )
            } catch {
                self.presentSafeSwitchNotice(
                    MenuNotice(
                        kind: .error,
                        message: AppLocalization.localized(
                            en: "Rollback failed: \(self.userFacingMessage(for: error))",
                            zh: "回滚失败：\(self.userFacingMessage(for: error))"
                        )
                    ),
                    lifetime: .persistent
                )
            }

            self.endForegroundOperation(.rollback)
            self.refreshAllProfiles()
        }
    }

    @objc
    private func manageSessionsTapped() {
        guard !isLaunchingSessionManager else { return }

        isLaunchingSessionManager = true
        presentSessionManagerNotice(
            MenuNotice(
                kind: .info,
                message: AppLocalization.localized(en: "Opening session manager…", zh: "正在打开 Session Manager…")
            ),
            lifetime: .operationBound
        )
        rebuildMenu()

        Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                self.isLaunchingSessionManager = false
                self.rebuildMenu()
            }

            do {
                _ = try await self.sessionManagerCoordinator.openInBrowser()
                self.sessionManagerNotice = nil
            } catch {
                self.presentSessionManagerNotice(
                    MenuNotice(
                        kind: .error,
                        message: self.userFacingMessage(for: error)
                    ),
                    lifetime: .persistent
                )
            }
        }
    }

    @objc
    private func openSettingsTapped() {
        if menuTrackingGate.isTracking {
            deferredMenuPresentations.enqueue(.settings)
            return
        }

        presentSettingsWindow()
    }

    private func presentSettingsWindow() {
        let wasVisible = settingsPresenter.isVisible
        if !wasVisible {
            beginForegroundPresentation()
        }
        let accountPanelState = buildSettingsAccountPanelState(
            vaultSnapshot: vaultSnapshot,
            vaultProfiles: vaultProfiles,
            currentProviderProfile: currentProviderProfile,
            refreshIntervalPreset: settings.refreshIntervalPreset,
            actionsEnabled: !isPerformingSafeSwitchOperation
        )
        settingsPresenter.show(
            settings: settings,
            accountPanelState: accountPanelState,
            callbacks: SettingsPresenterCallbacks(
                onSettingsChanged: { [weak self] updatedSettings in
                    guard let self else { return }
                    let previousSettings = self.settings
                    do {
                        self.settings = try applySettingsTransaction(
                            previous: previousSettings,
                            updated: updatedSettings,
                            syncLaunchAtLogin: { enabled in
                                try self.launchAtLoginManager.sync(enabled: enabled)
                            },
                            saveSettings: { settings in
                                try self.store.saveSettings(settings)
                            }
                        )
                    } catch {
                        self.settings = previousSettings
                        self.settingsPresenter.update(
                            settings: previousSettings,
                            accountPanelState: buildSettingsAccountPanelState(
                                vaultSnapshot: self.vaultSnapshot,
                                vaultProfiles: self.vaultProfiles,
                                currentProviderProfile: self.currentProviderProfile,
                                refreshIntervalPreset: self.settings.refreshIntervalPreset,
                                actionsEnabled: !self.isPerformingSafeSwitchOperation
                            )
                        )
                        self.statusNotice = MenuNotice(kind: .error, message: self.userFacingMessage(for: error))
                    }
                    self.scheduleRefreshTimer()
                    self.refreshSettingsUI()
                },
                onAddChatGPTAccount: { [weak self] in
                    self?.addChatGPTAccountTapped()
                },
                onAddAPIAccount: { [weak self] in
                    self?.addAPIAccountTapped()
                },
                onActivateAccount: { [weak self] identifier in
                    self?.activateSavedAccount(identifier: identifier)
                },
                onRenameAccount: { [weak self] identifier in
                    self?.renameSavedAccount(identifier: identifier)
                },
                onForgetAccount: { [weak self] identifier in
                    self?.forgetSavedAccount(identifier: identifier)
                },
                onOpenVaultFolder: { [weak self] in
                    self?.openVaultFolder()
                },
                onWindowClosed: { [weak self] in
                    self?.endForegroundPresentationIfPossible()
                }
            )
        )
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openVaultFolder() {
        do {
            try FileManager.default.createDirectory(
                at: store.accountsRootURL,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.activateFileViewerSelecting([store.accountsRootURL])
        } catch {
            statusNotice = MenuNotice(
                kind: .error,
                message: AppLocalization.localized(
                    en: "Could not open the local vault folder: \(userFacingMessage(for: error))",
                    zh: "无法打开本地账号仓文件夹：\(userFacingMessage(for: error))"
                )
            )
            rebuildMenu(reason: "open-vault-error")
        }
    }

    @objc
    private func quitTapped() {
        NSApplication.shared.terminate(nil)
    }

    private func currentStatusSummary(for snapshot: CodexSnapshot) -> String {
        if snapshot.account.type == "apiKey" {
            let details = (try? store.currentRuntimeMaterial()).flatMap {
                apiKeyProfileDetails(authData: $0.authData, configData: $0.configData)
            }
            return apiKeyStatusTexts(details: details).0
        }

        let windows = quotaDisplayWindows(from: snapshot)
        guard !windows.isEmpty else {
            return AppLocalization.statusPlaceholderSummary()
        }
        return windows.map(compactWindowSummary).joined(separator: " ")
    }

    private func compactWindowSummary(_ quotaWindow: QuotaDisplayWindow) -> String {
        "\(quotaWindow.label)\(quotaWindow.window.remainingPercentText)"
    }

    private func formatUsageResetDate(_ date: Date?, style: UsageDateStyle) -> String {
        guard let date else { return "-" }

        let formatter = DateFormatter()
        formatter.locale = AppLocalization.locale
        switch style {
        case .time:
            formatter.dateFormat = "HH:mm"
        case .monthDay:
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
        }
        return formatter.string(from: date)
    }

    private func protectedMutationFileURLs(forAccountIDs accountIDs: [String]) throws -> [URL] {
        let additionalFiles = try vaultStore.allProtectedFileURLs() + vaultStore.protectedMutationFileURLs(forAccountIDs: accountIDs)
        return deduplicatedFileURLs(store.protectedMutationFileURLs(additionalFiles: additionalFiles))
    }

    private func deduplicatedFileURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        for url in urls {
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else {
                continue
            }
            result.append(standardized)
        }

        return result.sorted { $0.path < $1.path }
    }

    private func bootstrapVaultAccounts(currentRuntimeMaterial: ProfileRuntimeMaterial?) {
        do {
            let outcome = try vaultBootstrapCoordinator.bootstrap(
                currentRuntimeMaterial: currentRuntimeMaterial,
                currentSnapshot: currentSnapshot,
                settings: settings,
                saveSettings: { [store] settings, writer in
                    try store.saveSettings(settings, writer: writer)
                },
                userFacingMessage: { [weak self] error in
                    self?.userFacingMessage(for: error) ?? error.localizedDescription
                }
            )
            settings = outcome.settings
            if let statusNotice = outcome.statusNotice {
                self.statusNotice = statusNotice
            }
            if let safeSwitchNotice = outcome.safeSwitchNotice {
                presentSafeSwitchNotice(
                    safeSwitchNotice,
                    lifetime: .persistent
                )
            }
        } catch {
            presentSafeSwitchNotice(
                MenuNotice(
                    kind: .error,
                    message: userFacingMessage(for: error)
                ),
                lifetime: .persistent
            )
        }
    }

    private func refreshVaultProfiles(
        currentRuntimeMaterial: ProfileRuntimeMaterial?,
        scheduleQuotaRefresh: Bool
    ) {
        do {
            let snapshot = try vaultStore.loadSnapshot()
            vaultSnapshot = snapshot

            let builtProfiles = snapshot.accounts.map { record in
                let quotaRecord = vaultQuotaRecords[record.id]
                return buildProviderProfile(
                    id: record.id,
                    fallbackDisplayName: record.metadata.displayName,
                    source: .vault,
                    runtimeMaterial: record.runtimeMaterial,
                    snapshot: quotaRecord?.snapshot,
                    healthStatus: quotaRecord?.healthStatus ?? .healthy,
                    errorMessage: quotaRecord?.errorSummary,
                    isCurrent: runtimeMatches(record.runtimeMaterial, currentRuntimeMaterial),
                    managedFileURLs: [store.settingsURL, store.accountsIndexURL] + record.protectedFileURLs,
                    lastUsedAt: record.metadata.lastUsedAt,
                    quotaFetchedAt: quotaRecord?.fetchedAt
                )
            }

            vaultProfiles = sortProviderProfiles(builtProfiles)
            availableSwitchTargets = sortProviderProfiles(
                builtProfiles.filter { !runtimeMatches($0.runtimeMaterial, currentRuntimeMaterial) }
            )
        } catch {
            vaultSnapshot = nil
            vaultProfiles = []
            availableSwitchTargets = []
            presentSafeSwitchNotice(
                MenuNotice(
                    kind: .error,
                    message: AppLocalization.localized(
                        en: "Failed to read saved accounts: \(userFacingMessage(for: error))",
                        zh: "读取已保存账号失败：\(userFacingMessage(for: error))"
                    )
                ),
                lifetime: .persistent
            )
        }

        applyVaultPresentationStateUpdates()

        guard scheduleQuotaRefresh, let vaultSnapshot else {
            return
        }

        quotaRefreshCoordinator.requestRefresh(
            .init(
                currentProfile: currentProviderProfile,
                vaultAccounts: vaultSnapshot.accounts,
                cachedRecords: Array(vaultQuotaRecords.values)
            )
        ) { [weak self] records in
            guard let self else { return }
            self.vaultQuotaRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.accountID, $0) })
            do {
                try self.quotaCacheStore.save(records)
            } catch {
                self.statusNotice = MenuNotice(
                    kind: .warning,
                    message: AppLocalization.localized(
                        en: "Quota cache could not be updated: \(self.userFacingMessage(for: error))",
                        zh: "额度缓存无法更新：\(self.userFacingMessage(for: error))"
                    )
                )
            }
            self.scheduleVaultPresentationRefresh(currentRuntimeMaterial: currentRuntimeMaterial)
        }
    }

    private func applyVaultPresentationStateUpdates(now: Date = Date()) {
        refreshSafeSwitchCenterState()
        refreshQuotaOverviewState(now: now)
        refreshSettingsAccountPanel()
        rebuildMenu(reason: "vault-presentation")
    }

    private func scheduleVaultPresentationRefresh(
        currentRuntimeMaterial: ProfileRuntimeMaterial?,
        delay: TimeInterval = 0.3
    ) {
        pendingVaultPresentationRefresh?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingVaultPresentationRefresh = nil
            self?.refreshVaultProfiles(
                currentRuntimeMaterial: currentRuntimeMaterial,
                scheduleQuotaRefresh: false
            )
        }
        pendingVaultPresentationRefresh = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func refreshQuotaOverviewState(now: Date = Date()) {
        quotaOverviewState = buildQuotaOverviewState(
            currentProfile: currentProviderProfile,
            vaultProfiles: vaultProfiles,
            refreshIntervalPreset: settings.refreshIntervalPreset,
            now: now
        )
    }

    private func promptForText(
        title: String,
        message: String,
        defaultValue: String
    ) -> String? {
        runForegroundModalPresentation {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: AppLocalization.localized(en: "Save", zh: "保存"))
            alert.addButton(withTitle: AppLocalization.localized(en: "Cancel", zh: "取消"))

            let field = NSTextField(string: defaultValue)
            field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
            alert.accessoryView = field

            guard alert.runModal() == .alertFirstButtonReturn else {
                return nil
            }

            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    private func confirmForgetAccount(record: VaultAccountRecord) -> Bool {
        runForegroundModalPresentation {
            let alert = NSAlert()
            alert.messageText = AppLocalization.localized(
                en: "Forget \(record.metadata.displayName)?",
                zh: "要移除 \(record.metadata.displayName) 吗？"
            )
            alert.informativeText = AppLocalization.localized(
                en: "This removes the saved account from the local vault. A restore point will be created first.",
                zh: "这会从本地账号仓移除该账号。操作前会先创建还原点。"
            )
            alert.addButton(withTitle: AppLocalization.localized(en: "Forget Account", zh: "移除账号"))
            alert.addButton(withTitle: AppLocalization.localized(en: "Cancel", zh: "取消"))
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    private func startChatGPTAccountFlow(useDeviceAuth: Bool) {
        guard beginOrHandoffChatGPTOperation(useDeviceAuth: useDeviceAuth) else {
            return
        }

        let operation: ForegroundOperation = useDeviceAuth ? .chatGPTDeviceLogin : .chatGPTBrowserLogin
        presentSafeSwitchNotice(
            MenuNotice(
                kind: .info,
                message: useDeviceAuth
                    ? AppLocalization.localized(en: "Waiting for device-code login…", zh: "正在等待设备码登录…")
                    : AppLocalization.localized(en: "Waiting for ChatGPT login in your browser…", zh: "正在等待浏览器中的 ChatGPT 登录…")
            ),
            lifetime: .operationBound
        )
        rebuildMenu()

        Task { @MainActor [weak self] in
            guard let self else { return }
            var shouldEndOperation = true

            defer {
                if shouldEndOperation {
                    self.endForegroundOperation(operation)
                    self.refreshAllProfiles()
                }
            }

            do {
                let result = try await self.accountOnboardingCoordinator.addChatGPTAccount(
                    useDeviceAuth: useDeviceAuth,
                    deviceAuthHandler: useDeviceAuth
                        ? { [weak self] instructions in
                            self?.presentDeviceAuthInstructions(instructions)
                        }
                        : nil
                )
                self.presentSafeSwitchNotice(
                    MenuNotice(
                        kind: .info,
                        message: AppLocalization.localized(
                            en: "Added \(result.record.metadata.displayName). Restore point \(result.restorePoint.id) is ready.",
                            zh: "已添加 \(result.record.metadata.displayName)。还原点 \(result.restorePoint.id) 已创建。"
                        )
                    ),
                    lifetime: .timed(4)
                )
            } catch {
                if !useDeviceAuth,
                   self.confirmDeviceAuthFallback(error: error) {
                    shouldEndOperation = false
                    self.startChatGPTAccountFlow(useDeviceAuth: true)
                    return
                }

                self.presentSafeSwitchNotice(
                    MenuNotice(
                        kind: .error,
                        message: AppLocalization.localized(
                            en: "ChatGPT login failed: \(self.userFacingMessage(for: error))",
                            zh: "ChatGPT 登录失败：\(self.userFacingMessage(for: error))"
                        )
                    ),
                    lifetime: .persistent
                )
            }
        }
    }

    private func confirmDeviceAuthFallback(error: Error) -> Bool {
        runForegroundModalPresentation {
            let alert = NSAlert()
            alert.messageText = AppLocalization.localized(en: "Browser login failed", zh: "浏览器登录失败")
            alert.informativeText = [
                userFacingMessage(for: error),
                "",
                AppLocalization.localized(en: "Use device-code sign-in instead?", zh: "改用设备码登录吗？")
            ].joined(separator: "\n")
            alert.addButton(withTitle: AppLocalization.localized(en: "Use Device Code", zh: "使用设备码"))
            alert.addButton(withTitle: AppLocalization.localized(en: "Cancel", zh: "取消"))
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    private func presentDeviceAuthInstructions(_ instructions: DeviceAuthInstructions) {
        beginForegroundPresentation()
        if let url = URL(string: instructions.verificationURL) {
            _ = NSWorkspace.shared.open(url)
        }

        let alert = NSAlert()
        alert.messageText = AppLocalization.localized(en: "Finish Device-Code Sign-In", zh: "完成设备码登录")
        alert.informativeText = [
            AppLocalization.localized(
                en: "Open the sign-in page and enter this one-time code:",
                zh: "打开登录页面并输入下面这组一次性验证码："
            ),
            instructions.userCode,
            "",
            instructions.verificationURL,
        ].joined(separator: "\n")
        alert.addButton(withTitle: AppLocalization.localized(en: "Continue Waiting", zh: "继续等待"))
        _ = alert.runModal()
        endForegroundPresentationIfPossible()
    }

    private func runForegroundModalPresentation<T>(_ body: () -> T) -> T {
        beginForegroundPresentation()
        defer { endForegroundPresentationIfPossible() }
        return body()
    }

    private func beginForegroundPresentation() {
        foregroundPresentationDepth += 1
        if foregroundPresentationDepth == 1 {
            _ = NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func endForegroundPresentationIfPossible() {
        foregroundPresentationDepth = max(0, foregroundPresentationDepth - 1)
        guard foregroundPresentationDepth == 0,
              !settingsPresenter.isVisible else {
            return
        }
        _ = NSApp.setActivationPolicy(.accessory)
    }

    private func sortProviderProfiles(_ profiles: [ProviderProfile]) -> [ProviderProfile] {
        profiles.sorted { lhs, rhs in
            if lhs.authMode != rhs.authMode {
                return lhs.authMode.rawValue < rhs.authMode.rawValue
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func runtimeMatches(
        _ lhs: ProfileRuntimeMaterial,
        _ rhs: ProfileRuntimeMaterial?
    ) -> Bool {
        stableRuntimeIdentityMatches(lhs, rhs)
    }

    private func matchingVaultRecord(
        for runtimeMaterial: ProfileRuntimeMaterial?
    ) -> VaultAccountRecord? {
        guard let runtimeMaterial else {
            return nil
        }

        return vaultSnapshot?.accounts.first {
            stableRuntimeIdentityMatches($0.runtimeMaterial, runtimeMaterial)
        }
    }

    private func userFacingMessage(for error: Error) -> String {
        userFacingErrorMessage(error)
    }

    func stopSessionManagerIfNeeded() {
        sessionManagerCoordinator.stopManagedProcess()
    }
}
