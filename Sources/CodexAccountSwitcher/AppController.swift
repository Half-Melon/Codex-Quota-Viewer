import AppKit
import Foundation

@MainActor
final class AppController: NSObject, NSMenuDelegate {
    private let store: ProfileStore
    private let rpcClient: CodexRPCClient
    private let appManager: CodexAppManager
    private let launchAtLoginManager = LaunchAtLoginManager()
    private let statusItemRenderer = StatusItemRenderer()
    private lazy var switchService = ProfileSwitchService(
        store: store,
        rpcClient: rpcClient,
        appManager: appManager
    )

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var profiles: [CodexProfile] = []
    private var settings = AppSettings(lastActiveProfileID: nil)
    private var currentSnapshot: CodexSnapshot?
    private var currentError: String?
    private var profileErrors: [UUID: String] = [:]
    private var profileHealthStatuses: [UUID: ProfileHealthStatus] = [:]
    private var isRefreshing = false
    private var isSwitching = false
    private var statusNotice: String?
    private var loadWarningNotice: String?
    private var lastRefreshAt: Date?
    private var refreshTimer: Timer?
    private var settingsWindowController: SettingsWindowController?

    override init() {
        store = ProfileStore()
        rpcClient = CodexRPCClient()
        appManager = CodexAppManager()
        super.init()
    }

    func start() {
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.title = "CX"

        runMigrationIfNeeded()
        reloadLocalState()
        applySettingsSideEffects(showErrorsInStatus: false)
        rebuildMenu()
        refreshAllProfiles()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshAllProfiles()
    }

    private func runMigrationIfNeeded() {
        let settingsResult = store.loadSettingsResult()
        var currentSettings = settingsResult.settings
        let migrationResult = store.migrateLegacyCredentialsIfNeeded(settings: &currentSettings)

        settings = currentSettings
        try? store.saveSettings(settings)

        let issues = settingsResult.issues.map(\.message)
        loadWarningNotice = issues.isEmpty ? nil : issues.joined(separator: "；")

        if !migrationResult.errors.isEmpty {
            statusNotice = migrationResult.errors.joined(separator: "；")
        } else if migrationResult.migratedCount > 0 {
            statusNotice = "已迁移 \(migrationResult.migratedCount) 项旧数据"
        }
    }

