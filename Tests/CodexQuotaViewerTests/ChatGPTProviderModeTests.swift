import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func chatGPTProviderModeAuthPreservesChatGPTTokensAndClearsAPIKey() throws {
    let input = Data(
        """
        {"OPENAI_API_KEY":"sk-old","auth_mode":"apikey","last_refresh":"2026-05-16T00:00:00Z","tokens":{"access_token":"token-1","account_id":"acct-1"}}
        """.utf8
    )

    let output = try chatGPTProviderModeAuthData(from: input)
    let object = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
    let tokens = try #require(object["tokens"] as? [String: Any])

    #expect(object["auth_mode"] as? String == "chatgpt")
    #expect(object.keys.contains("OPENAI_API_KEY"))
    #expect(object["OPENAI_API_KEY"] is NSNull)
    #expect(object["last_refresh"] as? String == "2026-05-16T00:00:00Z")
    #expect(tokens["access_token"] as? String == "token-1")
    #expect(tokens["account_id"] as? String == "acct-1")
}

@Test
func chatGPTProviderModeConfigUsesTutorialOpenAIProviderShape() throws {
    let record = makeChatGPTProviderModeAPIRecord(
        displayName: "Third Party",
        apiKey: "sk-third-party",
        baseURL: "https://proxy.example.com",
        model: "gpt-5.4"
    )

    let configData = try chatGPTProviderModeConfigData(from: record)
    let text = try configData.utf8String()

    #expect(text.contains("model_provider = \"OpenAI\""))
    #expect(text.contains("model = \"gpt-5.4\""))
    #expect(text.contains("[model_providers.OpenAI]"))
    #expect(text.contains("name = \"OpenAI\""))
    #expect(text.contains("base_url = \"https://proxy.example.com/v1\""))
    #expect(text.contains("wire_api = \"responses\""))
    #expect(text.contains("experimental_bearer_token = \"sk-third-party\""))
    #expect(text.contains("requires_openai_auth = true"))
}

@MainActor
@Test
func chatGPTProviderModeManagerEntersWithBackupAndRestoresOnExit() async throws {
    let harness = try makeHarness()
    let store = ProfileStore(
        baseURL: harness.appSupportURL,
        currentAuthURL: harness.codexHomeURL.appendingPathComponent("auth.json"),
        homeDirectoryOverride: harness.homeURL
    )
    try FileManager.default.createDirectory(at: harness.codexHomeURL, withIntermediateDirectories: true)

    let originalAuth = Data(
        """
        {"auth_mode":"chatgpt","last_refresh":"2026-05-16T00:00:00Z","tokens":{"access_token":"token-1","account_id":"acct-1"}}
        """.utf8
    )
    let originalConfig = Data(
        """
        personality = "pragmatic"
        model_provider = "openai"
        """.utf8
    )
    try originalAuth.write(to: store.currentAuthURL, options: .atomic)
    try originalConfig.write(to: store.currentConfigURL, options: .atomic)

    let desktop = ProviderModeDesktopControllerSpy(isRunning: true)
    let invalidator = ProviderModeChannelInvalidatorSpy()
    let manager = ChatGPTProviderModeManager(
        store: store,
        backupManager: makeBackupManager(harness),
        desktopController: desktop,
        quotaChannelInvalidator: invalidator
    )
    let record = makeChatGPTProviderModeAPIRecord(
        displayName: "Third Party",
        apiKey: "sk-third-party",
        baseURL: "https://proxy.example.com/v1",
        model: "gpt-5.4"
    )

    let enterResult = try await manager.enter(providerRecord: record)

    let modeState = try #require(try manager.currentModeState())
    #expect(modeState.providerAccountID == record.id)
    #expect(modeState.restorePointID == enterResult.restorePoint.id)
    #expect(enterResult.restorePoint.reason == "chatgpt-provider-mode")
    #expect(try manager.isActive())
    #expect(desktop.closeInvocationCount == 1)
    #expect(desktop.reopenInvocationCount == 1)
    #expect(await invalidator.invalidateAllCount == 1)

    let enteredAuth = try Data(contentsOf: store.currentAuthURL)
    let enteredAuthObject = try #require(JSONSerialization.jsonObject(with: enteredAuth) as? [String: Any])
    #expect(enteredAuthObject["auth_mode"] as? String == "chatgpt")
    #expect(enteredAuthObject["OPENAI_API_KEY"] is NSNull)

    let enteredConfig = try Data(contentsOf: store.currentConfigURL).utf8String()
    #expect(enteredConfig.contains("personality = \"pragmatic\""))
    #expect(enteredConfig.contains("model_provider = \"OpenAI\""))
    #expect(enteredConfig.contains("experimental_bearer_token = \"sk-third-party\""))

    let exitResult = try await manager.exit()

    #expect(exitResult.restorePoint.id == enterResult.restorePoint.id)
    #expect(try manager.currentModeState() == nil)
    #expect(desktop.closeInvocationCount == 2)
    #expect(desktop.reopenInvocationCount == 2)
    #expect(await invalidator.invalidateAllCount == 2)
    #expect(try Data(contentsOf: store.currentAuthURL) == originalAuth)
    #expect(try Data(contentsOf: store.currentConfigURL) == originalConfig)
}

