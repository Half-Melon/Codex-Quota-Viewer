import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func vaultAccountStoreCreatesAPIAccountAndPersistsIndex() throws {
    let harness = try makeHarness()
    let vault = VaultAccountStore(
        accountsRootURL: harness.appSupportURL.appendingPathComponent("Accounts", isDirectory: true)
    )

    let record = try vault.createAPIAccount(
        displayName: "Proxy",
        apiKey: "sk-test-1234",
        baseURL: "https://shell.wyzai.top/v1",
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
    #expect(configText.contains("base_url = \"https://shell.wyzai.top/v1\""))
    #expect(FileManager.default.fileExists(atPath: vault.indexURL.path))
}

@Test
func vaultAccountStoreLoadsLegacyMetadataAndRewritesWithoutLegacyFields() throws {
    let harness = try makeHarness()
    let vault = VaultAccountStore(
        accountsRootURL: harness.appSupportURL.appendingPathComponent("Accounts", isDirectory: true)
    )
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
            base_url = "https://shell.wyzai.top/v1"
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
    let vault = VaultAccountStore(
        accountsRootURL: harness.appSupportURL.appendingPathComponent("Accounts", isDirectory: true)
    )

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
            base_url = "https://shell.wyzai.top/v1"
            """.utf8
        )
    )

    #expect(vault.accountID(for: legacyRuntime) == vault.accountID(for: currentRuntime))

    let first = try vault.upsertAccount(
        fallbackDisplayName: "Krisxu8@gmail.com",
        source: .manualChatGPT,
        runtimeMaterial: legacyRuntime
    )
    let second = try vault.upsertAccount(
        fallbackDisplayName: "krisxu8@gmail.com",
        source: .currentRuntime,
        runtimeMaterial: currentRuntime
    )
    let snapshot = try vault.loadSnapshot()

    #expect(first.inserted)
    #expect(second.inserted == false)
    #expect(second.updated)
    #expect(snapshot.accounts.count == 1)
    #expect(snapshot.accounts.first?.metadata.displayName == "Krisxu8@gmail.com")
    #expect(snapshot.accounts.first?.metadata.source == .manualChatGPT)
    #expect(snapshot.accounts.first?.runtimeMaterial.configData.flatMap { try? $0.utf8String() } == "model_provider = \"openai\"\n")
}

@Test
func vaultNormalizationPlanMergesLegacyAndCurrentRuntimeDuplicates() throws {
    let harness = try makeHarness()
    let vault = VaultAccountStore(
        accountsRootURL: harness.appSupportURL.appendingPathComponent("Accounts", isDirectory: true)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601

    let accountsRoot = vault.accountsRootURL
    try FileManager.default.createDirectory(at: accountsRoot, withIntermediateDirectories: true)

    let legacyID = "acct-legacy-1"
    let runtimeID = "acct-current-1"
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    let legacyMetadata = VaultAccountMetadata(
        id: legacyID,
        displayName: "Krisxu9@gmail.com",
        authMode: .chatgpt,
        providerID: "openai",
        baseURL: nil,
        model: nil,
        createdAt: createdAt,
        lastUsedAt: nil,
        source: .currentRuntime,
        runtimeKey: "legacy"
    )
    let currentMetadata = VaultAccountMetadata(
        id: runtimeID,
        displayName: "krisxu9@gmail.com",
        authMode: .chatgpt,
        providerID: "openai",
        baseURL: "https://shell.wyzai.top",
        model: "gpt-5.4",
        createdAt: createdAt.addingTimeInterval(60),
        lastUsedAt: createdAt.addingTimeInterval(120),
        source: .currentRuntime,
        runtimeKey: "current"
    )

    let legacyRuntime = ProfileRuntimeMaterial(
        authData: Data(
            """
            {"auth_mode":"chatgpt","last_refresh":"2026-03-30T02:33:21.958042Z","tokens":{"access_token":"token-1","refresh_token":"refresh-1","account_id":"acct-9"}}
            """.utf8
        ),
        configData: Data("model_provider = \"openai\"\n".utf8)
    )
    let currentRuntime = ProfileRuntimeMaterial(
        authData: Data(
            """
            {"auth_mode":"chatgpt","last_refresh":"2026-03-31T01:45:41.950247Z","tokens":{"access_token":"token-2","refresh_token":"refresh-2","account_id":"acct-9"}}
            """.utf8
        ),
        configData: Data(
            """
            model_provider = "custom"
            model = "gpt-5.4"

            [model_providers.custom]
            name = "custom"
            requires_openai_auth = true
            base_url = "https://shell.wyzai.top/v1"
            """.utf8
        )
    )

    try writeVaultRecord(root: accountsRoot, metadata: legacyMetadata, runtime: legacyRuntime, encoder: encoder)
    try writeVaultRecord(root: accountsRoot, metadata: currentMetadata, runtime: currentRuntime, encoder: encoder)
    try encoder.encode([legacyMetadata, currentMetadata]).write(to: vault.indexURL)

    let plan = try #require(try vault.normalizationPlan())
    try vault.applyNormalizationPlan(plan)

    let snapshot = try vault.loadSnapshot()
    #expect(plan.obsoleteRecordIDs.count == 2)
    #expect(snapshot.accounts.count == 1)
    #expect(snapshot.accounts.first?.id == vault.accountID(for: currentRuntime))
    #expect(snapshot.accounts.first?.metadata.displayName == "Krisxu9@gmail.com")
    #expect(snapshot.accounts.first?.runtimeMaterial.configData.flatMap { try? $0.utf8String() } == "model_provider = \"openai\"\nmodel = \"gpt-5.4\"\n")
}

@Test
func vaultNormalizationPlanRewritesLegacyOpenAICompatibleAPIConfigToWorkingCustomProviderShape() throws {
    let harness = try makeHarness()
    let vault = VaultAccountStore(
        accountsRootURL: harness.appSupportURL.appendingPathComponent("Accounts", isDirectory: true)
    )

    let legacyRuntime = ProfileRuntimeMaterial(
        authData: Data(#"{"OPENAI_API_KEY":"sk-test-legacy"}"#.utf8),
        configData: Data(
            """
            model_provider = "openai"
            base_url = "https://shell.wyzai.top"
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
    #expect(configText.contains("base_url = \"https://shell.wyzai.top/v1\""))
}

@MainActor
@Test
func accountOnboardingCoordinatorImportsChatGPTLoginFromTemporaryCodexHome() async throws {
    let harness = try makeHarness()
    let vault = VaultAccountStore(
        accountsRootURL: harness.appSupportURL.appendingPathComponent("Accounts", isDirectory: true)
    )
    let coordinator = AccountOnboardingCoordinator(
        vaultStore: vault,
        backupManager: BackupManager(
            backupsRootURL: harness.appSupportURL.appendingPathComponent("SwitchBackups", isDirectory: true)
        ),
        protectedFilesProvider: { accountIDs in
            [vault.indexURL] + vault.protectedMutationFileURLs(forAccountIDs: accountIDs)
        },
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
    let vault = VaultAccountStore(
        accountsRootURL: harness.appSupportURL.appendingPathComponent("Accounts", isDirectory: true)
    )
    let coordinator = AccountOnboardingCoordinator(
        vaultStore: vault,
        backupManager: BackupManager(
            backupsRootURL: harness.appSupportURL.appendingPathComponent("SwitchBackups", isDirectory: true)
        ),
        protectedFilesProvider: { accountIDs in
            [vault.indexURL] + vault.protectedMutationFileURLs(forAccountIDs: accountIDs)
        },
        apiModelsProbe: ProbeStub(
            result: APIAccountProbeResponse(
                modelIDs: ["gpt-5.4"],
                normalizedBaseURL: "https://shell.wyzai.top/v1"
            )
        )
    )

    let result = try await coordinator.addAPIAccount(
        apiKey: "sk-proxy-test",
        rawBaseURL: "shell.wyzai.top"
    )
    let configData = try #require(result.record.runtimeMaterial.configData)
    let configText = try configData.utf8String()

    #expect(result.record.metadata.authMode == .apiKey)
    #expect(result.record.metadata.source == .manualAPI)
    #expect(configText.contains("model_provider = \"custom\""))
    #expect(configText.contains("[model_providers.custom]"))
    #expect(configText.contains("wire_api = \"responses\""))
    #expect(configText.contains("requires_openai_auth = true"))
    #expect(configText.contains("base_url = \"https://shell.wyzai.top/v1\""))
    #expect(configText.contains("model = \"gpt-5.4\""))
}

private func writeVaultRecord(
    root: URL,
    metadata: VaultAccountMetadata,
    runtime: ProfileRuntimeMaterial,
    encoder: JSONEncoder
) throws {
    let directory = root.appendingPathComponent(metadata.id, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try encoder.encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))
    try runtime.authData.write(to: directory.appendingPathComponent("auth.json"))
    try runtime.configData?.write(to: directory.appendingPathComponent("config.toml"))
}

private struct ProbeStub: APIModelsProbing {
    let result: APIAccountProbeResponse

    func probeModels(apiKey: String, rawBaseURL: String) async throws -> APIAccountProbeResponse {
        result
    }
}
