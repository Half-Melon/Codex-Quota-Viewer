import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func vaultAccountStoreCreatesAPIAccountAndPersistsIndex() throws {
    let harness = try makeHarness()
    let vault = makeVaultStore(harness)

    let record = try vault.createAPIAccount(
        displayName: "Proxy",
        apiKey: "sk-test-1234",
        baseURL: "https://gateway.example.com/v1",
        model: "gpt-5.4"
    )
    let snapshot = try vault.loadSnapshot()

    #expect(snapshot.accounts.count == 1)
    #expect(snapshot.accounts.first?.metadata.displayName == "Proxy")
    #expect(snapshot.accounts.first?.metadata.source == .manualAPI)
    #expect(try record.runtimeMaterial.authData.utf8String().contains("\"OPENAI_API_KEY\":\"sk-test-1234\""))
    let configData = try #require(record.runtimeMaterial.configData)
    let configText = try configData.utf8String()
    #expect(configText.contains("model_provider = \"custom\""))
    #expect(configText.contains("[model_providers.custom]"))
    #expect(configText.contains("wire_api = \"responses\""))
    #expect(configText.contains("requires_openai_auth = true"))
    #expect(configText.contains("base_url = \"https://gateway.example.com/v1\""))
    #expect(FileManager.default.fileExists(atPath: vault.indexURL.path))
}

@Test
func vaultAccountStoreLoadsLegacyMetadataAndRewritesWithoutLegacyFields() throws {
    let harness = try makeHarness()
    let vault = makeVaultStore(harness)
    let root = vault.accountsRootURL
    let accountID = "acct-legacy-1"
    let accountDirectory = root.appendingPathComponent(accountID, isDirectory: true)
    try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)

    let metadataData = Data(
        """
        {
          "id": "acct-legacy-1",
          "displayName": "legacy@example.com",
          "authMode": "chatgpt",
          "providerID": "openai",
          "baseURL": null,
          "model": "gpt-5.4",
          "createdAt": "2026-03-31T00:00:00Z",
          "lastUsedAt": null,
          "source": "legacyCCSwitch",
          "isImportedFromCCSwitch": true,
          "runtimeKey": "chatgpt:acct-legacy-1"
        }
        """.utf8
    )
    try metadataData.write(to: accountDirectory.appendingPathComponent("metadata.json"))
    try Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"token-1","account_id":"acct-legacy-1"}}"#.utf8)
        .write(to: accountDirectory.appendingPathComponent("auth.json"))
    try Data("model_provider = \"openai\"\nmodel = \"gpt-5.4\"\n".utf8)
        .write(to: accountDirectory.appendingPathComponent("config.toml"))
    try Data("[{\"id\":\"acct-legacy-1\",\"displayName\":\"legacy@example.com\",\"authMode\":\"chatgpt\",\"providerID\":\"openai\",\"baseURL\":null,\"model\":\"gpt-5.4\",\"createdAt\":\"2026-03-31T00:00:00Z\",\"lastUsedAt\":null,\"source\":\"legacyCCSwitch\",\"isImportedFromCCSwitch\":true,\"runtimeKey\":\"chatgpt:acct-legacy-1\"}]".utf8)
        .write(to: vault.indexURL)

    let loaded = try vault.loadSnapshot()
    _ = try vault.noteAccountUsed(id: accountID)
    let rewritten = try String(
        contentsOf: accountDirectory.appendingPathComponent("metadata.json"),
        encoding: .utf8
    )

    #expect(loaded.accounts.count == 1)
    #expect(loaded.accounts.first?.metadata.displayName == "legacy@example.com")
    #expect(loaded.accounts.first?.metadata.authMode == .chatgpt)
    #expect(rewritten.contains("legacyCCSwitch") == false)
    #expect(rewritten.contains("isImportedFromCCSwitch") == false)
    #expect(rewritten.contains("\"source\""))
}

@Test
func vaultAccountStoreSkipsCorruptedRecordsAndKeepsHealthyAccountsVisible() throws {
    let harness = try makeHarness()
    let vault = makeVaultStore(harness)

    let record = try vault.createAPIAccount(
        displayName: "Healthy",
        apiKey: "sk-healthy",
        baseURL: "https://api.example.com/v1",
        model: "gpt-5.4"
    )

    let corruptedDirectory = vault.accountsRootURL.appendingPathComponent("acct-corrupted", isDirectory: true)
    try FileManager.default.createDirectory(at: corruptedDirectory, withIntermediateDirectories: true)
    try Data("{not-json}".utf8).write(
        to: corruptedDirectory.appendingPathComponent("metadata.json"),
        options: .atomic
    )
    try Data("broken".utf8).write(
        to: corruptedDirectory.appendingPathComponent("auth.json"),
        options: .atomic
    )

    let snapshot = try vault.loadSnapshot()

    #expect(snapshot.accounts.count == 1)
    #expect(snapshot.accounts.first?.id == record.id)
}

