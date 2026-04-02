import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func vaultBootstrapCoordinatorRewritesPreferredAccountIDAfterNormalization() throws {
    try withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])

        let harness = try makeHarness()
        let vault = makeVaultStore(harness)
        let backupManager = makeBackupManager(harness)
        let protectedFilesProvider = makeProtectedFilesProvider(for: vault)
        let captureCoordinator = CurrentRuntimeCaptureCoordinator(
            vaultStore: vault,
            backupManager: backupManager,
            protectedFilesProvider: protectedFilesProvider
        )
        let coordinator = VaultBootstrapCoordinator(
            vaultStore: vault,
            backupManager: backupManager,
            currentRuntimeCaptureCoordinator: captureCoordinator,
            protectedFilesProvider: protectedFilesProvider
        )

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

        var persistedSettings: AppSettings?
        let outcome = try coordinator.bootstrap(
            currentRuntimeMaterial: nil,
            currentSnapshot: nil,
            settings: AppSettings(preferredAccountID: fixture.legacyMetadata.id),
            saveSettings: { settings, _ in
                persistedSettings = settings
            },
            userFacingMessage: { $0.localizedDescription }
        )

        #expect(outcome.settings.preferredAccountID == vault.accountID(for: fixture.currentRuntime))
        #expect(persistedSettings?.preferredAccountID == vault.accountID(for: fixture.currentRuntime))
        #expect(outcome.statusNotice?.kind == .info)
        #expect(outcome.statusNotice?.message.contains("local vault") == true)
        #expect(outcome.safeSwitchNotice == nil)
    }
}
