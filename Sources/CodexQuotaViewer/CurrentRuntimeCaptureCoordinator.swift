import Foundation

struct CurrentRuntimeCaptureResult: Equatable {
    let action: CurrentRuntimeCaptureAction
    let updated: Bool
}

final class CurrentRuntimeCaptureCoordinator {
    typealias ProtectedFilesProvider = ([String]) throws -> [URL]

    private let vaultStore: VaultAccountStore
    private let backupManager: BackupManager
    private let protectedFilesProvider: ProtectedFilesProvider

    init(
        vaultStore: VaultAccountStore,
        backupManager: BackupManager,
        protectedFilesProvider: @escaping ProtectedFilesProvider
    ) {
        self.vaultStore = vaultStore
        self.backupManager = backupManager
        self.protectedFilesProvider = protectedFilesProvider
    }

    func captureIfNeeded(
        currentRuntimeMaterial: ProfileRuntimeMaterial,
        currentSnapshot: CodexSnapshot?
    ) throws -> CurrentRuntimeCaptureResult {
        let canonicalRuntime = canonicalRuntimeMaterialForStorage(currentRuntimeMaterial)
        let accountID = vaultStore.accountID(for: canonicalRuntime)
        let existingRecord = try vaultStore.loadSnapshot().accounts.first(where: { $0.id == accountID })
        let action = currentRuntimeCaptureAction(
            currentRuntimeMaterial: currentRuntimeMaterial,
            existingRuntimeMaterial: existingRecord?.runtimeMaterial
        )

        guard action != .skip else {
            return CurrentRuntimeCaptureResult(action: .skip, updated: false)
        }

        let fallbackName = currentSnapshot?.account.email
            ?? currentSnapshot?.account.displayLabel
            ?? AppLocalization.currentAccountFallbackName()
        let writer: FileDataWriting

        if action == .captureWithRestorePoint {
            let restorePoint = try backupManager.createRestorePoint(
                reason: "capture-current-account",
                summary: "Capture current account into vault",
                files: try protectedFilesProvider([accountID]),
                codexWasRunning: false
            )
            writer = ProtectedFileMutationContext(restorePoint: restorePoint)
        } else {
            writer = DirectFileDataWriter()
        }

        let result = try vaultStore.upsertAccount(
            fallbackDisplayName: fallbackName,
            source: .currentRuntime,
            runtimeMaterial: currentRuntimeMaterial,
            writer: writer
        )
        return CurrentRuntimeCaptureResult(action: action, updated: result.updated)
    }
}