@Test
func stableAccountRecordIDUsesStableChatGPTIdentityAcrossRefreshAndConfigDifferences() throws {
    let legacyRuntime = ProfileRuntimeMaterial(
        authData: Data(
            """
            {"auth_mode":"chatgpt","last_refresh":"2026-03-30T02:33:21.958042Z","tokens":{"access_token":"token-1","refresh_token":"refresh-1","account_id":"acct-1"}}
            """.utf8
        ),
        configData: Data("model_provider = \"openai\"\n".utf8)
    )
    let currentRuntime = ProfileRuntimeMaterial(
        authData: Data(
            """
            {"auth_mode":"chatgpt","last_refresh":"2026-03-31T01:45:41.950247Z","tokens":{"access_token":"token-2","refresh_token":"refresh-2","account_id":"acct-1"}}
            """.utf8
        ),
        configData: Data(
            """
            model_provider = "custom"

            [model_providers.custom]
            name = "custom"
            requires_openai_auth = true
            base_url = "https://gateway.example.com/v1"
            """.utf8
        )
    )

    #expect(stableAccountRecordID(for: legacyRuntime) == stableAccountRecordID(for: currentRuntime))
}

@Test
func resolveAuthModePrefersExplicitChatGPTModeOverResidualAPIKey() {
    let authData = Data(
        """
        {"auth_mode":"chatgpt","OPENAI_API_KEY":"sk-residual","tokens":{"access_token":"token-1","account_id":"acct-1"}}
        """.utf8
    )

    #expect(resolveAuthMode(authData: authData) == .chatgpt)
}

@Test
func vaultAccountStoreUsesStableChatGPTIdentityAcrossRefreshAndConfigDifferences() throws {
    let harness = try makeHarness()
    let vault = makeVaultStore(harness)

    let legacyRuntime = ProfileRuntimeMaterial(
        authData: Data(
            """
            {"auth_mode":"chatgpt","last_refresh":"2026-03-30T02:33:21.958042Z","tokens":{"access_token":"token-1","refresh_token":"refresh-1","account_id":"acct-1"}}
            """.utf8
        ),
        configData: Data("model_provider = \"openai\"\n".utf8)
    )
    let currentRuntime = ProfileRuntimeMaterial(
        authData: Data(
            """
            {"auth_mode":"chatgpt","last_refresh":"2026-03-31T01:45:41.950247Z","tokens":{"access_token":"token-2","refresh_token":"refresh-2","account_id":"acct-1"}}
            """.utf8
        ),
        configData: Data(
            """
            model_provider = "custom"

            [model_providers.custom]
            name = "custom"
            requires_openai_auth = true
            base_url = "https://gateway.example.com/v1"
            """.utf8
        )
    )

    #expect(vault.accountID(for: legacyRuntime) == vault.accountID(for: currentRuntime))

    let first = try vault.upsertAccount(
        fallbackDisplayName: "Saved.User@example.com",
        source: .manualChatGPT,
        runtimeMaterial: legacyRuntime
    )
    let second = try vault.upsertAccount(
        fallbackDisplayName: "saved.user@example.com",
        source: .currentRuntime,
        runtimeMaterial: currentRuntime
    )
    let snapshot = try vault.loadSnapshot()

    #expect(first.inserted)
    #expect(second.inserted == false)
    #expect(second.updated)
    #expect(snapshot.accounts.count == 1)
    #expect(snapshot.accounts.first?.metadata.displayName == "Saved.User@example.com")
    #expect(snapshot.accounts.first?.metadata.source == .manualChatGPT)
    #expect(snapshot.accounts.first?.runtimeMaterial.configData.flatMap { try? $0.utf8String() } == "model_provider = \"openai\"\n")
}

@Test
func vaultNormalizationPlanMergesLegacyAndCurrentRuntimeDuplicates() throws {
    let harness = try makeHarness()
    let vault = makeVaultStore(harness)
    let fixture = makeChatGPTNormalizationFixture()

    let accountsRoot = vault.accountsRootURL
    try FileManager.default.createDirectory(at: accountsRoot, withIntermediateDirectories: true)

    try writeTestVaultRecord(
        root: accountsRoot,
        metadata: fixture.legacyMetadata,
        runtime: fixture.legacyRuntime,
        encoder: fixture.encoder
    )
    try writeTestVaultRecord(
        root: accountsRoot,
        metadata: fixture.currentMetadata,
        runtime: fixture.currentRuntime,
        encoder: fixture.encoder
    )
    try fixture.encoder.encode([fixture.legacyMetadata, fixture.currentMetadata]).write(to: vault.indexURL)

    let plan = try #require(try vault.normalizationPlan())
    try vault.applyNormalizationPlan(plan)

    let snapshot = try vault.loadSnapshot()
    #expect(plan.obsoleteRecordIDs.count == 2)
    #expect(snapshot.accounts.count == 1)
    #expect(snapshot.accounts.first?.id == vault.accountID(for: fixture.currentRuntime))
    #expect(snapshot.accounts.first?.metadata.displayName == "Primary.User@example.com")
    #expect(snapshot.accounts.first?.runtimeMaterial.configData.flatMap { try? $0.utf8String() } == "model_provider = \"openai\"\nmodel = \"gpt-5.4\"\n")
}