    private func reloadLocalState() {
        let profilesResult = store.loadProfilesResult()
        let settingsResult = store.loadSettingsResult()

        profiles = profilesResult.profiles
        settings = settingsResult.settings

        let issues = (profilesResult.issues + settingsResult.issues).map(\.message)
        loadWarningNotice = issues.isEmpty ? nil : issues.joined(separator: "；")
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
        guard !isRefreshing, !isSwitching else { return }

        isRefreshing = true
        currentError = nil
        profileErrors = [:]
        profileHealthStatuses = [:]
        updateStatusTitle()
        rebuildMenu()

        Task {
            defer {
                isRefreshing = false
                updateStatusTitle()
                rebuildMenu()
            }

            reloadLocalState()

            do {
                let snapshot = try await rpcClient.fetchCurrentSnapshot()
                currentSnapshot = snapshot
                syncFallbackActiveProfileIfNeeded(using: snapshot)
                syncCurrentSnapshotIntoActiveProfileCache(snapshot)
                if let activeID = resolvedActiveProfileID(currentSnapshot: snapshot) {
                    profileHealthStatuses[activeID] = .healthy
                }
            } catch {
                currentSnapshot = nil
                currentError = userFacingMessage(for: error)
                if let activeID = resolvedActiveProfileID() {
                    profileHealthStatuses[activeID] = classifyProfileHealth(from: error)
                    profileErrors[activeID] = userFacingMessage(for: error)
                }
            }

            let activeID = resolvedActiveProfileID()

            for profile in profiles {
                if activeID == profile.id, currentSnapshot != nil {
                    continue
                }

                do {
                    let authData = try store.readAuthData(for: profile.id)
                    let snapshot = try await rpcClient.fetchSnapshot(authData: authData)
                    try store.updateProfile(id: profile.id, snapshot: snapshot.cached)
                    profileHealthStatuses[profile.id] = .healthy

                    if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                        profiles[index].cachedSnapshot = snapshot.cached
                        profiles[index].updatedAt = Date()
                    }
                } catch {
                    profileHealthStatuses[profile.id] = classifyProfileHealth(from: error)
                    profileErrors[profile.id] = userFacingMessage(for: error)
                }

                rebuildMenu()
            }

            lastRefreshAt = Date()
        }
    }

    private func syncFallbackActiveProfileIfNeeded(using snapshot: CodexSnapshot) {
        let resolved = resolveActiveProfileID(
            lastActiveProfileID: settings.lastActiveProfileID,
            profiles: profiles,
            currentSnapshot: snapshot
        )

        guard resolved != settings.lastActiveProfileID else {
            return
        }

        settings.lastActiveProfileID = resolved
        try? store.saveSettings(settings)
    }

    private func syncCurrentSnapshotIntoActiveProfileCache(_ snapshot: CodexSnapshot) {
        guard let activeID = resolvedActiveProfileID() else { return }

        try? store.updateProfile(id: activeID, snapshot: snapshot.cached)
        if let index = profiles.firstIndex(where: { $0.id == activeID }) {
            profiles[index].cachedSnapshot = snapshot.cached
            profiles[index].updatedAt = Date()
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        addDisabledItem(currentAccountLine())
        addDisabledItem(currentUsageLine())
        addDisabledItem(currentStatusLine())

        menu.addItem(.separator())

        let refreshTitle = isRefreshing ? "刷新中…" : "刷新全部"
        addActionItem(title: refreshTitle, action: #selector(refreshTapped), enabled: !isRefreshing && !isSwitching)
        addActionItem(
            title: "从当前会话创建档案…",
            action: #selector(createProfileTapped),
            enabled: currentSnapshot != nil && !isSwitching
        )
        addActionItem(
            title: "更新当前档案",
            action: #selector(updateCurrentProfileTapped),
            enabled: resolvedActiveProfileID() != nil && currentSnapshot != nil && !isSwitching
        )
        addActionItem(
            title: "重命名档案…",
            action: #selector(renameProfileTapped),
            enabled: !profiles.isEmpty && !isSwitching
        )
        addActionItem(
            title: "删除档案…",
            action: #selector(deleteProfileTapped),
            enabled: !profiles.isEmpty && !isSwitching
        )
        addActionItem(
            title: "设置…",
            action: #selector(openSettingsTapped),
            enabled: !isSwitching
        )

        menu.addItem(.separator())

        if profiles.isEmpty {
            addDisabledItem("还没有档案")
        } else {
            for profile in profiles {
                let item = NSMenuItem(
                    title: profileMenuTitle(for: profile),
                    action: #selector(switchProfileTapped(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = profile.id.uuidString
                item.state = resolvedActiveProfileID() == profile.id ? .on : .off
                item.isEnabled = !isSwitching
                item.toolTip = profileTooltip(for: profile)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        addActionItem(title: "打开档案目录", action: #selector(openProfilesDirectoryTapped), enabled: true)
        addActionItem(title: "退出", action: #selector(quitTapped), enabled: true)
    }

    private func currentAccountLine() -> String {
        if let currentSnapshot {
            let activeHealth = resolvedActiveProfileID().flatMap { profileHealthStatuses[$0] } ?? .healthy
            return "当前账号：\(currentSnapshot.account.displayLabel) · \(activeHealth.label)"
        }

        return "当前账号：未读取到"
    }

    private func currentUsageLine() -> String {
        guard let currentSnapshot else {
            return "剩余：-"
        }

        return "剩余：\(preciseUsageSummary(from: currentSnapshot.rateLimits) ?? "-")"
    }

    private func currentStatusLine() -> String {
        if let statusNotice, !statusNotice.isEmpty {
            return "状态：\(statusNotice)"
        }

        if let loadWarningNotice, !loadWarningNotice.isEmpty {
            return "状态：\(loadWarningNotice)"
        }

        if let currentError, !currentError.isEmpty {
            return "状态：\(currentError)"
        }

        if isSwitching {
            return "状态：切换中…"
        }

        if isRefreshing {
            return "状态：刷新中…"
        }

        if let lastRefreshAt {
            return "最近刷新：\(formatDateTime(lastRefreshAt, includesSeconds: true))"
        }

        return "最近刷新：-"
    }

    private func profileMenuTitle(for profile: CodexProfile) -> String {
        let health = profileHealthStatuses[profile.id] ?? .healthy
        let usage = usageSummary(from: profile.cachedSnapshot?.rateLimits) ?? {
            profileErrors[profile.id] == nil ? "未读取" : "读取失败"
        }()
        return "\(profile.name) · \(health.label) · \(usage)"
    }

    private func profileTooltip(for profile: CodexProfile) -> String {
        let account = profile.cachedSnapshot?.account.displayLabel ?? "未知账号"
        let health = profileHealthStatuses[profile.id] ?? .healthy
        let usage = preciseUsageSummary(from: profile.cachedSnapshot?.rateLimits) ?? "没有额度数据"
        let refreshedAt: String
        if let fetchedAt = profile.cachedSnapshot?.fetchedAt {
            refreshedAt = "最后刷新：\(formatDateTime(fetchedAt, includesSeconds: true))"
        } else {
            refreshedAt = "最后刷新：-"
        }

        var lines = [account, "状态：\(health.label)", usage, refreshedAt]
        if let error = profileErrors[profile.id] {
            lines.append("错误：\(error)")
        }
        return lines.joined(separator: "\n")
    }

    private func usageSummary(from snapshot: RateLimitSnapshot?) -> String? {
        guard let snapshot else { return nil }
        let primary = shortWindowSummary(window: snapshot.primary, fallbackLabel: "5h")
        let secondary = shortWindowSummary(window: snapshot.secondary, fallbackLabel: "1w")
        return "\(primary) / \(secondary)"
    }

    private func preciseUsageSummary(from snapshot: RateLimitSnapshot?) -> String? {
        guard let snapshot else { return nil }
        let primary = preciseWindowSummary(window: snapshot.primary, fallbackLabel: "5h")
        let secondary = preciseWindowSummary(window: snapshot.secondary, fallbackLabel: "1w")
        return "\(primary) / \(secondary)"
    }

    private func compactUsageSummary(from snapshot: RateLimitSnapshot?) -> String? {
        guard let snapshot else { return nil }
        let primary = compactWindowSummary(window: snapshot.primary, fallbackLabel: "5h")
        let secondary = compactWindowSummary(window: snapshot.secondary, fallbackLabel: "1w")
        return "\(primary) \(secondary)"
    }

    private func shortWindowSummary(window: RateLimitWindow?, fallbackLabel: String) -> String {
        guard let window else { return "\(fallbackLabel) -" }
        return "\(fallbackLabel) 剩余\(window.remainingPercentText)"
    }

    private func preciseWindowSummary(window: RateLimitWindow?, fallbackLabel: String) -> String {
        guard let window else { return "\(fallbackLabel) -" }

        if let resetDate = window.resetDate {
            return "\(fallbackLabel) 剩余\(window.remainingPercentText) · \(formatDateTime(resetDate, includesSeconds: false))"
        }

        return "\(fallbackLabel) 剩余\(window.remainingPercentText)"
    }

    private func compactWindowSummary(window: RateLimitWindow?, fallbackLabel: String) -> String {
        guard let window else { return "\(fallbackLabel)-" }
        return "\(fallbackLabel)\(window.remainingPercentText)"
    }

    private func resolvedActiveProfileID(currentSnapshot snapshot: CodexSnapshot? = nil) -> UUID? {
        resolveActiveProfileID(
            lastActiveProfileID: settings.lastActiveProfileID,
            profiles: profiles,
            currentSnapshot: snapshot ?? currentSnapshot
        )
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }

        switch settings.statusItemStyle {
        case .text:
            button.image = statusItemRenderer.makeBrandImage(for: button.effectiveAppearance)
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleNone

            let title: String
            if let currentSnapshot,
               let usageSummary = compactUsageSummary(from: currentSnapshot.rateLimits) {
                title = usageSummary
            } else if isSwitching {
                title = "切换中"
            } else if isRefreshing {
                title = "刷新中"
            } else if currentError != nil {
                title = "读取失败"
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

            let primaryRemaining = currentSnapshot?.rateLimits.primary?.remainingPercent ?? 0
            let secondaryRemaining = currentSnapshot?.rateLimits.secondary?.remainingPercent ?? 0
            button.image = statusItemRenderer.makeMeterImage(
                primaryRemaining: primaryRemaining / 100,
                secondaryRemaining: secondaryRemaining / 100,
                state: currentMeterIconState()
            )
        }
    }

    private func currentMeterIconState() -> MeterIconState {
        if currentError != nil {
            return .degraded
        }

        if let activeID = resolvedActiveProfileID(),
           let health = profileHealthStatuses[activeID],
           !health.isHealthy {
            return .degraded
        }

        if isDataStale {
            return .stale
        }

        return .normal
    }

    private var isDataStale: Bool {
        guard let interval = settings.refreshIntervalPreset.interval,
              let lastRefreshAt else {
            return false
        }

        return Date().timeIntervalSince(lastRefreshAt) > interval * 1.5
    }

    private func addDisabledItem(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addActionItem(title: String, action: Selector, enabled: Bool) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    private func promptForProfileName(
        title: String,
        informativeText: String,
        defaultValue: String
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informativeText
        alert.alertStyle = .informational
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = defaultValue
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func promptForProfileSelection(
        title: String,
        informativeText: String,
        confirmTitle: String
    ) -> CodexProfile? {
        guard !profiles.isEmpty else { return nil }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informativeText
        alert.alertStyle = .informational
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "取消")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        for profile in profiles {
            popup.addItem(withTitle: profile.name)
            popup.lastItem?.representedObject = profile.id.uuidString
        }

        if let activeID = resolvedActiveProfileID(),
           let index = profiles.firstIndex(where: { $0.id == activeID }) {
            popup.selectItem(at: index)
        }

        alert.accessoryView = popup

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn,
              let selectedItem = popup.selectedItem,
              let rawID = selectedItem.representedObject as? String,
              let profileID = UUID(uuidString: rawID) else {
            return nil
        }

        return profiles.first(where: { $0.id == profileID })
    }

    @objc
    private func refreshTapped() {
        refreshAllProfiles()
    }

    @objc
    private func createProfileTapped() {
        guard let currentSnapshot else { return }

        let defaultName = currentSnapshot.account.email ?? "Codex 档案"
        guard let name = promptForProfileName(
            title: "新建档案",
            informativeText: "输入一个容易辨认的名字。",
            defaultValue: defaultName
        ) else {
            return
        }

        do {
            let authData = try store.currentAuthData()
            let profile = try store.createProfile(
                name: name,
                authData: authData,
                snapshot: currentSnapshot.cached
            )

            settings.lastActiveProfileID = profile.id
            try store.saveSettings(settings)

            statusNotice = "已保存档案：\(profile.name)"
            reloadLocalState()
            rebuildMenu()
            updateStatusTitle()
        } catch {
            statusNotice = userFacingMessage(for: error)
            rebuildMenu()
        }
    }

    @objc
    private func updateCurrentProfileTapped() {
        guard let activeID = resolvedActiveProfileID(),
              let currentSnapshot else {
            return
        }

        do {
            let authData = try store.currentAuthData()
            try store.updateProfile(
                id: activeID,
                authData: authData,
                snapshot: currentSnapshot.cached
            )

            if let index = profiles.firstIndex(where: { $0.id == activeID }) {
                profiles[index].cachedSnapshot = currentSnapshot.cached
                profiles[index].updatedAt = Date()
                statusNotice = "已更新档案：\(profiles[index].name)"
            } else {
                statusNotice = "已更新当前档案"
            }

            reloadLocalState()
            rebuildMenu()
        } catch {
            statusNotice = userFacingMessage(for: error)
            rebuildMenu()
        }
    }

    @objc
    private func renameProfileTapped() {
        guard let profile = promptForProfileSelection(
            title: "重命名档案",
            informativeText: "选择要重命名的档案。",
            confirmTitle: "继续"
        ) else {
            return
        }

        guard let newName = promptForProfileName(
            title: "重命名档案",
            informativeText: "给档案一个更清晰的名字。",
            defaultValue: profile.name
        ) else {
            return
        }

        do {
            try store.updateProfile(id: profile.id, name: newName)
            statusNotice = "已重命名：\(profile.name) -> \(newName)"
            reloadLocalState()
            rebuildMenu()
        } catch {
            statusNotice = userFacingMessage(for: error)
            rebuildMenu()
        }
    }

    @objc
    private func deleteProfileTapped() {
        guard let profile = promptForProfileSelection(
            title: "删除档案",
            informativeText: "选择要删除的档案。删除后会同时移除 Keychain 凭据。",
            confirmTitle: "删除"
        ) else {
            return
        }

        do {
            try store.deleteProfile(id: profile.id)
            if settings.lastActiveProfileID == profile.id {
                settings.lastActiveProfileID = nil
                try? store.saveSettings(settings)
            }

            statusNotice = "已删除档案：\(profile.name)"
            reloadLocalState()
            rebuildMenu()
        } catch {
            statusNotice = userFacingMessage(for: error)
            rebuildMenu()
        }
    }

    @objc
    private func switchProfileTapped(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let profileID = UUID(uuidString: idString),
              let profile = profiles.first(where: { $0.id == profileID }) else {
            return
        }

        if resolvedActiveProfileID() == profile.id {
            statusNotice = "当前已经是 \(profile.name)"
            rebuildMenu()
            return
        }

        isSwitching = true
        statusNotice = "正在切换到 \(profile.name)…"
        rebuildMenu()
        updateStatusTitle()

        Task {
            defer {
                isSwitching = false
                rebuildMenu()
                updateStatusTitle()
            }

            do {
                let result = try await switchService.switchToProfile(
                    targetProfile: profile,
                    activeProfileID: resolvedActiveProfileID(),
                    currentSnapshot: currentSnapshot,
                    autoOpenCodexAfterSwitch: settings.autoOpenCodexAfterSwitch
                )

                try store.updateProfile(
                    id: profile.id,
                    snapshot: result.verifiedSnapshot.cached
                )

                currentSnapshot = result.verifiedSnapshot
                settings.lastActiveProfileID = profile.id
                try? store.saveSettings(settings)

                statusNotice = "已切换到 \(profile.name)"
                lastRefreshAt = Date()

                reloadLocalState()
                refreshAllProfiles()
            } catch {
                statusNotice = userFacingMessage(for: error)
            }
        }
    }

    @objc
    private func openSettingsTapped() {
        if settingsWindowController == nil {
            let controller = SettingsWindowController(settings: settings)
            controller.onSettingsChanged = { [weak self] updatedSettings in
                guard let self else { return }
                self.settings = updatedSettings
                do {
                    try self.store.saveSettings(updatedSettings)
                } catch {
                    self.statusNotice = self.userFacingMessage(for: error)
                }
                self.applySettingsSideEffects(showErrorsInStatus: true)
            }
            settingsWindowController = controller
        }

        settingsWindowController?.update(settings: settings)
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func openProfilesDirectoryTapped() {
        NSWorkspace.shared.open(store.profilesDirectoryURL)
    }

    @objc
    private func quitTapped() {
        NSApplication.shared.terminate(nil)
    }

    private func formatDateTime(_ date: Date, includesSeconds: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .day)
            ? (includesSeconds ? "HH:mm:ss" : "HH:mm")
            : (includesSeconds ? "MM-dd HH:mm:ss" : "MM-dd HH:mm")
        return formatter.string(from: date)
    }

    private func userFacingMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
