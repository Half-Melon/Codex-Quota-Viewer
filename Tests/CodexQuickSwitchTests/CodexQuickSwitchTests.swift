import Foundation
import Testing

@testable import CodexQuickSwitch

@Test
func createProfilePersistsMetadataAndCredentialWithoutLegacySidecar() throws {
    let harness = try TestHarness()
    let snapshot = sampleSnapshot(email: "one@example.com")
    let authData = Data("auth-one".utf8)

    let profile = try harness.store.createProfile(
        name: "One",
        authData: authData,
        snapshot: snapshot.cached
    )

    let loadedProfiles = harness.store.loadProfiles()
    #expect(loadedProfiles.count == 1)
    #expect(loadedProfiles.first?.id == profile.id)
    #expect(loadedProfiles.first?.name == "One")
    #expect(loadedProfiles.first?.cachedSnapshot == snapshot.cached)

    let files = try FileManager.default.contentsOfDirectory(
        at: harness.store.profilesDirectoryURL,
        includingPropertiesForKeys: nil
    )
    #expect(!files.contains { $0.lastPathComponent.hasSuffix(".auth.json") })
    #expect(try harness.credentialStore.read(account: profile.id.uuidString) == authData)
}

@Test
func migrationMovesLegacySidecarIntoCredentialStoreAndDeletesPlaintextFile() throws {
    let harness = try TestHarness()
    let profile = makeProfile(
        name: "Legacy",
        snapshot: sampleSnapshot(email: "legacy@example.com").cached
    )
    try harness.store.save(profile)

    let legacyURL = harness.store.profilesDirectoryURL
        .appendingPathComponent("\(profile.id.uuidString).auth.json", isDirectory: false)
    let legacyData = Data("legacy-auth".utf8)
    try legacyData.write(to: legacyURL, options: .atomic)

    var settings = AppSettings(lastActiveProfileID: nil)
    let result = harness.store.migrateLegacyCredentialsIfNeeded(settings: &settings)

    #expect(result.migratedCount == 1)
    #expect(result.errors.isEmpty)
    #expect(settings.storageVersion == AppSettings.currentStorageVersion)
    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    #expect(try harness.credentialStore.read(account: profile.id.uuidString) == legacyData)
}

@Test
func loadProfilesResultReportsCorruptedProfileFile() throws {
    let harness = try TestHarness()
    let profile = try harness.store.createProfile(
        name: "Healthy",
        authData: Data("healthy-auth".utf8),
        snapshot: sampleSnapshot(email: "healthy@example.com").cached
    )

    let brokenURL = harness.store.profilesDirectoryURL
        .appendingPathComponent("\(UUID().uuidString).json", isDirectory: false)
    try Data("not-json".utf8).write(to: brokenURL, options: .atomic)

    let result = harness.store.loadProfilesResult()

    #expect(result.profiles.count == 1)
    #expect(result.profiles.first?.id == profile.id)
    #expect(result.issues.count == 1)
    #expect(result.issues[0].message.contains(brokenURL.lastPathComponent))
}

