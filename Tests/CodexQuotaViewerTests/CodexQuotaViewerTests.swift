import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func loadSettingsDefaultsWhenMissing() throws {
    let harness = try TestHarness()
    let result = harness.store.loadSettingsResult()

    #expect(result.settings == AppSettings())
    #expect(result.issues.isEmpty)
}

@Test
func saveAndLoadSettingsRoundTrip() throws {
    let harness = try TestHarness()
    let settings = AppSettings(
        refreshIntervalPreset: .oneMinute,
        launchAtLoginEnabled: true,
        statusItemStyle: .text
    )

    try harness.store.saveSettings(settings)

    let result = harness.store.loadSettingsResult()
    #expect(result.settings == settings)
    #expect(result.issues.isEmpty)
}

@Test
func currentRuntimeMaterialReadsAuthAndConfig() throws {
    let harness = try TestHarness()
    let authData = Data(#"{"access_token":"token"}"#.utf8)
    let configData = Data(#"model = "gpt-5""#.utf8)

    try harness.writeCurrentRuntime(authData: authData, configData: configData)

    let runtime = try harness.store.currentRuntimeMaterial()
    #expect(runtime.authData == authData)
    #expect(runtime.configData == configData)
}

@Test
func ccSwitchCodexStoreParsesLoggedInOrdinaryProvidersOnly() throws {
    let ordinarySettings = #"{"auth":{"access_token":"token-1","refresh_token":"refresh-1"},"config":"model = \"gpt-5\""}"#
    let apiKeySettings = #"{"auth":{"auth_mode":"apikey","OPENAI_API_KEY":"sk-test-1234"},"config":"model = \"gpt-5\""}"#
    let emptySettings = #"{"auth":{},"config":""}"#
    let output = [
        [hex("provider-1"), hex("Ordinary"), hex(ordinarySettings)].joined(separator: "\t"),
        [hex("provider-2"), hex("API"), hex(apiKeySettings)].joined(separator: "\t"),
        [hex("provider-3"), hex("Empty"), hex(emptySettings)].joined(separator: "\t"),
    ].joined(separator: "\n")

    let providers = CCSwitchCodexStore.parseProviders(from: output)

    #expect(providers.count == 1)
    #expect(providers[0].name == "Ordinary")
    #expect(
        String(data: providers[0].runtimeMaterial.authData, encoding: .utf8)
            == #"{"access_token":"token-1","refresh_token":"refresh-1"}"#
    )
}

@Test
func ccSwitchCodexStoreDeduplicatesSameRuntime() {
    let settings = #"{"auth":{"access_token":"token-1","refresh_token":"refresh-1"},"config":"model = \"gpt-5\""}"#
    let output = [
        [hex("provider-1"), hex("One"), hex(settings)].joined(separator: "\t"),
        [hex("provider-2"), hex("Two"), hex(settings)].joined(separator: "\t"),
    ].joined(separator: "\n")

    let providers = CCSwitchCodexStore.parseProviders(from: output)

    #expect(providers.count == 1)
    #expect(providers[0].name == "One")
}

@Test
func classifyProfileHealthMarksNotLoggedInAsNeedsLogin() {
    #expect(classifyProfileHealth(from: CodexRPCError.notLoggedIn) == .needsLogin)
}

@Test
func classifyProfileHealthMarksUnauthorizedRPCAsNeedsLogin() {
    #expect(classifyProfileHealth(from: CodexRPCError.rpc("401 unauthorized")) == .needsLogin)
}

@Test
func fallbackRateLimitsSnapshotAcceptsOpenAIAuthRequiredError() {
    let snapshot = fallbackRateLimitsSnapshot(
        requestID: "3",
        errorCode: -32600,
        message: "ChatGPT authentication required to read rate limits"
    )

    #expect(snapshot != nil)
    #expect(snapshot?.primary == nil)
    #expect(snapshot?.secondary == nil)
}

@Test
func resolveCurrentAccountCardStateMarksRefreshingBeforeSnapshotArrives() {
    let state = resolveCurrentAccountCardState(
        snapshot: nil,
        explicitHealth: nil,
        errorMessage: nil,
        isRefreshing: true
    )

    #expect(state == .refreshing)
}

@Test
func resolveCurrentAccountCardStatePrefersExplicitErrorOverRefreshing() {
    let state = resolveCurrentAccountCardState(
        snapshot: nil,
        explicitHealth: .needsLogin,
        errorMessage: "当前账号未登录或 auth.json 无效。",
        isRefreshing: true
    )

    #expect(state == .error(.needsLogin, "当前账号未登录或 auth.json 无效。"))
}

@Test
func resolveCurrentAccountCardStateReturnsEmptyWhenIdleWithoutSnapshot() {
    let state = resolveCurrentAccountCardState(
        snapshot: nil,
        explicitHealth: nil,
        errorMessage: nil,
        isRefreshing: false
    )

    #expect(state == .empty)
}

@Test
func buildVisibleMenuNoticesDeduplicatesAndPrefixesCurrentError() {
    let notices = buildVisibleMenuNotices(
        statusNotice: "已刷新",
        loadWarningNotice: "设置文件损坏",
        currentError: "超时"
    )

    #expect(notices == [
        MenuNotice(kind: .info, message: "已刷新"),
        MenuNotice(kind: .warning, message: "设置文件损坏"),
        MenuNotice(kind: .error, message: "当前刷新失败：超时"),
    ])
}

