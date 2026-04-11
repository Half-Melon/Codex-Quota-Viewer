import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func localSQLiteQueryErrorSqliteUnavailableMessageFollowsActiveLanguage() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.zh, preferredLanguages: ["zh-Hans-CN"])

        #expect(LocalSQLiteQueryError.sqliteUnavailable.errorDescription == "检查本地线程元数据需要 sqlite3。")
    }
}

@Test
func localThreadSyncInspectorNoLocalThreadsMessageFollowsActiveLanguage() throws {
    try withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.zh, preferredLanguages: ["zh-Hans-CN"])
        let harness = try makeHarness()
        let store = ProfileStore(homeDirectoryOverride: harness.homeURL)
        let inspector = LocalThreadSyncInspector()

        let status = inspector.inspect(store: store, expectedProviderID: nil)

        #expect(status == .unavailable("未发现本地线程。"))
    }
}

@Test
func localThreadSyncInspectorStateDatabaseReadFailureMessageFollowsActiveLanguage() throws {
    try withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.zh, preferredLanguages: ["zh-Hans-CN"])
        let harness = try makeHarness()
        let store = ProfileStore(homeDirectoryOverride: harness.homeURL)

        try FileManager.default.createDirectory(
            at: store.stateDatabaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: store.stateDatabaseURL)

        let inspector = LocalThreadSyncInspector(queryRunner: { _, _ in
            throw NSError(domain: "SafeSwitchThreadSyncLocalizationTests", code: 1)
        })

        let status = inspector.inspect(store: store, expectedProviderID: nil)

        #expect(status == .unavailable("无法读取状态数据库。"))
    }
}