@Test
func loadSettingsResultReportsCorruptedSettingsFile() throws {
    let harness = try TestHarness()
    try FileManager.default.createDirectory(
        at: harness.store.settingsURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("not-json".utf8).write(to: harness.store.settingsURL, options: .atomic)

    let result = harness.store.loadSettingsResult()

    #expect(result.settings.refreshIntervalPreset == .fiveMinutes)
    #expect(result.settings.launchAtLoginEnabled == false)
    #expect(result.issues.count == 1)
    #expect(result.issues[0].message.contains("settings.json"))
}

@Test
func resolveActiveProfilePrefersStoredIDOverEmailFallback() {
    let snapshotA = sampleSnapshot(email: "a@example.com").cached
    let snapshotB = sampleSnapshot(email: "b@example.com").cached
    let profileA = makeProfile(name: "A", snapshot: snapshotA)
    let profileB = makeProfile(name: "B", snapshot: snapshotB)

    let resolved = resolveActiveProfileID(
        lastActiveProfileID: profileA.id,
        profiles: [profileA, profileB],
        currentSnapshot: sampleSnapshot(email: "b@example.com")
    )

    #expect(resolved == profileA.id)
}

@Test
func classifyProfileHealthMapsErrorsToExpectedStates() {
    #expect(classifyProfileHealth(from: CredentialStoreError.itemNotFound) == .readFailure)
    #expect(classifyProfileHealth(from: CodexRPCError.notLoggedIn) == .needsLogin)
    #expect(classifyProfileHealth(from: CodexRPCError.rpc("401 unauthorized")) == .needsLogin)
    #expect(classifyProfileHealth(from: CodexRPCError.rpc("session expired")) == .expired)
}

@Test
func rateLimitWindowDisplaysRemainingPercentInsteadOfUsedPercent() {
    let window = RateLimitWindow(
        usedPercent: 35,
        windowDurationMins: 300,
        resetsAt: nil
    )

    #expect(window.remainingPercent == 65)
    #expect(window.remainingPercentText == "65%")
}

@Test
func deleteProfileRemovesMetadataAndCredential() throws {
    let harness = try TestHarness()
    let profile = try harness.store.createProfile(
        name: "DeleteMe",
        authData: Data("delete-auth".utf8),
        snapshot: sampleSnapshot(email: "delete@example.com").cached
    )

    try harness.store.deleteProfile(id: profile.id)

    let metadataURL = harness.store.profilesDirectoryURL
        .appendingPathComponent("\(profile.id.uuidString).json", isDirectory: false)
    #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
    #expect(try !harness.credentialStore.contains(account: profile.id.uuidString))
}

@MainActor
@Test
func switchFailureRollsBackAuthAndRelaunchesCodex() async throws {
    let harness = try TestHarness()
    let snapshotA = sampleSnapshot(email: "a@example.com")
    let snapshotB = sampleSnapshot(email: "b@example.com")
    let authA = Data("auth-a".utf8)
    let authB = Data("auth-b".utf8)

    let profileA = try harness.store.createProfile(
        name: "A",
        authData: authA,
        snapshot: snapshotA.cached
    )
    let profileB = try harness.store.createProfile(
        name: "B",
        authData: authB,
        snapshot: snapshotB.cached
    )
    try harness.store.overwriteCurrentAuthData(authA)

    let rpcClient = FakeRPCClient(
        fetchSnapshotHandler: { data in
            if data == authB { return snapshotB }
            if data == authA { return snapshotA }
            throw NSError(domain: "test", code: 1)
        },
        fetchCurrentSnapshotHandler: {
            snapshotA
        }
    )
    let appManager = FakeAppManager()
    let switchService = ProfileSwitchService(
        store: harness.store,
        rpcClient: rpcClient,
        appManager: appManager
    )

    do {
        _ = try await switchService.switchToProfile(
            targetProfile: profileB,
            activeProfileID: profileA.id,
            currentSnapshot: snapshotA,
            autoOpenCodexAfterSwitch: true
        )
        Issue.record("Expected rollback error")
    } catch let error as ProfileSwitchError {
        switch error {
        case .rolledBack:
            break
        default:
            Issue.record("Unexpected error: \(error)")
        }
    }

    #expect(try harness.store.currentAuthData() == authA)
    #expect(try harness.store.readAuthData(for: profileA.id) == authA)
    #expect(appManager.terminateCallCount == 1)
    #expect(appManager.launchCallCount == 1)
}

private final class TestHarness {
    let rootURL: URL
    let credentialStore: InMemoryCredentialStore
    let store: ProfileStore

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexQuickSwitchTests-\(UUID().uuidString)", isDirectory: true)
        credentialStore = InMemoryCredentialStore()

        let baseURL = rootURL.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let currentAuthURL = rootURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)

        store = ProfileStore(
            baseURL: baseURL,
            currentAuthURL: currentAuthURL,
            credentialStore: credentialStore
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class InMemoryCredentialStore: CredentialStore {
    private var items: [String: Data] = [:]

    func contains(account: String) throws -> Bool {
        items[account] != nil
    }

    func read(account: String) throws -> Data {
        guard let data = items[account] else {
            throw CredentialStoreError.itemNotFound
        }
        return data
    }

    func upsert(data: Data, account: String) throws {
        items[account] = data
    }

    func delete(account: String) throws {
        items.removeValue(forKey: account)
    }
}

private final class FakeRPCClient: @unchecked Sendable, CodexRPCClientProtocol {
    private let fetchSnapshotHandler: @Sendable (Data) async throws -> CodexSnapshot
    private let fetchCurrentSnapshotHandler: @Sendable () async throws -> CodexSnapshot

    init(
        fetchSnapshotHandler: @escaping @Sendable (Data) async throws -> CodexSnapshot,
        fetchCurrentSnapshotHandler: @escaping @Sendable () async throws -> CodexSnapshot
    ) {
        self.fetchSnapshotHandler = fetchSnapshotHandler
        self.fetchCurrentSnapshotHandler = fetchCurrentSnapshotHandler
    }

    func fetchCurrentSnapshot() async throws -> CodexSnapshot {
        try await fetchCurrentSnapshotHandler()
    }

    func fetchSnapshot(authData: Data) async throws -> CodexSnapshot {
        try await fetchSnapshotHandler(authData)
    }
}

private final class FakeAppManager: @unchecked Sendable, CodexAppManaging {
    private(set) var terminateCallCount = 0
    private(set) var launchCallCount = 0

    func isCodexRunning() -> Bool {
        true
    }

    func terminateCodex() async throws {
        terminateCallCount += 1
    }

    func launchCodex(activate: Bool) throws {
        launchCallCount += 1
    }
}

private func makeProfile(
    name: String,
    snapshot: CachedProfileSnapshot?
) -> CodexProfile {
    let now = Date()
    return CodexProfile(
        id: UUID(),
        name: name,
        cachedSnapshot: snapshot,
        createdAt: now,
        updatedAt: now
    )
}

private func sampleSnapshot(email: String) -> CodexSnapshot {
    CodexSnapshot(
        account: CodexAccount(
            type: "chatgpt",
            email: email,
            planType: "team"
        ),
        rateLimits: RateLimitSnapshot(
            limitId: "codex",
            limitName: nil,
            primary: RateLimitWindow(
                usedPercent: 50,
                windowDurationMins: 300,
                resetsAt: 1_774_348_129
            ),
            secondary: RateLimitWindow(
                usedPercent: 15,
                windowDurationMins: 10_080,
                resetsAt: 1_774_934_929
            ),
            planType: "team"
        ),
        fetchedAt: Date(timeIntervalSince1970: 1_774_000_000)
    )
}
