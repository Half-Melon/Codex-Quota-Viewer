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

enum CurrentAccountCardState: Equatable {
    case refreshing
    case empty
    case error(ProfileHealthStatus, String)
    case snapshot(CodexSnapshot)
}

enum MenuBlueprintItem: Equatable {
    case notice(MenuNotice)
    case separator
    case sectionHeader(String)
    case currentAccount
    case ccSwitchAccount(String)
    case action(title: String, isEnabled: Bool)
}

enum ProfileIndicatorKind: Equatable {
    case error
    case neutral
    case apiKey
    case limited
    case healthy
}

func buildVisibleMenuNotices(
    statusNotice: String?,
    loadWarningNotice: String?,
    currentError: String?
) -> [MenuNotice] {
    var notices: [MenuNotice] = []

    func append(_ notice: MenuNotice?) {
        guard let notice,
              !notice.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !notices.contains(notice) else {
            return
        }
        notices.append(notice)
    }

    append(statusNotice.map { MenuNotice(kind: .info, message: $0) })
    append(loadWarningNotice.map { MenuNotice(kind: .warning, message: $0) })
    append(currentError.map { MenuNotice(kind: .error, message: "Current account refresh failed: \($0)") })
    return notices
}

func userFacingErrorMessage(_ error: Error) -> String {
    if let localized = error as? LocalizedError,
       let description = localized.errorDescription {
        return description
    }
    return error.localizedDescription
}

func resolveCurrentAccountCardState(
    snapshot: CodexSnapshot?,
    explicitHealth: ProfileHealthStatus?,
    errorMessage: String?,
    isRefreshing: Bool
) -> CurrentAccountCardState {
    if let errorMessage {
        return .error(explicitHealth ?? .readFailure, errorMessage)
    }

    if let snapshot {
        return .snapshot(snapshot)
    }

    if isRefreshing {
        return .refreshing
    }

    return .empty
}

