import AppKit
import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func menuTrackingGateDefersRebuildUntilMenuCloses() {
    var gate = MenuTrackingGate()

    gate.beginTracking()
    #expect(gate.requestRebuild() == false)
    #expect(gate.hasPendingRebuild == true)
    #expect(gate.finishTracking() == true)
    #expect(gate.hasPendingRebuild == false)
}

@Test
func deferredMenuPresentationQueueDrainsAfterMenuCloses() {
    var queue = DeferredMenuPresentationQueue()
    queue.enqueue(.settings)
    queue.enqueue(.settings)

    #expect(queue.actions == [.settings])
    #expect(queue.drain() == [.settings])
    #expect(queue.actions.isEmpty)
}

@Test
func settingsAccountSectionsGroupAndSortAccountsForHumanScanning() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sections = buildSettingsAccountSections([
            SettingsAccountPresentationInput(
                id: "current",
                title: "current@example.com",
                authMode: .chatgpt,
                state: .healthy,
                isCurrent: true,
                lastUsedAt: now,
                host: nil,
                model: nil
            ),
            SettingsAccountPresentationInput(
                id: "healthy",
                title: "healthy@example.com",
                authMode: .chatgpt,
                state: .healthy,
                isCurrent: false,
                lastUsedAt: now.addingTimeInterval(-10),
                host: nil,
                model: nil
            ),
            SettingsAccountPresentationInput(
                id: "limited",
                title: "limited@example.com",
                authMode: .chatgpt,
                state: .limited,
                isCurrent: false,
                lastUsedAt: now.addingTimeInterval(-5),
                host: nil,
                model: nil
            ),
            SettingsAccountPresentationInput(
                id: "api",
                title: "api.example.com",
                authMode: .apiKey,
                state: .healthy,
                isCurrent: false,
                lastUsedAt: now.addingTimeInterval(-20),
                host: "api.example.com",
                model: "gpt-5.4"
            ),
        ])

        #expect(sections.map(\.title) == ["Current Account (1)", "ChatGPT Accounts (2)", "API Accounts (1)"])
        #expect(sections[0].items.map(\.id) == ["current"])
        #expect(sections[1].items.map(\.id) == ["healthy", "limited"])
        #expect(sections[2].items.map(\.id) == ["api"])
    }
}

@Test
func settingsAccountSectionsIncludeLocalizedHealthHints() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let sections = buildSettingsAccountSections([
            SettingsAccountPresentationInput(
                id: "attention",
                title: "attention@example.com",
                authMode: .chatgpt,
                state: .attention,
                isCurrent: false,
                lastUsedAt: nil,
                host: nil,
                model: nil
            ),
            SettingsAccountPresentationInput(
                id: "api",
                title: "api.example.com",
                authMode: .apiKey,
                state: .healthy,
                isCurrent: false,
                lastUsedAt: nil,
                host: "api.example.com",
                model: "gpt-5.4"
            ),
        ])

        #expect(sections[0].items[0].subtitle.contains("Needs attention"))
        #expect(sections[1].items[0].subtitle.contains("Healthy"))
    }
}

@Test
func settingsAccountPanelBuilderMarksCurrentAndAttentionStatesConsistently() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let currentProfile = makeMenuProfile(
            id: "current",
            displayName: "current@example.com",
            authMode: .chatgpt,
            snapshot: makeMenuSnapshot(
                email: "current@example.com",
                primaryRemaining: 81,
                secondaryRemaining: 79,
                fetchedAt: now
            ),
            isCurrent: true,
            lastUsedAt: now
        )
        let apiProfile = makeMenuProfile(
            id: "api",
            displayName: "api.example.com",
            authMode: .apiKey,
            snapshot: nil,
            isCurrent: false,
            lastUsedAt: now.addingTimeInterval(-20),
            healthStatus: .readFailure
        )

        let panelState = buildSettingsAccountPanelState(
            vaultSnapshot: AccountVaultSnapshot(
                accounts: [
                    makeVaultRecord(from: currentProfile),
                    makeVaultRecord(from: apiProfile),
                ]
            ),
            vaultProfiles: [apiProfile],
            currentProviderProfile: currentProfile,
            refreshIntervalPreset: RefreshIntervalPreset.fiveMinutes,
            actionsEnabled: false
        )

        #expect(panelState.importStatusText == "Local vault: 2 saved account(s)")
        #expect(panelState.actionsEnabled == false)
        #expect(panelState.sections.map(\.title) == ["Current Account (1)", "API Accounts (1)"])
        #expect(panelState.sections[0].items[0].isCurrent)
        #expect(panelState.sections[1].items[0].subtitle.contains("Needs attention"))
    }
}