@MainActor
@Test
func chatGPTProviderModeExitRestoresRecordedRestorePointWhenNewerBackupExists() async throws {
    let harness = try makeHarness()
    let store = ProfileStore(
        baseURL: harness.appSupportURL,
        currentAuthURL: harness.codexHomeURL.appendingPathComponent("auth.json"),
        homeDirectoryOverride: harness.homeURL
    )
    try FileManager.default.createDirectory(at: harness.codexHomeURL, withIntermediateDirectories: true)

    let originalAuth = Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"token-1","account_id":"acct-1"}}"#.utf8)
    let originalConfig = Data("model_provider = \"openai\"\n".utf8)
    try originalAuth.write(to: store.currentAuthURL, options: .atomic)
    try originalConfig.write(to: store.currentConfigURL, options: .atomic)

    let backupManager = makeBackupManager(harness)
    let manager = ChatGPTProviderModeManager(
        store: store,
        backupManager: backupManager,
        desktopController: ProviderModeDesktopControllerSpy(isRunning: false),
        quotaChannelInvalidator: ProviderModeChannelInvalidatorSpy()
    )
    let record = makeChatGPTProviderModeAPIRecord(
        displayName: "Third Party",
        apiKey: "sk-third-party",
        baseURL: "https://proxy.example.com/v1",
        model: "gpt-5.4"
    )

    let enterResult = try await manager.enter(providerRecord: record)
    let unrelatedURL = harness.codexHomeURL.appendingPathComponent("unrelated.txt", isDirectory: false)
    try Data("newer backup".utf8).write(to: unrelatedURL, options: .atomic)
    let newerRestorePoint = try backupManager.createRestorePoint(
        reason: "newer",
        summary: "newer backup",
        files: [unrelatedURL],
        codexWasRunning: false
    )

    #expect(newerRestorePoint.id != enterResult.restorePoint.id)

    let exitResult = try await manager.exit()

    #expect(exitResult.restorePoint.id == enterResult.restorePoint.id)
    #expect(try Data(contentsOf: store.currentAuthURL) == originalAuth)
    #expect(try Data(contentsOf: store.currentConfigURL) == originalConfig)
}

@MainActor
@Test
func chatGPTProviderModeEnterSynchronizesRolloutsAndRepairsOfficialThreads() async throws {
    let harness = try makeHarness()
    let store = ProfileStore(
        baseURL: harness.appSupportURL,
        currentAuthURL: harness.codexHomeURL.appendingPathComponent("auth.json"),
        homeDirectoryOverride: harness.homeURL
    )
    try FileManager.default.createDirectory(at: harness.codexHomeURL, withIntermediateDirectories: true)
    try Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"token-1","account_id":"acct-1"}}"#.utf8)
        .write(to: store.currentAuthURL, options: .atomic)
    try Data("model_provider = \"openai\"\n".utf8)
        .write(to: store.currentConfigURL, options: .atomic)
    let rolloutURL = try writeProviderModeRollout(
        under: store.sessionsRootURL,
        id: "existing-session",
        provider: "openai"
    )

    let repairer = ProviderModeRepairerSpy()
    let manager = ChatGPTProviderModeManager(
        store: store,
        backupManager: makeBackupManager(harness),
        rolloutSynchronizer: RolloutProviderSynchronizer(),
        repairClient: repairer,
        desktopController: ProviderModeDesktopControllerSpy(isRunning: false),
        quotaChannelInvalidator: ProviderModeChannelInvalidatorSpy()
    )
    let record = makeChatGPTProviderModeAPIRecord(
        displayName: "Third Party",
        apiKey: "sk-third-party",
        baseURL: "https://proxy.example.com/v1",
        model: "gpt-5.4"
    )

    let result = try await manager.enter(providerRecord: record)

    #expect(result.updatedRolloutCount == 1)
    #expect(repairer.invocationCount == 1)
    #expect(try readProviderModeRolloutProvider(from: rolloutURL) == "OpenAI")
    #expect(result.restorePoint.files.contains { $0.originalPath == rolloutURL.standardizedFileURL.path })
}