func buildMenuBlueprint(
    notices: [MenuNotice],
    ccSwitchProfileNames: [String],
    isRefreshing: Bool,
    isLaunchingSessionManager: Bool
) -> [MenuBlueprintItem] {
    var items: [MenuBlueprintItem] = []

    if !notices.isEmpty {
        items.append(contentsOf: notices.map(MenuBlueprintItem.notice))
        items.append(.separator)
    }

    items.append(.sectionHeader("Current Account"))
    items.append(.currentAccount)

    if !ccSwitchProfileNames.isEmpty {
        items.append(.separator)
        items.append(.sectionHeader("CC Switch Accounts"))
        items.append(contentsOf: ccSwitchProfileNames.map(MenuBlueprintItem.ccSwitchAccount))
    }

    items.append(.separator)
    items.append(.action(title: isRefreshing ? "Refreshing…" : "Refresh All", isEnabled: !isRefreshing))
    items.append(
        .action(
            title: isLaunchingSessionManager ? "Starting Session Manager…" : "Manage Sessions",
            isEnabled: !isLaunchingSessionManager
        )
    )
    items.append(.action(title: "Settings…", isEnabled: true))
    items.append(.action(title: "Quit", isEnabled: true))
    return items
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

func shouldHideDuplicateCCSwitchSnapshot(
    _ snapshot: CodexSnapshot?,
    currentSnapshot: CodexSnapshot?
) -> Bool {
    guard let snapshot,
          let currentSnapshot,
          snapshot.account.type != "apiKey",
          currentSnapshot.account.type != "apiKey",
          let snapshotEmail = normalizedAccountEmail(snapshot.account.email),
          let currentEmail = normalizedAccountEmail(currentSnapshot.account.email) else {
        return false
    }

    return snapshotEmail == currentEmail
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

    guard let primary = snapshot.rateLimits.primary,
          let secondary = snapshot.rateLimits.secondary else {
        return .neutral
    }

    if primary.remainingPercent <= 0 || secondary.remainingPercent <= 0 {
        return .limited
    }

    let plan = (snapshot.account.planType ?? snapshot.rateLimits.planType ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard !plan.isEmpty, plan != "free" else {
        return .neutral
    }

    return .healthy
}

private func normalizedAccountEmail(_ email: String?) -> String? {
    guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines),
          !email.isEmpty else {
        return nil
    }

    return email.lowercased()
}

@MainActor
final class AppController: NSObject, NSMenuDelegate {
    private struct CCSwitchQuotaProfile {
        let name: String
        let snapshot: CodexSnapshot?
        let healthStatus: ProfileHealthStatus
        let errorMessage: String?
    }

    private let store = ProfileStore()
    private let ccSwitchStore = CCSwitchCodexStore()
    private let rpcClient = CodexRPCClient()
    private let launchAtLoginManager = LaunchAtLoginManager()
    private let statusItemRenderer = StatusItemRenderer()
    private let sessionManagerLauncher = SessionManagerLauncher()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var settings = AppSettings()
    private var currentSnapshot: CodexSnapshot?
    private var currentHealthStatus: ProfileHealthStatus?
    private var currentError: String?
    private var ccSwitchProfiles: [CCSwitchQuotaProfile] = []
    private var ccSwitchWarningNotice: String?
    private var statusNotice: String?
    private var loadWarningNotice: String?
    private var sessionManagerNotice: MenuNotice?
    private var isRefreshing = false
    private var isLaunchingSessionManager = false
    private var lastRefreshAt: Date?
    private var refreshTimer: Timer?
    private var settingsWindowController: SettingsWindowController?

    func start() {
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.title = "CX"

        loadReadOnlyState()
        applySettingsSideEffects(showErrorsInStatus: false)
        rebuildMenu()
        refreshAllProfiles()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard shouldAutoRefreshWhenMenuOpens(settings.refreshIntervalPreset) else {
            return
        }
        refreshAllProfiles()
    }

    private func loadReadOnlyState() {
        let settingsResult = store.loadSettingsResult()
        settings = settingsResult.settings
        let issues = settingsResult.issues.map(\.message)
        loadWarningNotice = issues.isEmpty ? nil : issues.joined(separator: "; ")
        statusNotice = nil
    }

    private func applySettingsSideEffects(showErrorsInStatus: Bool) {
        scheduleRefreshTimer()
        do {
            try launchAtLoginManager.sync(enabled: settings.launchAtLoginEnabled)
        } catch {
            if showErrorsInStatus {
                statusNotice = userFacingMessage(for: error)
            }
        }
        refreshSettingsUI()
    }

    private func refreshSettingsUI() {
        settingsWindowController?.update(settings: settings)
        updateStatusTitle()
        rebuildMenu()
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
        guard !isRefreshing else { return }

        isRefreshing = true
        currentError = nil
        currentHealthStatus = currentSnapshot == nil ? nil : .healthy
        ccSwitchWarningNotice = nil
        updateStatusTitle()
        rebuildMenu()

        Task {
            defer {
                isRefreshing = false
                updateStatusTitle()
                rebuildMenu()
            }

            do {
                currentSnapshot = try await rpcClient.fetchSnapshot(
                    codexHomeURL: store.currentAuthURL.deletingLastPathComponent()
                )
                currentHealthStatus = .healthy
            } catch {
                currentSnapshot = nil
                currentHealthStatus = classifyProfileHealth(from: error)
                currentError = userFacingMessage(for: error)
            }

            lastRefreshAt = Date()
            updateStatusTitle()
            rebuildMenu()

            await refreshCCSwitchProfiles(currentRuntimeMaterial: try? store.currentRuntimeMaterial())
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let blueprint = buildMenuBlueprint(
            notices: visibleMenuNotices(),
            ccSwitchProfileNames: ccSwitchProfiles.map(\.name),
            isRefreshing: isRefreshing,
            isLaunchingSessionManager: isLaunchingSessionManager
        )
        var ccSwitchIndex = 0

        for item in blueprint {
            switch item {
            case .notice(let notice):
                addNoticeItem(notice)
            case .separator:
                menu.addItem(.separator())
            case .sectionHeader(let title):
                addDisabledItem(title)
            case .currentAccount:
                menu.addItem(makeCurrentAccountMenuItem())
            case .ccSwitchAccount(let name):
                guard ccSwitchIndex < ccSwitchProfiles.count else { continue }
                let profile = ccSwitchProfiles[ccSwitchIndex]
                ccSwitchIndex += 1
                guard profile.name == name else { continue }
                menu.addItem(makeCCSwitchMenuItem(for: profile))
            case .action(let title, let isEnabled):
                switch title {
                case "Refresh All", "Refreshing…":
                    addActionItem(title: title, action: #selector(refreshTapped), enabled: isEnabled)
                case "Manage Sessions", "Starting Session Manager…":
                    addActionItem(title: title, action: #selector(manageSessionsTapped), enabled: isEnabled)
                case "Settings…":
                    addActionItem(title: title, action: #selector(openSettingsTapped), enabled: isEnabled)
                case "Quit":
                    addActionItem(title: title, action: #selector(quitTapped), enabled: isEnabled)
                default:
                    break
                }
            }
        }
    }

    private func visibleMenuNotices() -> [MenuNotice] {
        var notices = buildVisibleMenuNotices(
            statusNotice: statusNotice,
            loadWarningNotice: loadWarningNotice,
            currentError: currentError
        )

        if let sessionManagerNotice,
           !sessionManagerNotice.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !notices.contains(sessionManagerNotice) {
            notices.append(sessionManagerNotice)
        }

        if let ccSwitchWarningNotice,
           !ccSwitchWarningNotice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let notice = MenuNotice(kind: .warning, message: ccSwitchWarningNotice)
            if !notices.contains(notice) {
                notices.append(notice)
            }
        }

        return notices
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
                title = "Refreshing"
            } else if currentError != nil {
                title = "Read failed"
            } else {
                title = "5h- 1w-"
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
                let primaryRemaining = currentSnapshot?.rateLimits.primary?.remainingPercent ?? 0
                let secondaryRemaining = currentSnapshot?.rateLimits.secondary?.remainingPercent ?? 0
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

    private func makeCurrentAccountMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Current Codex Account", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.view = AccountMenuRowView(model: makeCurrentAccountRowModel())
        return item
    }

    private func makeCurrentAccountRowModel() -> AccountMenuRowModel {
        let state = currentAccountCardState()
        let (primaryText, secondaryText) = currentAccountRowTexts(state: state)
        return AccountMenuRowModel(
            name: currentAccountDisplayName(),
            primaryUsageText: primaryText,
            secondaryUsageText: secondaryText,
            indicatorColor: currentAccountIndicatorColor(for: state),
            isCurrent: true,
            isEnabled: false
        )
    }

    private func currentAccountDisplayName() -> String {
        guard let currentSnapshot else {
            return "Current Account"
        }

        if let email = currentSnapshot.account.email,
           !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return email
        }

        if currentSnapshot.account.type == "apiKey" {
            return "Current Account · API Key"
        }

        return currentSnapshot.account.displayLabel
    }

    private func currentAccountCardState() -> CurrentAccountCardState {
        resolveCurrentAccountCardState(
            snapshot: currentSnapshot,
            explicitHealth: currentHealthStatus,
            errorMessage: currentError,
            isRefreshing: isRefreshing
        )
    }

    private func currentAccountRowTexts(state: CurrentAccountCardState) -> (String, String) {
        switch state {
        case .error(let health, let errorMessage):
            return (
                health.label,
                condensedProfileErrorText(message: errorMessage, fallback: health.label)
            )
        case .refreshing:
            return ("Refreshing", "Loading current account")
        case .empty:
            return ("Not loaded", "Use “Refresh All”")
        case .snapshot(let currentSnapshot):
            if currentSnapshot.account.type == "apiKey" {
                return apiKeyStatusTexts(
                    details: (try? store.currentRuntimeMaterial()).flatMap {
                        apiKeyProfileDetails(authData: $0.authData, configData: $0.configData)
                    }
                )
            }

            return (
                accountUsageSummary(
                    window: currentSnapshot.rateLimits.primary,
                    label: "5h",
                    dateStyle: .time
                ),
                accountUsageSummary(
                    window: currentSnapshot.rateLimits.secondary,
                    label: "1w",
                    dateStyle: .monthDay
                )
            )
        }
    }

    private func currentAccountIndicatorColor(for state: CurrentAccountCardState) -> NSColor {
        switch state {
        case .refreshing, .empty:
            return .secondaryLabelColor
        case .error(let health, _):
            return indicatorColor(snapshot: nil, health: health)
        case .snapshot(let snapshot):
            return indicatorColor(snapshot: snapshot, health: .healthy)
        }
    }

    private func makeCCSwitchMenuItem(for profile: CCSwitchQuotaProfile) -> NSMenuItem {
        let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.view = AccountMenuRowView(model: makeCCSwitchRowModel(for: profile))
        return item
    }

    private func makeCCSwitchRowModel(for profile: CCSwitchQuotaProfile) -> AccountMenuRowModel {
        let (primaryText, secondaryText) = ccSwitchAccountRowTexts(for: profile)
        return AccountMenuRowModel(
            name: profile.name,
            primaryUsageText: primaryText,
            secondaryUsageText: secondaryText,
            indicatorColor: indicatorColor(snapshot: profile.snapshot, health: profile.healthStatus),
            isCurrent: false,
            isEnabled: false
        )
    }

    private func ccSwitchAccountRowTexts(for profile: CCSwitchQuotaProfile) -> (String, String) {
        if !profile.healthStatus.isHealthy {
            return (
                profile.healthStatus.label,
                condensedProfileErrorText(
                    message: profile.errorMessage,
                    fallback: profile.healthStatus.label
                )
            )
        }

        return (
            accountUsageSummary(
                window: profile.snapshot?.rateLimits.primary,
                label: "5h",
                dateStyle: .time
            ),
            accountUsageSummary(
                window: profile.snapshot?.rateLimits.secondary,
                label: "1w",
                dateStyle: .monthDay
            )
        )
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

    private func condensedProfileErrorText(
        message: String?,
        fallback: String
    ) -> String {
        guard let message else { return fallback }
        let lowered = message.lowercased()

        if lowered.contains("unauthorized") || lowered.contains("sign in") || lowered.contains("not signed in") {
            return "Sign in required"
        }
        if lowered.contains("expired") {
            return "Session expired"
        }
        if lowered.contains("timeout") || lowered.contains("timed out") {
            return "Request timed out"
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

    @objc
    private func refreshTapped() {
        refreshAllProfiles()
    }

    @objc
    private func manageSessionsTapped() {
        guard !isLaunchingSessionManager else { return }

        isLaunchingSessionManager = true
        sessionManagerNotice = MenuNotice(kind: .info, message: "Opening session manager…")
        rebuildMenu()

        Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                self.isLaunchingSessionManager = false
                self.rebuildMenu()
            }

            do {
                _ = try await self.sessionManagerLauncher.openSessionManagerInBrowser()
                self.sessionManagerNotice = nil
            } catch {
                self.sessionManagerNotice = MenuNotice(
                    kind: .error,
                    message: self.userFacingMessage(for: error)
                )
            }
        }
    }

    @objc
    private func openSettingsTapped() {
        if settingsWindowController == nil {
            let controller = SettingsWindowController(settings: settings)
            controller.onSettingsChanged = { [weak self] updatedSettings in
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
                    self.settingsWindowController?.update(settings: previousSettings)
                    self.statusNotice = self.userFacingMessage(for: error)
                }
                self.scheduleRefreshTimer()
                self.refreshSettingsUI()
            }
            settingsWindowController = controller
        }

        settingsWindowController?.update(settings: settings)
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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

        let primary = compactWindowSummary(window: snapshot.rateLimits.primary, fallbackLabel: "5h")
        let secondary = compactWindowSummary(window: snapshot.rateLimits.secondary, fallbackLabel: "1w")
        return "\(primary) \(secondary)"
    }

    private func compactWindowSummary(window: RateLimitWindow?, fallbackLabel: String) -> String {
        guard let window else { return "\(fallbackLabel)-" }
        return "\(fallbackLabel)\(window.remainingPercentText)"
    }

    private func formatUsageResetDate(_ date: Date?, style: UsageDateStyle) -> String {
        guard let date else { return "-" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        switch style {
        case .time:
            formatter.dateFormat = "HH:mm"
        case .monthDay:
            formatter.dateFormat = "MMM d"
        }
        return formatter.string(from: date)
    }

    private func refreshCCSwitchProfiles(
        currentRuntimeMaterial: ProfileRuntimeMaterial?
    ) async {
        do {
            let providers = try ccSwitchStore.loadLoggedInOrdinaryProviders()
            let candidates = providers.filter { provider in
                !runtimeMatches(provider.runtimeMaterial, currentRuntimeMaterial)
            }
            let rpcClient = self.rpcClient

            var refreshedProfiles: [CCSwitchQuotaProfile] = []
            ccSwitchWarningNotice = nil

            let batchSize = 4
            var startIndex = 0
            while startIndex < candidates.count {
                let batch = Array(candidates[startIndex..<min(startIndex + batchSize, candidates.count)])
                let batchProfiles = await withTaskGroup(of: CCSwitchQuotaProfile?.self) { group in
                    for provider in batch {
                        group.addTask {
                            do {
                                let snapshot = try await rpcClient.fetchSnapshot(
                                    authData: provider.runtimeMaterial.authData,
                                    configData: provider.runtimeMaterial.configData
                                )
                                guard snapshot.account.type != "apiKey" else {
                                    return nil
                                }

                                return CCSwitchQuotaProfile(
                                    name: snapshot.account.email ?? provider.name,
                                    snapshot: snapshot,
                                    healthStatus: .healthy,
                                    errorMessage: nil
                                )
                            } catch {
                                return CCSwitchQuotaProfile(
                                    name: provider.name,
                                    snapshot: nil,
                                    healthStatus: classifyProfileHealth(from: error),
                                    errorMessage: userFacingErrorMessage(error)
                                )
                            }
                        }
                    }

                    var completed: [CCSwitchQuotaProfile] = []
                    for await profile in group {
                        if let profile {
                            completed.append(profile)
                        }
                    }
                    return completed
                }

                refreshedProfiles.append(
                    contentsOf: batchProfiles.filter {
                        !shouldHideDuplicateCCSwitchSnapshot(
                            $0.snapshot,
                            currentSnapshot: self.currentSnapshot
                        )
                    }
                )
                startIndex += batchSize
            }

            ccSwitchProfiles = sortCCSwitchProfiles(refreshedProfiles)
            ccSwitchWarningNotice = nil
        } catch {
            ccSwitchProfiles = []
            ccSwitchWarningNotice = "Failed to read CC Switch data: \(userFacingErrorMessage(error))"
        }

        rebuildMenu()
    }

    private func sortCCSwitchProfiles(_ profiles: [CCSwitchQuotaProfile]) -> [CCSwitchQuotaProfile] {
        profiles.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func runtimeMatches(
        _ lhs: ProfileRuntimeMaterial,
        _ rhs: ProfileRuntimeMaterial?
    ) -> Bool {
        guard let rhs else { return false }
        return runtimeIdentityKey(for: lhs) == runtimeIdentityKey(for: rhs)
    }

    private func userFacingMessage(for error: Error) -> String {
        userFacingErrorMessage(error)
    }

    func stopSessionManagerIfNeeded() {
        sessionManagerLauncher.stopManagedProcess()
    }
}