@Test
func apiAutoConfigNormalizesURLAndChoosesGeneralPurposeModel() {
    let fallback = try! buildFallbackAPIAccountDraft(
        apiKey: "sk-test",
        rawBaseURL: "shell.wyzai.top"
    )

    #expect(fallback.displayName == "shell.wyzai.top")
    #expect(fallback.normalizedBaseURL == "https://shell.wyzai.top/v1")
    #expect(fallback.model == "gpt-5.4")

    let preferred = preferredModelID(
        from: [
            "text-embedding-3-large",
            "gpt-4o",
            "moderation-latest",
        ]
    )

    #expect(preferred == "gpt-4o")
}

@Test
func apiAutoConfigRejectsInvalidFallbackBaseURL() {
    #expect(throws: APIAccountAutoConfigurationError.invalidBaseURL) {
        try buildFallbackAPIAccountDraft(
            apiKey: "sk-test",
            rawBaseURL: "://bad-url"
        )
    }
}

@Test
func apiStatusTextUsesAPIAsPrimaryLabel() {
    let details = APIKeyProfileDetails(
        providerName: "openai",
        baseURL: "https://api.example.com/v1",
        model: "gpt-5.4",
        keyHint: "...1234"
    )

    let texts = apiKeyStatusTexts(details: details)

    #expect(texts.0 == "API")
    #expect(texts.1 == "gpt-5.4 · api.example.com · ...1234")
}

@Test
func allAccountsMenuItemPresentationUsesCurrentCheckmarkAndDirectSwitchForOthers() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let current = makeMenuProfile(
            id: "current",
            displayName: "current@example.com",
            authMode: .chatgpt,
            snapshot: makeMenuSnapshot(
                email: "current@example.com",
                primaryRemaining: 81,
                secondaryRemaining: 79,
                fetchedAt: now
            ),
            isCurrent: true,
            lastUsedAt: now
        )
        let other = makeMenuProfile(
            id: "other",
            displayName: "other@example.com",
            authMode: .chatgpt,
            snapshot: makeMenuSnapshot(
                email: "other@example.com",
                primaryRemaining: 77,
                secondaryRemaining: 73,
                fetchedAt: now
            ),
            isCurrent: false,
            lastUsedAt: now.addingTimeInterval(-20)
        )

        let currentItem = buildAllAccountsMenuItemPresentation(
            for: current,
            refreshIntervalPreset: .fiveMinutes,
            now: now,
            isPerformingSafeSwitchOperation: false
        )
        let otherItem = buildAllAccountsMenuItemPresentation(
            for: other,
            refreshIntervalPreset: .fiveMinutes,
            now: now,
            isPerformingSafeSwitchOperation: false
        )

        #expect(currentItem.showsCheckmark == true)
        #expect(currentItem.isEnabled == true)
        #expect(currentItem.triggersDirectSwitch == false)
        #expect(currentItem.title.contains("Selected") == false)

        #expect(otherItem.showsCheckmark == false)
        #expect(otherItem.isEnabled == true)
        #expect(otherItem.triggersDirectSwitch == true)
    }
}