@Test
func vaultNormalizationPlanRewritesLegacyOpenAICompatibleAPIConfigToWorkingCustomProviderShape() throws {
    let harness = try makeHarness()
    let vault = makeVaultStore(harness)

    let legacyRuntime = ProfileRuntimeMaterial(
        authData: Data(#"{"OPENAI_API_KEY":"sk-test-legacy"}"#.utf8),
        configData: Data(
            """
            model_provider = "openai"
            base_url = "https://gateway.example.com"
            model = "gpt-5.4"
            """.utf8
        )
    )

    _ = try vault.upsertAccount(
        fallbackDisplayName: "legacy proxy",
        source: .manualAPI,
        runtimeMaterial: legacyRuntime
    )

    let plan = try #require(try vault.normalizationPlan())
    try vault.applyNormalizationPlan(plan)

    let snapshot = try vault.loadSnapshot()
    let configData = try #require(snapshot.accounts.first?.runtimeMaterial.configData)
    let configText = try configData.utf8String()

    #expect(snapshot.accounts.count == 1)
    #expect(configText.contains("model_provider = \"custom\""))
    #expect(configText.contains("[model_providers.custom]"))
    #expect(configText.contains("wire_api = \"responses\""))
    #expect(configText.contains("requires_openai_auth = true"))
    #expect(configText.contains("base_url = \"https://gateway.example.com/v1\""))
}

@MainActor
@Test
func accountOnboardingCoordinatorImportsChatGPTLoginFromTemporaryCodexHome() async throws {
    let harness = try makeHarness()
    let vault = makeVaultStore(harness)
    let coordinator = AccountOnboardingCoordinator(
        vaultStore: vault,
        backupManager: makeBackupManager(harness),
        protectedFilesProvider: makeProtectedFilesProvider(for: vault),
        processRunner: { command in
            try FileManager.default.createDirectory(at: command.codexHomeURL, withIntermediateDirectories: true)
            try Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"token-1","refresh_token":"refresh-1","account_id":"acct-1"}}"#.utf8)
                .write(to: command.codexHomeURL.appendingPathComponent("auth.json"), options: .atomic)
            try Data("model_provider = \"openai\"\nmodel = \"gpt-5.4\"\n".utf8)
                .write(to: command.codexHomeURL.appendingPathComponent("config.toml"), options: .atomic)
            return AccountOnboardingProcessResult(
                exitStatus: 0,
                standardOutput: "ok",
                standardError: ""
            )
        }
    )

    let result = try await coordinator.addChatGPTAccount()
    let snapshot = try vault.loadSnapshot()

    #expect(result.record.metadata.authMode == .chatgpt)
    #expect(snapshot.accounts.count == 1)
    #expect(snapshot.accounts.first?.metadata.source == .manualChatGPT)
}

@MainActor
@Test
func accountOnboardingCoordinatorCreatesOpenAICompatibleAPIAccountWithCustomProviderConfig() async throws {
    let harness = try makeHarness()
    let vault = makeVaultStore(harness)
    let coordinator = AccountOnboardingCoordinator(
        vaultStore: vault,
        backupManager: makeBackupManager(harness),
        protectedFilesProvider: makeProtectedFilesProvider(for: vault),
        apiModelsProbe: ProbeStub(
            result: APIAccountProbeResponse(
                modelIDs: ["gpt-5.4"],
                normalizedBaseURL: "https://gateway.example.com/v1"
            )
        )
    )

    let result = try await coordinator.addAPIAccount(
        apiKey: "sk-proxy-test",
        rawBaseURL: "gateway.example.com"
    )
    let configData = try #require(result.record.runtimeMaterial.configData)
    let configText = try configData.utf8String()

    #expect(result.record.metadata.authMode == .apiKey)
    #expect(result.record.metadata.source == .manualAPI)
    #expect(configText.contains("model_provider = \"custom\""))
    #expect(configText.contains("[model_providers.custom]"))
    #expect(configText.contains("wire_api = \"responses\""))
    #expect(configText.contains("requires_openai_auth = true"))
    #expect(configText.contains("base_url = \"https://gateway.example.com/v1\""))
    #expect(configText.contains("model = \"gpt-5.4\""))
}