@Test
func buildMenuBlueprintIncludesCurrentSectionAndActionsWhenNoExternalAccounts() {
    let items = buildMenuBlueprint(
        notices: [],
        ccSwitchProfileNames: [],
        isRefreshing: false
    )

    #expect(items == [
        .sectionHeader("当前账号"),
        .currentAccount,
        .separator,
        .action(title: "刷新全部", isEnabled: true),
        .action(title: "设置…", isEnabled: true),
        .action(title: "退出", isEnabled: true),
    ])
}

@Test
func buildMenuBlueprintPlacesNoticesAndCCSwitchSectionBeforeActions() {
    let items = buildMenuBlueprint(
        notices: [
            MenuNotice(kind: .warning, message: "CC Switch 读取失败"),
        ],
        ccSwitchProfileNames: ["team@example.com", "backup@example.com"],
        isRefreshing: true
    )

    #expect(items == [
        .notice(MenuNotice(kind: .warning, message: "CC Switch 读取失败")),
        .separator,
        .sectionHeader("当前账号"),
        .currentAccount,
        .separator,
        .sectionHeader("CC Switch 账号"),
        .ccSwitchAccount("team@example.com"),
        .ccSwitchAccount("backup@example.com"),
        .separator,
        .action(title: "刷新中…", isEnabled: false),
        .action(title: "设置…", isEnabled: true),
        .action(title: "退出", isEnabled: true),
    ])
}

@Test
func loadSettingsMigratesLegacySupportDirectory() throws {
    let harness = try TestHarness()
    let legacyBaseURL = harness.rootURL
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("CodexAccountSwitcher", isDirectory: true)
    let newBaseURL = harness.rootURL
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent(AppIdentity.supportDirectoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: legacyBaseURL, withIntermediateDirectories: true)
    let legacySettings = AppSettings(
        refreshIntervalPreset: .fiveMinutes,
        launchAtLoginEnabled: true,
        statusItemStyle: .meter
    )
    let data = try JSONEncoder().encode(legacySettings)
    try data.write(to: legacyBaseURL.appendingPathComponent("settings.json"), options: .atomic)

    let store = ProfileStore(
        baseURL: nil,
        currentAuthURL: harness.store.currentAuthURL,
        homeDirectoryOverride: harness.rootURL
    )
    let result = store.loadSettingsResult()

    #expect(result.settings == legacySettings)
    #expect(FileManager.default.fileExists(atPath: newBaseURL.path))
}

private final class TestHarness {
    let rootURL: URL
    let store: ProfileStore

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexQuotaViewerTests-\(UUID().uuidString)", isDirectory: true)

        let homeURL = rootURL
        let baseURL = rootURL.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let currentAuthURL = rootURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)

        store = ProfileStore(
            baseURL: baseURL,
            currentAuthURL: currentAuthURL,
            homeDirectoryOverride: homeURL
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func writeCurrentRuntime(authData: Data, configData: Data?) throws {
        let directoryURL = store.currentAuthURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try authData.write(to: store.currentAuthURL, options: .atomic)
        if let configData {
            try configData.write(to: store.currentConfigURL, options: .atomic)
        }
    }
}

private func hex(_ value: String) -> String {
    value.utf8.map { String(format: "%02x", $0) }.joined()
}
