import AppKit
import Foundation

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
        desktopController: desktopController,
        quotaChannelInvalidator: rpcClient
    )
    private lazy var rollbackManager = RollbackManager(
        backupManager: backupManager,
        desktopController: desktopController,
        quotaChannelInvalidator: rpcClient
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
        snapshotFetcher: { [rpcClient] runtimeMaterial, timeout in
            try await rpcClient.fetchSavedAccountSnapshot(
                authData: runtimeMaterial.authData,
                configData: runtimeMaterial.configData,
                timeout: timeout
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
    private var vaultProfiles: [ProviderProfile] = []
    private var availableSwitchTargets: [ProviderProfile] = []
    private var quotaOverviewState: QuotaOverviewState?
    private var safeSwitchCenterState: SafeSwitchCenterState?
    private var statusNotice: MenuNotice?
    private var loadWarningNotice: String?
    private var localizationNotice: MenuNotice?
    private var isLaunchingSessionManager = false
    private var foregroundOperationState = ForegroundOperationState()
    private var cachedThreadSyncStatus: LocalThreadSyncStatus?
    private let settingsWindowCoordinator = SettingsWindowCoordinator()
    private var menuTrackingGate = MenuTrackingGate()
    private var pendingMenuRefreshReason: String?
    private var deferredMenuPresentations = DeferredMenuPresentationQueue()
    private lazy var transientMenuNotices = TransientMenuNoticeController(
        operationStateProvider: { [weak self] in
            (
                isForegroundOperationActive: self?.isPerformingSafeSwitchOperation ?? false,
                isLaunchingSessionManager: self?.isLaunchingSessionManager ?? false
            )
        }
    ) { [weak self] in
        self?.rebuildMenu(reason: "notice-expired")
    }
    private lazy var foregroundPresentationController = ForegroundPresentationController(
        isPrimaryWindowVisible: { [weak self] in
            self?.settingsWindowCoordinator.isVisible ?? false
        }
    )
    private lazy var profileRefreshController = ProfileRefreshController(
        store: store,
        vaultStore: vaultStore,
        currentSnapshotFetcher: currentSnapshotFetcher,
        vaultBootstrapCoordinator: vaultBootstrapCoordinator,
        quotaRefreshCoordinator: quotaRefreshCoordinator,
        quotaCacheStore: quotaCacheStore,
        settingsProvider: { [weak self] in
            self?.settings ?? AppSettings()
        },
        saveSettings: { [store] settings, writer in
            try store.saveSettings(settings, writer: writer)
        },
        applySettings: { [weak self] settings in
            self?.settings = settings
        },
        currentProfileBuilder: { [weak self] runtimeMaterial, snapshot, healthStatus, errorMessage, lastRefreshAt in
            self?.makeCurrentProviderProfile(
                currentRuntimeMaterial: runtimeMaterial,
                snapshot: snapshot,
                healthStatus: healthStatus,
                errorMessage: errorMessage,
                lastRefreshAt: lastRefreshAt
            )
        },
        localizedErrorNotice: { [weak self] kind, en, zh, error in
            self?.localizedErrorNotice(kind: kind, en: en, zh: zh, error: error)
                ?? MenuNotice(kind: kind, message: userFacingErrorMessage(error))
        },
        userFacingMessage: { [weak self] error in
            self?.userFacingMessage(for: error) ?? userFacingErrorMessage(error)
        },
        presentSafeSwitchNotice: { [weak self] notice, lifetime in
            self?.presentSafeSwitchNotice(notice, lifetime: lifetime)
        },
        setStatusNotice: { [weak self] notice in
            self?.statusNotice = notice
        },
        onStateChanged: { [weak self] in
            self?.refreshPresentationFromProfileRefreshController()
        }
    )

    private var currentSnapshot: CodexSnapshot? {
        profileRefreshController.currentSnapshot
    }

    private var currentHealthStatus: ProfileHealthStatus? {
        profileRefreshController.currentHealthStatus
    }

    private var currentError: String? {
        profileRefreshController.currentError
    }

    private var currentProviderProfile: ProviderProfile? {
        profileRefreshController.currentProviderProfile
    }

    private var vaultSnapshot: AccountVaultSnapshot? {
        profileRefreshController.vaultSnapshot
    }

    private var vaultQuotaRecords: [String: VaultQuotaSnapshotRecord] {
        profileRefreshController.vaultQuotaRecords
    }

    private var lastRefreshAt: Date? {
        profileRefreshController.lastRefreshAt
    }

    private var refreshProgress: RefreshProgress? {
        profileRefreshController.refreshProgress
    }

    func start() {
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.title = "CX"

        loadReadOnlyState()
        synchronizeLocalizationState()
        let currentRuntimeMaterial = try? store.currentRuntimeMaterial()
        profileRefreshController.prepareInitialState(currentRuntimeMaterial: currentRuntimeMaterial)
        applySettingsSideEffects(showErrorsInStatus: false)
        rebuildMenu()
        profileRefreshController.refreshCurrentProfileOnly()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshTimeSensitivePresentationState(now: Date())
        menuTrackingGate.beginTracking()
        refreshSavedAccountsOnMenuOpen()
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
            profileRefreshController.replaceCachedQuotaRecords(cachedRecords)
        } catch {
            profileRefreshController.replaceCachedQuotaRecords([])
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
        profileRefreshController.scheduleRefreshTimer()
        do {
            try launchAtLoginManager.sync(enabled: settings.launchAtLoginEnabled)
        } catch {
            AppLog.settings.error("Launch-at-login sync failed: \(self.userFacingMessage(for: error), privacy: .public)")
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
        settingsWindowCoordinator.update(state: currentSettingsWindowPresentationState())
        updateStatusTitle()
        rebuildMenu(reason: "settings-ui")
    }

    private func refreshSettingsAccountPanel() {
        settingsWindowCoordinator.update(state: currentSettingsWindowPresentationState())
    }

    private func refreshPresentationFromProfileRefreshController(now: Date = Date()) {
        invalidateCachedThreadSyncStatusIfNeeded()
        rebuildVaultPresentation(currentRuntimeMaterial: profileRefreshController.currentRuntimeMaterial)
        applyVaultPresentationStateUpdates(now: now)
    }

    private func refreshCurrentProfileOnly() {
        profileRefreshController.refreshCurrentProfileOnly()
    }

    private func refreshSavedAccountsOnMenuOpen() {
        profileRefreshController.refreshSavedAccountsOnMenuOpen()
    }

    private func refreshAllProfiles() {
        profileRefreshController.refreshAllProfiles()
    }

    private func rebuildMenu(force: Bool = false, reason: String? = nil) {
        if !force && !menuTrackingGate.requestRebuild() {
            if pendingMenuRefreshReason == nil {
                pendingMenuRefreshReason = reason
            }
            return
        }

        pendingMenuRefreshReason = nil
        if updateMenuInPlaceIfPossible() {
            return
        }
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

    private func updateMenuInPlaceIfPossible() -> Bool {
        guard visibleMenuNotice() == nil,
              let quotaSectionEndIndex = menu.items.firstIndex(where: \.isSeparatorItem),
              menu.items.count == quotaSectionEndIndex + 4 else {
            return false
        }

        let quotaItems = Array(menu.items[..<quotaSectionEndIndex])
        guard reconcileQuotaOverviewMenuItemsInPlace(
            quotaItems,
            quotaOverviewState: quotaOverviewState,
            refreshIntervalPreset: settings.refreshIntervalPreset,
            isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation,
            target: self,
            activateSavedAccountAction: #selector(activateSavedAccountTapped(_:))
        ) else {
            return false
        }

        let maintenanceItem = menu.items[quotaSectionEndIndex + 1]
        maintenanceItem.title = AppLocalization.localized(en: "Maintenance", zh: "维护")
        maintenanceItem.action = nil
        maintenanceItem.target = nil
        maintenanceItem.representedObject = nil
        maintenanceItem.isEnabled = true
        maintenanceItem.submenu = makeMaintenanceMenu()

        let settingsItem = menu.items[quotaSectionEndIndex + 2]
        settingsItem.title = AppLocalization.localized(en: "Settings…", zh: "设置…")
        settingsItem.action = #selector(openSettingsTapped)
        settingsItem.target = self
        settingsItem.isEnabled = true

        let quitItem = menu.items[quotaSectionEndIndex + 3]
        quitItem.title = AppLocalization.localized(en: "Quit", zh: "退出")
        quitItem.action = #selector(quitTapped)
        quitItem.target = self
        quitItem.isEnabled = true

        return true
    }

    private func visibleMenuNotice() -> MenuNotice? {
        transientMenuNotices.visibleNotice(
            isForegroundOperationActive: isPerformingSafeSwitchOperation,
            isLaunchingSessionManager: isLaunchingSessionManager,
            localizationNotice: localizationNotice,
            statusNotice: statusNotice,
            currentError: currentError,
            loadWarningNotice: loadWarningNotice
        )
    }

    private var isRefreshing: Bool {
        profileRefreshController.isRefreshing
    }

    private var isPerformingSafeSwitchOperation: Bool {
        foregroundOperationState.isBusy
    }

    private func presentSafeSwitchNotice(
        _ notice: MenuNotice,
        lifetime: MenuNoticeLifetime,
        now: Date = Date()
    ) {
        transientMenuNotices.presentSafeSwitchNotice(
            notice,
            lifetime: lifetime,
            now: now,
            isForegroundOperationActive: isPerformingSafeSwitchOperation,
            isLaunchingSessionManager: isLaunchingSessionManager
        )
    }

    private func presentSessionManagerNotice(
        _ notice: MenuNotice,
        lifetime: MenuNoticeLifetime,
        now: Date = Date()
    ) {
        transientMenuNotices.presentSessionManagerNotice(
            notice,
            lifetime: lifetime,
            now: now,
            isForegroundOperationActive: isPerformingSafeSwitchOperation,
            isLaunchingSessionManager: isLaunchingSessionManager
        )
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
        let apiKeyDetails = currentSnapshot?.account.type == "apiKey"
            ? (try? store.currentRuntimeMaterial()).flatMap {
                apiKeyProfileDetails(authData: $0.authData, configData: $0.configData)
            }
            : nil
        let presentation = buildStatusItemPresentation(
            snapshot: currentSnapshot,
            apiKeyDetails: apiKeyDetails,
            statusItemStyle: settings.statusItemStyle,
            refreshIntervalPreset: settings.refreshIntervalPreset,
            isRefreshing: isRefreshing,
            currentError: currentError,
            lastRefreshAt: lastRefreshAt
        )
        applyStatusItemPresentation(
            presentation,
            to: button,
            statusItem: statusItem,
            renderer: statusItemRenderer
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
        for item in buildQuotaOverviewMenuItems(
            quotaOverviewState: quotaOverviewState,
            refreshIntervalPreset: settings.refreshIntervalPreset,
            isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation,
            target: self,
            activateSavedAccountAction: #selector(activateSavedAccountTapped(_:))
        ) {
            menu.addItem(item)
        }
    }

    private func makeMaintenanceMenu() -> NSMenu {
        buildMaintenanceMenu(
            isRefreshing: isRefreshing,
            refreshProgress: refreshProgress,
            isLaunchingSessionManager: isLaunchingSessionManager,
            isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation,
            hasRollbackRestorePoint: safeSwitchCenterState?.latestRestorePoint != nil,
            target: self,
            refreshAction: #selector(refreshTapped),
            manageSessionsAction: #selector(manageSessionsTapped),
            repairAction: #selector(repairNowTapped),
            rollbackAction: #selector(rollbackLastChangeTapped)
        )
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
        currentRuntimeMaterial: ProfileRuntimeMaterial?,
        snapshot: CodexSnapshot?,
        healthStatus: ProfileHealthStatus?,
        errorMessage: String?,
        lastRefreshAt: Date?
    ) -> ProviderProfile? {
        guard let currentRuntimeMaterial else {
            return nil
        }

        let matchingVaultRecord = matchingVaultRecord(for: currentRuntimeMaterial)
        let fallbackName = snapshot?.account.displayLabel
            ?? matchingVaultRecord?.metadata.displayName
            ?? AppLocalization.currentAccountFallbackName()

        return buildProviderProfile(
            id: matchingVaultRecord?.id ?? stableAccountRecordID(for: currentRuntimeMaterial),
            fallbackDisplayName: fallbackName,
            source: .current,
            runtimeMaterial: currentRuntimeMaterial,
            snapshot: snapshot,
            healthStatus: healthStatus ?? (errorMessage == nil ? .healthy : .readFailure),
            errorMessage: errorMessage,
            isCurrent: true,
            quotaFetchedAt: snapshot?.fetchedAt ?? lastRefreshAt
        )
    }

    private func refreshSafeSwitchCenterState() {
        let latestRestorePoint = try? backupManager.latestRestorePoint()
        safeSwitchCenterState = statusEvaluator.currentState(
            currentProfile: currentProviderProfile,
            availableTargets: availableSwitchTargets,
            codexIsRunning: desktopController.isRunning,
            localThreadSyncStatus: cachedThreadSyncStatus ?? defaultThreadSyncStatus(),
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
        foregroundPresentationController.runModal {
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
        foregroundPresentationController.runModal {
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
                    return self.foregroundPresentationController.runModal(body)
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
                    self.localizedErrorNotice(
                        en: "Add API account failed",
                        zh: "添加 API 账号失败",
                        error: error
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
                localizedErrorNotice(
                    en: "Rename failed",
                    zh: "重命名失败",
                    error: error
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
                localizedErrorNotice(
                    en: "Forget account failed",
                    zh: "移除账号失败",
                    error: error
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
        AppLog.safeSwitch.info("Starting safe switch target=\(targetProfile.displayName, privacy: .public)")

        let preview: SwitchOperationPreview
        do {
            preview = try switchOrchestrator.preview(targetProfile: targetProfile)
        } catch {
            endForegroundOperation(.safeSwitch)
            AppLog.safeSwitch.error("Safe switch preview failed: \(self.userFacingMessage(for: error), privacy: .public)")
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
                        self.statusNotice = self.localizedErrorNotice(
                            kind: .warning,
                            en: "Switched successfully, but the saved account usage timestamp could not be updated",
                            zh: "切换已完成，但无法更新账号最近使用时间",
                            error: error
                        )
                    }
                    self.settings.preferredAccountID = targetProfile.id
                    do {
                        try self.store.saveSettings(self.settings, writer: writer)
                    } catch {
                        self.statusNotice = self.localizedErrorNotice(
                            kind: .warning,
                            en: "Switched successfully, but the preferred account could not be saved",
                            zh: "切换已完成，但无法保存默认账号",
                            error: error
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
                AppLog.safeSwitch.info("Safe switch completed target=\(targetProfile.displayName, privacy: .public)")
                self.cachedThreadSyncStatus = .healthy(
                    expectedProvider: targetProfile.threadProviderID
                        ?? (targetProfile.authMode == .chatgpt ? "openai" : targetProfile.providerID)
                )
            } catch {
                AppLog.safeSwitch.error("Safe switch failed: \(self.userFacingMessage(for: error), privacy: .public)")
                self.presentSafeSwitchNotice(
                    self.localizedErrorNotice(
                        en: "Safe switch failed",
                        zh: "安全切换失败",
                        error: error,
                        suffixEN: ". Use “Rollback Last Change” if needed.",
                        suffixZH: "。如有需要，请使用“回滚上次变更”。"
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
        AppLog.safeSwitch.info("Starting repair flow")

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
                AppLog.safeSwitch.info("Repair flow completed")
                self.cachedThreadSyncStatus = .healthy(expectedProvider: self.currentExpectedProviderID)
            } catch {
                AppLog.safeSwitch.error("Repair flow failed: \(self.userFacingMessage(for: error), privacy: .public)")
                self.presentSafeSwitchNotice(
                    self.localizedErrorNotice(
                        en: "Repair failed",
                        zh: "修复失败",
                        error: error
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
        AppLog.safeSwitch.info("Starting rollback restorePoint=\(restorePoint.id, privacy: .public)")

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
                AppLog.safeSwitch.info("Rollback completed restorePoint=\(manifest.id, privacy: .public)")
                self.cachedThreadSyncStatus = nil
            } catch {
                AppLog.safeSwitch.error("Rollback failed: \(self.userFacingMessage(for: error), privacy: .public)")
                self.presentSafeSwitchNotice(
                    self.localizedErrorNotice(
                        en: "Rollback failed",
                        zh: "回滚失败",
                        error: error
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
        AppLog.sessionManager.info("Opening session manager")
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
                self.transientMenuNotices.clearSessionManagerNotice(
                    isForegroundOperationActive: self.isPerformingSafeSwitchOperation,
                    isLaunchingSessionManager: self.isLaunchingSessionManager
                )
                AppLog.sessionManager.info("Session manager opened")
            } catch {
                AppLog.sessionManager.error("Session manager open failed: \(self.userFacingMessage(for: error), privacy: .public)")
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
        AppLog.settings.info("Presenting settings window")
        if settingsWindowCoordinator.show(
            state: currentSettingsWindowPresentationState(),
            callbacks: makeSettingsPresenterCallbacks()
        ) {
            foregroundPresentationController.begin()
        } else {
            foregroundPresentationController.activate()
        }
    }

    private func openVaultFolder() {
        do {
            try FileManager.default.createDirectory(
                at: store.accountsRootURL,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.activateFileViewerSelecting([store.accountsRootURL])
        } catch {
            statusNotice = localizedErrorNotice(
                en: "Could not open the local vault folder",
                zh: "无法打开本地账号仓文件夹",
                error: error
            )
            rebuildMenu(reason: "open-vault-error")
        }
    }

    @objc
    private func quitTapped() {
        NSApplication.shared.terminate(nil)
    }

    private func protectedMutationFileURLs(forAccountIDs accountIDs: [String]) throws -> [URL] {
        let additionalFiles = vaultStore.protectedMutationFileURLs(forAccountIDs: accountIDs)
        return deduplicatedFileURLs(store.accountMutationFileURLs(additionalFiles: additionalFiles))
    }

    private func currentSettingsWindowPresentationState() -> SettingsWindowPresentationState {
        SettingsWindowPresentationState(
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

    private func makeSettingsPresenterCallbacks() -> SettingsPresenterCallbacks {
        SettingsPresenterCallbacks(
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
                    AppLog.settings.info("Applied settings update")
                } catch {
                    self.settings = previousSettings
                    self.settingsWindowCoordinator.update(state: self.currentSettingsWindowPresentationState())
                    self.statusNotice = MenuNotice(kind: .error, message: self.userFacingMessage(for: error))
                    AppLog.settings.error("Settings update failed: \(self.userFacingMessage(for: error), privacy: .public)")
                }
                self.profileRefreshController.scheduleRefreshTimer()
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
                self?.foregroundPresentationController.endIfPossible()
            }
        )
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

    private func applyVaultPresentationStateUpdates(now: Date = Date()) {
        refreshSafeSwitchCenterState()
        refreshQuotaOverviewState(now: now)
        refreshSettingsAccountPanel()
        updateStatusTitle()
        rebuildMenu(reason: "vault-presentation")
    }

    private func rebuildVaultPresentation(currentRuntimeMaterial: ProfileRuntimeMaterial?) {
        guard let snapshot = vaultSnapshot else {
            vaultProfiles = []
            availableSwitchTargets = []
            return
        }

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
                quotaFailureDisposition: quotaRecord?.failureDisposition,
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
    }

    private func defaultThreadSyncStatus() -> LocalThreadSyncStatus {
        .unavailable(
            AppLocalization.localized(
                en: "Open Session Manager and click Refresh to inspect local thread metadata.",
                zh: "请打开 Session Manager 并点击刷新，以检查本地线程元数据。"
            )
        )
    }

    private func invalidateCachedThreadSyncStatusIfNeeded() {
        guard cachedThreadSyncExpectedProviderID != currentExpectedProviderID else {
            return
        }
        cachedThreadSyncStatus = nil
    }

    private var cachedThreadSyncExpectedProviderID: String? {
        guard let cachedThreadSyncStatus else {
            return nil
        }

        switch cachedThreadSyncStatus {
        case .healthy(let expectedProvider):
            return expectedProvider
        case .repairNeeded(let expectedProvider, _, _):
            return expectedProvider
        case .unavailable:
            return nil
        }
    }

    private func refreshQuotaOverviewState(now: Date = Date()) {
        quotaOverviewState = buildQuotaOverviewState(
            currentProfile: currentProviderProfile,
            vaultProfiles: vaultProfiles,
            refreshIntervalPreset: settings.refreshIntervalPreset,
            now: now
        )
    }

    private func normalizeTransientMenuNotices(now: Date = Date()) {
        transientMenuNotices.normalize(
            now: now,
            isForegroundOperationActive: isPerformingSafeSwitchOperation,
            isLaunchingSessionManager: isLaunchingSessionManager
        )
    }

    private func refreshTimeSensitivePresentationState(now: Date = Date()) {
        normalizeTransientMenuNotices(now: now)
        refreshQuotaOverviewState(now: now)
        updateStatusTitle()
        rebuildMenu(force: true, reason: "menu-open-temporal")
    }

    private func promptForText(
        title: String,
        message: String,
        defaultValue: String
    ) -> String? {
        foregroundPresentationController.runModal {
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
        foregroundPresentationController.runModal {
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
                    self.localizedErrorNotice(
                        en: "ChatGPT login failed",
                        zh: "ChatGPT 登录失败",
                        error: error
                    ),
                    lifetime: .persistent
                )
            }
        }
    }

    private func confirmDeviceAuthFallback(error: Error) -> Bool {
        foregroundPresentationController.runModal {
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
        foregroundPresentationController.begin()
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
        foregroundPresentationController.endIfPossible()
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

    private func localizedErrorText(
        en prefixEN: String,
        zh prefixZH: String,
        error: Error,
        suffixEN: String = "",
        suffixZH: String = ""
    ) -> String {
        let message = userFacingMessage(for: error)
        return AppLocalization.localized(
            en: "\(prefixEN): \(message)\(suffixEN)",
            zh: "\(prefixZH)：\(message)\(suffixZH)"
        )
    }

    private func localizedErrorNotice(
        kind: MenuNoticeKind = .error,
        en prefixEN: String,
        zh prefixZH: String,
        error: Error,
        suffixEN: String = "",
        suffixZH: String = ""
    ) -> MenuNotice {
        MenuNotice(
            kind: kind,
            message: localizedErrorText(
                en: prefixEN,
                zh: prefixZH,
                error: error,
                suffixEN: suffixEN,
                suffixZH: suffixZH
            )
        )
    }

    func stopSessionManagerIfNeeded() {
        sessionManagerCoordinator.stopManagedProcess()
    }
}