@Test
func vaultAccountRecordWriterHardensVaultAuthAndConfigPermissions() throws {
    let harness = try makeHarness()
    let directoryURL = harness.appSupportURL.appendingPathComponent("Accounts/acct-secure", isDirectory: true)
    let record = VaultAccountRecord(
        metadata: VaultAccountMetadata(
            id: "acct-secure",
            displayName: "Secure Account",
            authMode: .apiKey,
            providerID: "openai",
            baseURL: "https://api.example.com/v1",
            model: "gpt-5.4",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastUsedAt: nil,
            source: .manualAPI,
            runtimeKey: "secure-runtime"
        ),
        runtimeMaterial: ProfileRuntimeMaterial(
            authData: Data(#"{"OPENAI_API_KEY":"sk-secure","auth_mode":"apikey"}"#.utf8),
            configData: Data("model_provider = \"openai\"\nmodel = \"gpt-5.4\"\n".utf8)
        ),
        directoryURL: directoryURL,
        metadataURL: directoryURL.appendingPathComponent("metadata.json"),
        authURL: directoryURL.appendingPathComponent("auth.json"),
        configURL: directoryURL.appendingPathComponent("config.toml")
    )

    try VaultAccountRecordWriter().write(record)

    let fileManager = FileManager.default
    let directoryPermissions = try #require(
        fileManager.attributesOfItem(atPath: directoryURL.path)[.posixPermissions] as? NSNumber
    )
    let authPermissions = try #require(
        fileManager.attributesOfItem(atPath: record.authURL.path)[.posixPermissions] as? NSNumber
    )
    let configPermissions = try #require(
        fileManager.attributesOfItem(atPath: record.configURL.path)[.posixPermissions] as? NSNumber
    )

    #expect(directoryPermissions.intValue == 0o700)
    #expect(authPermissions.intValue == 0o600)
    #expect(configPermissions.intValue == 0o600)
}

private struct ProbeStub: APIModelsProbing {
    let result: APIAccountProbeResponse

    func probeModels(apiKey: String, rawBaseURL: String) async throws -> APIAccountProbeResponse {
        result
    }
}

private struct FailingProbeStub: APIModelsProbing {
    let error: Error

    func probeModels(apiKey: String, rawBaseURL: String) async throws -> APIAccountProbeResponse {
        throw error
    }
}

@MainActor
@Test
func accountOnboardingCoordinatorRejectsUnauthorizedProbeWithoutFallback() async throws {
    let harness = try makeHarness()
    let vault = makeVaultStore(harness)
    let coordinator = AccountOnboardingCoordinator(
        vaultStore: vault,
        backupManager: makeBackupManager(harness),
        protectedFilesProvider: makeProtectedFilesProvider(for: vault),
        apiModelsProbe: FailingProbeStub(error: APIModelsProbeError.authenticationFailed)
    )

    await #expect(throws: APIModelsProbeError.authenticationFailed) {
        _ = try await coordinator.addAPIAccount(
            apiKey: "sk-proxy-test",
            rawBaseURL: "gateway.example.com"
        )
    }

    #expect(try vault.loadSnapshot().accounts.isEmpty)
}

@MainActor
@Test
func accountOnboardingCoordinatorUsesCodexExecutableFromPATHWhenBundledExecutableMissing() async throws {
    let harness = try makeHarness()
    let vault = makeVaultStore(harness)
    let binDirectory = harness.homeURL.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    let pathExecutable = binDirectory.appendingPathComponent("codex", isDirectory: false)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: pathExecutable, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: pathExecutable.path
    )

    let coordinator = AccountOnboardingCoordinator(
        vaultStore: vault,
        backupManager: makeBackupManager(harness),
        protectedFilesProvider: makeProtectedFilesProvider(for: vault),
        codexExecutableURL: harness.homeURL.appendingPathComponent("missing-codex", isDirectory: false),
        bundledCodexExecutableURL: harness.homeURL.appendingPathComponent("missing-bundled-codex", isDirectory: false),
        processEnvironment: ["PATH": binDirectory.path],
        processRunner: { command in
            #expect(command.codexExecutableURL == pathExecutable)
            try FileManager.default.createDirectory(at: command.codexHomeURL, withIntermediateDirectories: true)
            try Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"token-1","account_id":"acct-1"}}"#.utf8)
                .write(to: command.codexHomeURL.appendingPathComponent("auth.json"), options: .atomic)
            return AccountOnboardingProcessResult(
                exitStatus: 0,
                standardOutput: "ok",
                standardError: ""
            )
        }
    )

    let result = try await coordinator.addChatGPTAccount()
    #expect(result.record.metadata.authMode == .chatgpt)
}