@MainActor
@Test
func settingsWindowControllerInitializesForAccountsPanelState() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let state = SettingsAccountPanelState(
            importStatusText: "Local vault: 2 saved accounts",
            sections: [
                SettingsAccountSection(
                    title: "Current Account",
                    items: [
                        SettingsAccountItem(
                            id: "current",
                            title: "current@example.com",
                            subtitle: "ChatGPT · Stored in local vault",
                            isCurrent: true,
                            canActivate: false,
                            canRename: true,
                            canForget: false
                        )
                    ]
                ),
                SettingsAccountSection(
                    title: "API Accounts",
                    items: [
                        SettingsAccountItem(
                            id: "api",
                            title: "api.example.com",
                            subtitle: "API Key · Stored in local vault · api.example.com · gpt-5.4",
                            isCurrent: false,
                            canActivate: true,
                            canRename: true,
                            canForget: true
                        )
                    ]
                ),
            ],
            actionsEnabled: true
        )

        let controller = SettingsWindowController(
            settings: AppSettings(),
            accountPanelState: state
        )

        #expect(controller.window != nil)
        #expect(controller.window?.title == "Settings")
    }
}

@MainActor
@Test
func settingsWindowControllerSeparatesAccountsHeaderFromScrollableList() throws {
    let controller = SettingsWindowController(
        settings: AppSettings(),
        accountPanelState: SettingsAccountPanelState(
            importStatusText: "Local vault: 3 saved accounts",
            sections: [
                SettingsAccountSection(
                    title: "Current Account (1)",
                    items: [
                        SettingsAccountItem(
                            id: "current",
                            title: "current@example.com",
                            subtitle: "ChatGPT · Stored in local vault",
                            isCurrent: true,
                            canActivate: false,
                            canRename: true,
                            canForget: false
                        )
                    ]
                ),
                SettingsAccountSection(
                    title: "ChatGPT Accounts (2)",
                    items: [
                        SettingsAccountItem(
                            id: "a",
                            title: "a@example.com",
                            subtitle: "ChatGPT · Stored in local vault",
                            isCurrent: false,
                            canActivate: true,
                            canRename: true,
                            canForget: true
                        ),
                        SettingsAccountItem(
                            id: "b",
                            title: "b@example.com",
                            subtitle: "ChatGPT · Stored in local vault",
                            isCurrent: false,
                            canActivate: true,
                            canRename: true,
                            canForget: true
                        )
                    ]
                ),
            ],
            actionsEnabled: true
        )
    )

    let contentView = try #require(controller.window?.contentView)
    let tabView = try #require(findView(ofType: NSTabView.self, in: contentView))
    let accountsView = try #require(tabView.tabViewItems.last?.view)
    let header = try #require(findView(in: accountsView, identifier: "settings.accounts.header"))
    let scrollView = try #require(findView(in: accountsView, identifier: "settings.accounts.scroll") as? NSScrollView)

    #expect(scrollView.hasVerticalScroller)
    #expect(header !== scrollView)
    #expect(isDescendant(header, of: scrollView) == false)
    let tableView = try #require(findView(in: scrollView, identifier: "settings.accounts.table") as? NSTableView)
    controller.window?.layoutIfNeeded()
    accountsView.layoutSubtreeIfNeeded()
    #expect(tableView.numberOfRows == 5)
    #expect(scrollView.documentView === tableView)
    #expect(tableView.frame.height > 0)
}

