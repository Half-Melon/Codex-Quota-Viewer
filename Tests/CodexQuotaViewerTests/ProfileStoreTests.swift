import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func profileStoreAccountMutationFilesStayWithinVaultAndSettingsScope() throws {
    let harness = try makeHarness()
    let store = ProfileStore(
        baseURL: harness.appSupportURL,
        currentAuthURL: harness.codexHomeURL.appendingPathComponent("auth.json", isDirectory: false),
        homeDirectoryOverride: harness.homeURL
    )
    let accountMetadataURL = store.accountsRootURL
        .appendingPathComponent("acct-1", isDirectory: true)
        .appendingPathComponent("metadata.json", isDirectory: false)

    let urls = store.accountMutationFileURLs(additionalFiles: [accountMetadataURL])
    let paths = Set(urls.map(\.path))

    #expect(paths.contains(store.settingsURL.path))
    #expect(paths.contains(store.accountsIndexURL.path))
    #expect(paths.contains(accountMetadataURL.path))
    #expect(paths.contains(store.currentAuthURL.path) == false)
    #expect(paths.contains(store.currentConfigURL.path) == false)
    #expect(paths.contains(store.stateDatabaseURL.path) == false)
    #expect(paths.contains(store.sessionIndexURL.path) == false)
    #expect(paths.contains(store.sessionManagerDatabaseURL.path) == false)
}

@Test
func profileStoreDerivesCodexHomeFromCustomCurrentAuthURL() throws {
    let harness = try makeHarness()
    let customCodexHomeURL = harness.homeURL
        .appendingPathComponent(".codex-alt", isDirectory: true)
    let customAuthURL = URL(
        fileURLWithPath: customCodexHomeURL
            .appendingPathComponent(".", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
            .path,
        isDirectory: false
    )

    let store = ProfileStore(
        baseURL: harness.appSupportURL,
        currentAuthURL: customAuthURL,
        homeDirectoryOverride: harness.homeURL
    )

    #expect(store.codexHomeURL.path == customCodexHomeURL.path)
    #expect(
        store.currentAuthURL.path
            == customCodexHomeURL.appendingPathComponent("auth.json", isDirectory: false).path
    )
    #expect(
        store.currentConfigURL.path
            == customCodexHomeURL.appendingPathComponent("config.toml", isDirectory: false).path
    )
    #expect(
        store.sessionsRootURL.path
            == customCodexHomeURL.appendingPathComponent("sessions", isDirectory: true).path
    )
}