@MainActor
@Test
func chatGPTProviderModeExitRestoresRolloutProviderMetadata() async throws {
    let harness = try makeHarness()
    let store = ProfileStore(
        baseURL: harness.appSupportURL,
        currentAuthURL: harness.codexHomeURL.appendingPathComponent("auth.json"),
        homeDirectoryOverride: harness.homeURL
    )
    try FileManager.default.createDirectory(at: harness.codexHomeURL, withIntermediateDirectories: true)
    try Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"token-1","account_id":"acct-1"}}"#.utf8)
        .write(to: store.currentAuthURL, options: .atomic)
    try Data("model_provider = \"openai\"\n".utf8)
        .write(to: store.currentConfigURL, options: .atomic)
    let rolloutURL = try writeProviderModeRollout(
        under: store.sessionsRootURL,
        id: "existing-session",
        provider: "openai"
    )

    let manager = ChatGPTProviderModeManager(
        store: store,
        backupManager: makeBackupManager(harness),
        rolloutSynchronizer: RolloutProviderSynchronizer(),
        repairClient: ProviderModeRepairerSpy(),
        desktopController: ProviderModeDesktopControllerSpy(isRunning: false),
        quotaChannelInvalidator: ProviderModeChannelInvalidatorSpy()
    )
    let record = makeChatGPTProviderModeAPIRecord(
        displayName: "Third Party",
        apiKey: "sk-third-party",
        baseURL: "https://proxy.example.com/v1",
        model: "gpt-5.4"
    )

    _ = try await manager.enter(providerRecord: record)
    #expect(try readProviderModeRolloutProvider(from: rolloutURL) == "OpenAI")

    _ = try await manager.exit()

    #expect(try readProviderModeRolloutProvider(from: rolloutURL) == "openai")
}

@Test
func activeChatGPTProviderModeUsesRuntimeConfigAsExpectedThreadProvider() {
    let runtime = ProfileRuntimeMaterial(
        authData: Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"token-1","account_id":"acct-1"}}"#.utf8),
        configData: synthesizedChatGPTProviderModeConfig(
            baseURL: "https://proxy.example.com/v1",
            apiKey: "sk-third-party",
            model: "gpt-5.4"
        )
    )
    let profile = buildProviderProfile(
        id: "current",
        fallbackDisplayName: "Current",
        source: .current,
        runtimeMaterial: runtime,
        snapshot: nil,
        healthStatus: .healthy,
        errorMessage: nil,
        isCurrent: true
    )
    let modeState = ChatGPTProviderModeState(
        restorePointID: "restore-1",
        providerAccountID: "api-1",
        providerDisplayName: "Third Party",
        activatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    #expect(profile.threadProviderID == "openai")
    #expect(
        currentThreadSyncExpectedProviderID(
            currentProfile: profile,
            chatGPTProviderModeState: modeState,
            currentConfigData: runtime.configData
        ) == "OpenAI"
    )
}

@Test
func backupManagerPrunePreservesActiveChatGPTProviderModeRestorePoint() throws {
    let harness = try makeHarness()
    let protectedID = "19990101-000000-000-protectd"
    let protectedDirectory = harness.appSupportURL
        .appendingPathComponent("SwitchBackups", isDirectory: true)
        .appendingPathComponent(protectedID, isDirectory: true)
    try FileManager.default.createDirectory(at: protectedDirectory, withIntermediateDirectories: true)
    try Data(
        """
        {
          "id": "\(protectedID)",
          "createdAt": "1999-01-01T00:00:00Z",
          "reason": "chatgpt-provider-mode",
          "summary": "protected",
          "codexWasRunning": false,
          "files": []
        }
        """.utf8
    )
    .write(to: protectedDirectory.appendingPathComponent("manifest.json"), options: .atomic)

    try FileManager.default.createDirectory(at: harness.appSupportURL, withIntermediateDirectories: true)
    try Data(
        """
        {
          "restorePointID": "\(protectedID)",
          "providerAccountID": "api-1",
          "providerDisplayName": "api.example.com",
          "activatedAt": "2026-05-16T00:00:00Z"
        }
        """.utf8
    )
    .write(to: chatGPTProviderModeStateURL(baseURL: harness.appSupportURL), options: .atomic)

    let fileURL = harness.codexHomeURL.appendingPathComponent("auth.json", isDirectory: false)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("seed".utf8).write(to: fileURL, options: .atomic)

    let manager = BackupManager(
        backupsRootURL: harness.appSupportURL.appendingPathComponent("SwitchBackups", isDirectory: true),
        protectedRestorePointIDsProvider: {
            activeChatGPTProviderModeRestorePointIDs(baseURL: harness.appSupportURL)
        }
    )
    for index in 0..<21 {
        _ = try manager.createRestorePoint(
            reason: "newer-\(index)",
            summary: "newer",
            files: [fileURL],
            codexWasRunning: false
        )
    }

    #expect(FileManager.default.fileExists(atPath: protectedDirectory.path))
}