@MainActor
@Test
func settingsWindowControllerRendersAccountsAfterLateUpdate() throws {
    let controller = SettingsWindowController(
        settings: AppSettings(),
        accountPanelState: SettingsAccountPanelState(
            importStatusText: "",
            sections: [],
            actionsEnabled: true
        )
    )

    let contentView = try #require(controller.window?.contentView)
    let tabView = try #require(findView(ofType: NSTabView.self, in: contentView))
    let accountsView = try #require(tabView.tabViewItems.last?.view)
    let scrollView = try #require(findView(in: accountsView, identifier: "settings.accounts.scroll") as? NSScrollView)
    let tableView = try #require(findView(in: scrollView, identifier: "settings.accounts.table") as? NSTableView)

    controller.update(
        settings: AppSettings(),
        accountPanelState: SettingsAccountPanelState(
            importStatusText: "Local vault: 2 saved accounts",
            sections: [
                SettingsAccountSection(
                    title: "Current Account (1)",
                    items: [
                        SettingsAccountItem(
                            id: "current",
                            title: "current@example.com",
                            subtitle: "ChatGPT · Stored in local vault",
                            isCurrent: true,
                            canActivate: false,
                            canRename: true,
                            canForget: false
                        )
                    ]
                ),
                SettingsAccountSection(
                    title: "ChatGPT Accounts (1)",
                    items: [
                        SettingsAccountItem(
                            id: "other",
                            title: "other@example.com",
                            subtitle: "ChatGPT · Stored in local vault",
                            isCurrent: false,
                            canActivate: true,
                            canRename: true,
                            canForget: true
                        )
                    ]
                ),
            ],
            actionsEnabled: true
        )
    )

    controller.window?.layoutIfNeeded()
    accountsView.layoutSubtreeIfNeeded()

    #expect(tableView.numberOfRows == 4)
    #expect(tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) != nil)
    #expect(tableView.view(atColumn: 0, row: 1, makeIfNecessary: true) != nil)
}

@MainActor
@Test
func settingsWindowControllerRelocalizesGeneralControlsAfterLanguageChange() throws {
    try withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        var settings = AppSettings()
        settings.appLanguage = .en

        let controller = SettingsWindowController(
            settings: settings,
            accountPanelState: SettingsAccountPanelState(importStatusText: "", sections: [], actionsEnabled: true)
        )

        let contentView = try #require(controller.window?.contentView)
        let refreshLabel = try #require(
            findView(in: contentView, identifier: "settings.general.refresh") as? NSTextField
        )
        let languageLabel = try #require(
            findView(in: contentView, identifier: "settings.general.language") as? NSTextField
        )
        let iconStyleLabel = try #require(
            findView(in: contentView, identifier: "settings.general.icon-style") as? NSTextField
        )

        #expect(refreshLabel.stringValue == "Refresh interval")
        #expect(languageLabel.stringValue == "Language")
        #expect(iconStyleLabel.stringValue == "Menu bar style")

        settings.appLanguage = .zh
        AppLocalization.setPreferredLanguage(.zh, preferredLanguages: ["zh-Hans-CN"])
        controller.update(
            settings: settings,
            accountPanelState: SettingsAccountPanelState(importStatusText: "", sections: [], actionsEnabled: true)
        )

        #expect(refreshLabel.stringValue == "刷新频率")
        #expect(languageLabel.stringValue == "语言")
        #expect(iconStyleLabel.stringValue == "状态栏样式")
    }
}

@MainActor
@Test
func applicationMainMenuIncludesStandardEditCommands() throws {
    try withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let mainMenu = makeApplicationMainMenu(appName: "Codex Quota Viewer")

        #expect(mainMenu.items.count >= 2)

        let appMenu = try #require(mainMenu.item(at: 0)?.submenu)
        let editMenu = try #require(mainMenu.item(at: 1)?.submenu)

        #expect(appMenu.items.contains(where: { $0.action == #selector(NSApplication.terminate(_:)) }))
        #expect(editMenu.items.contains(where: { $0.action == #selector(NSText.cut(_:)) }))
        #expect(editMenu.items.contains(where: { $0.action == #selector(NSText.copy(_:)) }))
        #expect(editMenu.items.contains(where: { $0.action == #selector(NSText.paste(_:)) }))
        #expect(editMenu.items.contains(where: { $0.action == #selector(NSText.selectAll(_:)) }))
    }
}

@MainActor
private func findView(in root: NSView, identifier: String) -> NSView? {
    if root.identifier?.rawValue == identifier {
        return root
    }

    for subview in root.subviews {
        if let match = findView(in: subview, identifier: identifier) {
            return match
        }
    }

    return nil
}

