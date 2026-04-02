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