private func makeChatGPTProviderModeAPIRecord(
    displayName: String,
    apiKey: String,
    baseURL: String,
    model: String
) -> VaultAccountRecord {
    let runtime = ProfileRuntimeMaterial(
        authData: makeAPIKeyAuthData(apiKey: apiKey),
        configData: synthesizedOpenAICompatibleConfig(baseURL: baseURL, model: model)
    )
    let id = stableAccountRecordID(for: runtime)
    let metadata = VaultAccountMetadata(
        id: id,
        displayName: displayName,
        authMode: .apiKey,
        providerID: "custom",
        baseURL: baseURL,
        model: model,
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        source: .manualAPI,
        runtimeKey: stableAccountIdentityKey(for: runtime)
    )
    let directoryURL = URL(fileURLWithPath: "/tmp/\(id)", isDirectory: true)
    return VaultAccountRecord(
        metadata: metadata,
        runtimeMaterial: runtime,
        directoryURL: directoryURL,
        metadataURL: directoryURL.appendingPathComponent("metadata.json"),
        authURL: directoryURL.appendingPathComponent("auth.json"),
        configURL: directoryURL.appendingPathComponent("config.toml")
    )
}

private func writeProviderModeRollout(under root: URL, id: String, provider: String) throws -> URL {
    let folder = root
        .appendingPathComponent("2026", isDirectory: true)
        .appendingPathComponent("05", isDirectory: true)
        .appendingPathComponent("16", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fileURL = folder.appendingPathComponent("rollout-\(id).jsonl", isDirectory: false)
    let text = """
    {"timestamp":"2026-05-16T00:00:00Z","type":"session_meta","payload":{"id":"\(id)","timestamp":"2026-05-16T00:00:00Z","cwd":"/tmp","source":"vscode","originator":"Codex Desktop","cli_version":"0.118.0-alpha.2","model_provider":"\(provider)"}}
    {"timestamp":"2026-05-16T00:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"hello"}}
    """
    try Data(text.utf8).write(to: fileURL, options: .atomic)
    return fileURL
}

private func readProviderModeRolloutProvider(from fileURL: URL) throws -> String {
    guard let line = try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n").first else {
        throw NSError(domain: "ChatGPTProviderModeTests", code: 1)
    }
    let data = Data(line.utf8)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let payload = object["payload"] as? [String: Any],
          let provider = payload["model_provider"] as? String else {
        throw NSError(domain: "ChatGPTProviderModeTests", code: 2)
    }
    return provider
}

@MainActor
private final class ProviderModeRepairerSpy: OfficialThreadRepairing {
    private(set) var invocationCount = 0

    func rescanAndRepair() async throws -> OfficialRepairSummary {
        invocationCount += 1
        return OfficialRepairSummary(
            createdThreads: 0,
            updatedThreads: 1,
            updatedSessionIndexEntries: 1,
            removedBrokenThreads: 0,
            hiddenSnapshotOnlySessions: 0
        )
    }
}

actor ProviderModeChannelInvalidatorSpy: CodexRPCChannelInvalidating {
    private(set) var invalidateAllCount = 0

    func invalidateAllReusableChannels() async {
        invalidateAllCount += 1
    }

    func invalidateReusableChannel(for runtimeMaterial: ProfileRuntimeMaterial) async {
        _ = runtimeMaterial
    }
}

@MainActor
private final class ProviderModeDesktopControllerSpy: CodexDesktopControlling {
    private(set) var closeInvocationCount = 0
    private(set) var reopenInvocationCount = 0
    var isRunning: Bool

    init(isRunning: Bool) {
        self.isRunning = isRunning
    }

    func closeIfRunning() async throws -> Bool {
        let wasRunning = isRunning
        if wasRunning {
            closeInvocationCount += 1
            isRunning = false
        }
        return wasRunning
    }

    func reopenIfNeeded(previouslyRunning: Bool) async throws {
        guard previouslyRunning else {
            return
        }
        reopenInvocationCount += 1
        isRunning = true
    }
}
