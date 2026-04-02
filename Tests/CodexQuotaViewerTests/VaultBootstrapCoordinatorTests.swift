import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func vaultBootstrapCoordinatorRewritesPreferredAccountIDAfterNormalization() throws {
    try withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])

        let harness = try makeHarness()
        let vault = VaultAccountStore(
            accountsRootURL: harness.appSupportURL.appendingPathComponent("Accounts", isDirectory: true)
        )
        let backupManager = BackupManager(
            backupsRootURL: harness.appSupportURL.appendingPathComponent("SwitchBackups", isDirectory: true)
        )
        let captureCoordinator = CurrentRuntimeCaptureCoordinator(
            vaultStore: vault,
            backupManager: backupManager,
            protectedFilesProvider: { accountIDs in
                [vault.indexURL] + vault.protectedMutationFileURLs(forAccountIDs: accountIDs)
            }
        )
        let coordinator = VaultBootstrapCoordinator(
            vaultStore: vault,
            backupManager: backupManager,
            currentRuntimeCaptureCoordinator: captureCoordinator,
            protectedFilesProvider: { accountIDs in
                [vault.indexURL] + vault.protectedMutationFileURLs(forAccountIDs: accountIDs)
            }
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

        var persistedSettings: AppSettings?
        let outcome = try coordinator.bootstrap(
            currentRuntimeMaterial: nil,
            currentSnapshot: nil,
            settings: AppSettings(preferredAccountID: legacyID),
            saveSettings: { settings, _ in
                persistedSettings = settings
            },
            userFacingMessage: { $0.localizedDescription }
        )

        #expect(outcome.settings.preferredAccountID == vault.accountID(for: currentRuntime))
        #expect(persistedSettings?.preferredAccountID == vault.accountID(for: currentRuntime))
        #expect(outcome.statusNotice?.kind == .info)
        #expect(outcome.statusNotice?.message.contains("local vault") == true)
        #expect(outcome.safeSwitchNotice == nil)
    }
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
