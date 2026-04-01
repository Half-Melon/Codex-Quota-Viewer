import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func appLanguageResolvesSystemPreferenceAndLocalizedDisplayNames() {
    withExclusiveAppLocalization {
        #expect(resolveAppLanguage(.system, preferredLanguages: ["zh-Hans-CN"]) == .zh)
        #expect(resolveAppLanguage(.system, preferredLanguages: ["en-US"]) == .en)

        AppLocalization.setPreferredLanguage(.zh, preferredLanguages: ["zh-Hans-CN"])
        #expect(RefreshIntervalPreset.fiveMinutes.displayName == "5 分钟")
        #expect(StatusItemStyle.text.displayName == "文字")
        #expect(ProfileHealthStatus.expired.label == "已过期")

        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        #expect(RefreshIntervalPreset.fiveMinutes.displayName == "5 minutes")
        #expect(StatusItemStyle.text.displayName == "Text")
        #expect(ProfileHealthStatus.expired.label == "Expired")
    }
}

@Test
func appSettingsPersistLastResolvedLanguage() throws {
    let harness = try makeHarness()
    let store = ProfileStore(homeDirectoryOverride: harness.homeURL)
    var settings = AppSettings()
    settings.appLanguage = .zh
    settings.lastResolvedLanguage = .zh

    try store.saveSettings(settings)
    let result = store.loadSettingsResult()

    #expect(result.settings.appLanguage == .zh)
    #expect(result.settings.lastResolvedLanguage == .zh)
}

@MainActor
@Test
func sessionManagerCoordinatorPersistsResolvedLanguageAndUiConfig() throws {
    try withExclusiveAppLocalization {
        let harness = try makeHarness()
        let store = ProfileStore(homeDirectoryOverride: harness.homeURL)
        let coordinator = SessionManagerCoordinator(store: store, launcher: SessionManagerLauncher())
        var settings = AppSettings()
        settings.appLanguage = .zh

        let result = coordinator.synchronizeLocalizationState(settings: settings)

        #expect(result.notice == nil)
        #expect(result.settings.lastResolvedLanguage == .zh)
        #expect(store.loadSettingsResult().settings.lastResolvedLanguage == .zh)
        #expect(store.loadSessionManagerUIConfig() == SessionManagerUIConfig(language: .zh))
    }
}

@MainActor
@Test
func sessionManagerCoordinatorSurfacesUiConfigWriteFailures() throws {
    try withExclusiveAppLocalization {
        let harness = try makeHarness()
        let store = ProfileStore(homeDirectoryOverride: harness.homeURL)
        let coordinator = SessionManagerCoordinator(store: store, launcher: SessionManagerLauncher())
        var settings = AppSettings()
        settings.appLanguage = .zh

        let result = coordinator.synchronizeLocalizationState(
            settings: settings,
            uiConfigWriter: FailingWriter()
        )

        #expect(result.notice?.kind == .warning)
        #expect(result.notice?.message.contains("Session Manager") == true)
        #expect(result.settings.lastResolvedLanguage == .zh)
        #expect(store.loadSettingsResult().settings.lastResolvedLanguage == .zh)
        #expect(store.loadSessionManagerUIConfig() == nil)
    }
}

private struct FailingWriter: FileDataWriting {
    func write(_ data: Data, to url: URL) throws {
        throw NSError(domain: "CodexQuotaViewerTests", code: 99, userInfo: [
            NSLocalizedDescriptionKey: "disk full"
        ])
    }
}
