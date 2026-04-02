import Foundation

struct VaultBootstrapOutcome: Equatable {
    var settings: AppSettings
    var statusNotice: MenuNotice?
    var safeSwitchNotice: MenuNotice?
}

final class VaultBootstrapCoordinator {
    typealias ProtectedFilesProvider = ([String]) throws -> [URL]
    typealias SettingsSaver = (AppSettings, FileDataWriting) throws -> Void

    private let vaultStore: VaultAccountStore
    private let backupManager: BackupManager
    private let currentRuntimeCaptureCoordinator: CurrentRuntimeCaptureCoordinator
    private let protectedFilesProvider: ProtectedFilesProvider

    init(
        vaultStore: VaultAccountStore,
        backupManager: BackupManager,
        currentRuntimeCaptureCoordinator: CurrentRuntimeCaptureCoordinator,
        protectedFilesProvider: @escaping ProtectedFilesProvider
    ) {
        self.vaultStore = vaultStore
        self.backupManager = backupManager
        self.currentRuntimeCaptureCoordinator = currentRuntimeCaptureCoordinator
        self.protectedFilesProvider = protectedFilesProvider
    }

    func bootstrap(
        currentRuntimeMaterial: ProfileRuntimeMaterial?,
        currentSnapshot: CodexSnapshot?,
        settings: AppSettings,
        saveSettings: SettingsSaver,
        userFacingMessage: (Error) -> String
    ) throws -> VaultBootstrapOutcome {
        var outcome = VaultBootstrapOutcome(settings: settings)

        do {
            if let normalizationResult = try normalizeVaultIfNeeded(
                settings: outcome.settings,
                saveSettings: saveSettings,
                userFacingMessage: userFacingMessage
            ) {
                outcome.settings = normalizationResult.settings
                outcome.statusNotice = normalizationResult.statusNotice
            }
        } catch {
            outcome.safeSwitchNotice = MenuNotice(
                kind: .warning,
                message: AppLocalization.localized(
                    en: "Account cleanup skipped: \(userFacingMessage(error))",
                    zh: "账号清理已跳过：\(userFacingMessage(error))"
                )
            )
        }

        guard let currentRuntimeMaterial else {
            return outcome
        }

        do {
            let captureResult = try currentRuntimeCaptureCoordinator.captureIfNeeded(
                currentRuntimeMaterial: currentRuntimeMaterial,
                currentSnapshot: currentSnapshot
            )
            if captureResult.action == .captureWithRestorePoint,
               captureResult.updated {
                outcome.statusNotice = MenuNotice(
                    kind: .info,
                    message: AppLocalization.localized(
                        en: "Updated a saved account with the latest current login.",
                        zh: "已用当前最新登录状态更新一个已保存账号。"
                    )
                )
            }
        } catch {
            outcome.safeSwitchNotice = MenuNotice(
                kind: .warning,
                message: AppLocalization.localized(
                    en: "Could not capture the current account into the local vault: \(userFacingMessage(error))",
                    zh: "无法把当前账号保存到本地账号仓：\(userFacingMessage(error))"
                )
            )
        }

        return outcome
    }

    private func normalizeVaultIfNeeded(
        settings: AppSettings,
        saveSettings: SettingsSaver,
        userFacingMessage: (Error) -> String
    ) throws -> (settings: AppSettings, statusNotice: MenuNotice?)? {
        guard let plan = try vaultStore.normalizationPlan() else {
            return nil
        }

        let filesToBackup = try protectedFilesProvider(
            Array(Set(plan.originalRecords.map(\.id) + plan.normalizedRecords.map(\.id)))
        )
        let restorePoint = try backupManager.createRestorePoint(
            reason: "normalize-account-vault",
            summary: "Normalize saved accounts in the local vault",
            files: filesToBackup,
            codexWasRunning: false
        )
        let writer = ProtectedFileMutationContext(restorePoint: restorePoint)
        try vaultStore.applyNormalizationPlan(plan, writer: writer)

        var nextSettings = settings
        var statusNotice: MenuNotice?

        if let preferredAccountID = nextSettings.preferredAccountID,
           let rewrittenID = plan.idMapping[preferredAccountID],
           rewrittenID != preferredAccountID {
            nextSettings.preferredAccountID = rewrittenID
            do {
                try saveSettings(nextSettings, writer)
            } catch {
                statusNotice = MenuNotice(
                    kind: .warning,
                    message: AppLocalization.localized(
                        en: "Saved account cleanup finished, but the preferred account could not be updated: \(userFacingMessage(error))",
                        zh: "已完成账号清理，但无法更新默认账号：\(userFacingMessage(error))"
                    )
                )
            }
        }

        let removedCount = plan.originalRecords.count - plan.normalizedRecords.count
        if removedCount > 0 {
            statusNotice = MenuNotice(
                kind: .info,
                message: AppLocalization.localized(
                    en: "Merged \(removedCount) duplicate account(s) into the local vault.",
                    zh: "已将 \(removedCount) 个重复账号合并到本地账号仓。"
                )
            )
        }

        return (nextSettings, statusNotice)
    }
}