@MainActor
private func findView<T: NSView>(ofType type: T.Type, in root: NSView) -> T? {
    if let root = root as? T {
        return root
    }

    for subview in root.subviews {
        if let match: T = findView(ofType: type, in: subview) {
            return match
        }
    }

    return nil
}

@MainActor
private func isDescendant(_ view: NSView, of ancestor: NSView) -> Bool {
    var currentView = view.superview
    while currentView != nil {
        if currentView === ancestor {
            return true
        }
        currentView = currentView?.superview
    }
    return false
}

private func makeMenuProfile(
    id: String,
    displayName: String,
    authMode: CodexAuthMode,
    snapshot: CodexSnapshot?,
    isCurrent: Bool,
    lastUsedAt: Date?,
    healthStatus: ProfileHealthStatus = .healthy
) -> ProviderProfile {
    let authData: Data
    let configData: Data
    if authMode == .apiKey {
        authData = Data(#"{"OPENAI_API_KEY":"sk-\#(id)","auth_mode":"apikey"}"#.utf8)
        configData = Data(
            """
            model_provider = "openai"
            base_url = "https://api.example.com/v1"
            model = "gpt-5.4"
            """.utf8
        )
    } else {
        authData = Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"token-\#(id)"}}"#.utf8)
        configData = Data(#"model_provider = "openai""#.utf8)
    }

    return ProviderProfile(
        id: id,
        displayName: displayName,
        source: .vault,
        runtimeMaterial: ProfileRuntimeMaterial(authData: authData, configData: configData),
        authMode: authMode,
        providerID: "openai",
        providerDisplayName: authMode == .apiKey ? "openai" : nil,
        baseURLHost: authMode == .apiKey ? "api.example.com" : nil,
        model: authMode == .apiKey ? "gpt-5.4" : nil,
        snapshot: snapshot,
        healthStatus: healthStatus,
        errorMessage: nil,
        isCurrent: isCurrent,
        managedFileURLs: [],
        lastUsedAt: lastUsedAt
    )
}

private func makeVaultRecord(
    from profile: ProviderProfile
) -> VaultAccountRecord {
    let directoryURL = URL(fileURLWithPath: "/tmp/\(profile.id)", isDirectory: true)
    let metadata = VaultAccountMetadata(
        id: profile.id,
        displayName: profile.displayName,
        authMode: profile.authMode,
        providerID: profile.providerID,
        baseURL: profile.baseURLHost.map { "https://\($0)/v1" },
        model: profile.model,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastUsedAt: profile.lastUsedAt,
        source: .currentRuntime,
        runtimeKey: stableAccountIdentityKey(for: profile.runtimeMaterial)
    )
    return VaultAccountRecord(
        metadata: metadata,
        runtimeMaterial: profile.runtimeMaterial,
        directoryURL: directoryURL,
        metadataURL: directoryURL.appendingPathComponent("metadata.json"),
        authURL: directoryURL.appendingPathComponent("auth.json"),
        configURL: directoryURL.appendingPathComponent("config.toml")
    )
}

private func makeMenuSnapshot(
    email: String,
    primaryRemaining: Double,
    secondaryRemaining: Double,
    fetchedAt: Date
) -> CodexSnapshot {
    CodexSnapshot(
        account: CodexAccount(type: "chatgpt", email: email, planType: "plus"),
        rateLimits: RateLimitSnapshot(
            limitId: nil,
            limitName: nil,
            primary: RateLimitWindow(
                usedPercent: 100 - primaryRemaining,
                windowDurationMins: 300,
                resetsAt: 1_800_000_360
            ),
            secondary: RateLimitWindow(
                usedPercent: 100 - secondaryRemaining,
                windowDurationMins: 10_080,
                resetsAt: 1_800_086_400
            ),
            planType: "plus"
        ),
        fetchedAt: fetchedAt
    )
}
