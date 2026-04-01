import Foundation

@MainActor
protocol SessionManagerLaunching: AnyObject {
    func openSessionManagerInBrowser() async throws -> SessionManagerLaunchResult
    func stopManagedProcess()
}

@MainActor
extension SessionManagerLauncher: SessionManagerLaunching {}

struct SessionManagerLocalizationSyncResult {
    let settings: AppSettings
    let notice: MenuNotice?
}

@MainActor
final class SessionManagerCoordinator {
    private let store: ProfileStore
    private let launcher: SessionManagerLaunching

    init(
        store: ProfileStore,
        launcher: SessionManagerLaunching
    ) {
        self.store = store
        self.launcher = launcher
    }

    func synchronizeLocalizationState(
        settings: AppSettings,
        settingsWriter: FileDataWriting = DirectFileDataWriter(),
        uiConfigWriter: FileDataWriting = DirectFileDataWriter()
    ) -> SessionManagerLocalizationSyncResult {
        AppLocalization.setPreferredLanguage(settings.appLanguage)

        let resolvedLanguage = AppLocalization.resolvedLanguage
        var updatedSettings = settings
        updatedSettings.lastResolvedLanguage = resolvedLanguage

        var warnings: [String] = []

        if settings.lastResolvedLanguage != resolvedLanguage {
            do {
                try store.saveSettings(updatedSettings, writer: settingsWriter)
            } catch {
                warnings.append(
                    AppLocalization.localized(
                        en: "Language preference could not be saved: \(userFacingErrorMessage(error))",
                        zh: "语言设置未能保存：\(userFacingErrorMessage(error))"
                    )
                )
            }
        }

        do {
            try store.saveSessionManagerUIConfig(
                SessionManagerUIConfig(language: resolvedLanguage),
                writer: uiConfigWriter
            )
        } catch {
            warnings.append(
                AppLocalization.localized(
                    en: "Session Manager language sync failed: \(userFacingErrorMessage(error))",
                    zh: "Session Manager 语言同步失败：\(userFacingErrorMessage(error))"
                )
            )
        }

        let notice = warnings.isEmpty
            ? nil
            : MenuNotice(kind: .warning, message: warnings.joined(separator: " "))

        return SessionManagerLocalizationSyncResult(
            settings: updatedSettings,
            notice: notice
        )
    }

    func openInBrowser() async throws -> SessionManagerLaunchResult {
        try await launcher.openSessionManagerInBrowser()
    }

    func stopManagedProcess() {
        launcher.stopManagedProcess()
    }
}
