import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func vaultQuotaCacheStorePersistsSnapshotRecords() throws {
    let harness = try makeHarness()
    let store = VaultQuotaCacheStore(cacheURL: harness.appSupportURL.appendingPathComponent("quota-cache.json"))
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let records = [
        VaultQuotaSnapshotRecord(
            accountID: "acct-chatgpt",
            snapshot: makeSnapshot(email: "primary@example.com", primaryRemaining: 72, secondaryRemaining: 61, fetchedAt: now),
            healthStatus: .healthy,
            errorSummary: nil,
            fetchedAt: now,
            authMode: .chatgpt,
            isCurrent: true
        ),
        VaultQuotaSnapshotRecord(
            accountID: "acct-api",
            snapshot: nil,
            healthStatus: .healthy,
            errorSummary: "Official quota unavailable",
            fetchedAt: now,
            authMode: .apiKey,
            isCurrent: false
        ),
    ]

    try store.save(records)
    let loaded = try store.load()

    #expect(loaded == records)
}

@Test
func quotaOverviewStatePrioritizesAvailableProfilesAndLimitsOverviewToFiveRows() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let staleTime = now.addingTimeInterval(-1_000)
        let current = makeProfile(
            id: "current",
            displayName: "current@example.com",
            authMode: .chatgpt,
            snapshot: makeSnapshot(email: "current@example.com", primaryRemaining: 84, secondaryRemaining: 74, fetchedAt: now),
            lastUsedAt: now
        )
        let needsLogin = makeProfile(
            id: "needs-login",
            displayName: "needs-login@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            healthStatus: .needsLogin,
            errorMessage: "Sign in required",
            lastUsedAt: now.addingTimeInterval(-10)
        )
        let expired = makeProfile(
            id: "expired",
            displayName: "expired@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            healthStatus: .expired,
            errorMessage: "Session expired",
            lastUsedAt: now.addingTimeInterval(-20)
        )
        let exhausted = makeProfile(
            id: "exhausted",
            displayName: "exhausted@example.com",
            authMode: .chatgpt,
            snapshot: makeSnapshot(email: "exhausted@example.com", primaryRemaining: 0, secondaryRemaining: 44, fetchedAt: now),
            lastUsedAt: now.addingTimeInterval(-30)
        )
        let stale = makeProfile(
            id: "stale",
            displayName: "stale@example.com",
            authMode: .chatgpt,
            snapshot: makeSnapshot(email: "stale@example.com", primaryRemaining: 65, secondaryRemaining: 58, fetchedAt: staleTime),
            lastUsedAt: now.addingTimeInterval(-40)
        )
        let healthyA = makeProfile(
            id: "healthy-a",
            displayName: "healthy-a@example.com",
            authMode: .chatgpt,
            snapshot: makeSnapshot(email: "healthy-a@example.com", primaryRemaining: 76, secondaryRemaining: 67, fetchedAt: now),
            lastUsedAt: now.addingTimeInterval(-50)
        )
        let healthyB = makeProfile(
            id: "healthy-b",
            displayName: "healthy-b@example.com",
            authMode: .chatgpt,
            snapshot: makeSnapshot(email: "healthy-b@example.com", primaryRemaining: 92, secondaryRemaining: 88, fetchedAt: now),
            lastUsedAt: now.addingTimeInterval(-60)
        )
        let healthyHidden = makeProfile(
            id: "healthy-hidden",
            displayName: "healthy-hidden@example.com",
            authMode: .chatgpt,
            snapshot: makeSnapshot(email: "healthy-hidden@example.com", primaryRemaining: 91, secondaryRemaining: 77, fetchedAt: now),
            lastUsedAt: now.addingTimeInterval(-70)
        )
        let api = makeProfile(
            id: "api",
            displayName: "api account",
            authMode: .apiKey,
            snapshot: nil,
            healthStatus: .healthy,
            errorMessage: nil,
            lastUsedAt: now.addingTimeInterval(-80)
        )

        let state = buildQuotaOverviewState(
            currentProfile: current,
            vaultProfiles: [needsLogin, expired, exhausted, stale, healthyA, healthyB, healthyHidden, api],
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )

        #expect(state.chatGPTCount == 8)
        #expect(state.apiCount == 1)
        #expect(state.boardTiles.count == 5)
        #expect(state.boardTiles.map { $0.profile.id } == ["current", "healthy-a", "healthy-b", "healthy-hidden", "exhausted"])
    }
}

@Test
func quotaOverviewStateBuildsAllAccountsSections() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let current = makeProfile(
            id: "current",
            displayName: "current@example.com",
            authMode: .chatgpt,
            snapshot: makeSnapshot(email: "current@example.com", primaryRemaining: 81, secondaryRemaining: 79, fetchedAt: now),
            lastUsedAt: now
        )
        let exhausted = makeProfile(
            id: "exhausted",
            displayName: "exhausted@example.com",
            authMode: .chatgpt,
            snapshot: makeSnapshot(email: "exhausted@example.com", primaryRemaining: 0, secondaryRemaining: 20, fetchedAt: now),
            healthStatus: .healthy,
            errorMessage: nil,
            lastUsedAt: now.addingTimeInterval(-10)
        )
        let healthy = makeProfile(
            id: "healthy",
            displayName: "healthy@example.com",
            authMode: .chatgpt,
            snapshot: makeSnapshot(email: "healthy@example.com", primaryRemaining: 66, secondaryRemaining: 64, fetchedAt: now),
            lastUsedAt: now.addingTimeInterval(-20)
        )
        let api = makeProfile(
            id: "api",
            displayName: "api account",
            authMode: .apiKey,
            snapshot: nil,
            healthStatus: .healthy,
            errorMessage: nil,
            lastUsedAt: now.addingTimeInterval(-30)
        )

        let state = buildQuotaOverviewState(
            currentProfile: current,
            vaultProfiles: [exhausted, healthy, api],
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )

        #expect(state.sections.map { $0.title } == ["Available Quota", "Quota Exhausted", "API Accounts"])
        #expect(state.sections[0].profiles.map { $0.id } == ["current", "healthy"])
        #expect(state.sections[1].profiles.map { $0.id } == ["exhausted"])
        #expect(state.sections[2].profiles.map { $0.id } == ["api"])
    }
}

@MainActor
@Test
func vaultQuotaRefreshCoordinatorRefreshesChatGPTAccountEvenIfCachedAsCurrent() async {
    let now = Date(timeIntervalSince1970: 1_800_000_100)
    let refreshedAt = now.addingTimeInterval(120)
    let currentRuntime = makeRuntimeMaterial(id: "current-runtime", authMode: .chatgpt)
    let staleRuntime = makeRuntimeMaterial(id: "stale-runtime", authMode: .chatgpt)
    let currentRecord = makeVaultRecord(
        id: stableAccountRecordID(for: currentRuntime),
        displayName: "current@example.com",
        authMode: .chatgpt,
        runtimeMaterial: currentRuntime
    )
    let staleRecord = makeVaultRecord(
        id: stableAccountRecordID(for: staleRuntime),
        displayName: "stale@example.com",
        authMode: .chatgpt,
        runtimeMaterial: staleRuntime
    )
    let currentProfile = buildProviderProfile(
        id: currentRecord.id,
        fallbackDisplayName: "current@example.com",
        source: .current,
        runtimeMaterial: currentRuntime,
        snapshot: makeSnapshot(
            email: "current@example.com",
            primaryRemaining: 81,
            secondaryRemaining: 79,
            fetchedAt: now
        ),
        healthStatus: .healthy,
        errorMessage: nil,
        isCurrent: true,
        quotaFetchedAt: now
    )

    var fetchCount = 0
    let coordinator = VaultQuotaRefreshCoordinator { runtimeMaterial in
        fetchCount += 1
        #expect(stableAccountRecordID(for: runtimeMaterial) == staleRecord.id)
        return makeSnapshot(
            email: "refreshed@example.com",
            primaryRemaining: 68,
            secondaryRemaining: 55,
            fetchedAt: refreshedAt
        )
    }

    let finalRecords = await withCheckedContinuation { continuation in
        var didResume = false
        coordinator.requestRefresh(
            .init(
                currentProfile: currentProfile,
                vaultAccounts: [currentRecord, staleRecord],
                cachedRecords: [
                    VaultQuotaSnapshotRecord(
                        accountID: staleRecord.id,
                        snapshot: makeSnapshot(
                            email: "stale@example.com",
                            primaryRemaining: 10,
                            secondaryRemaining: 5,
                            fetchedAt: now.addingTimeInterval(-600)
                        ),
                        healthStatus: .healthy,
                        errorSummary: nil,
                        fetchedAt: now.addingTimeInterval(-600),
                        authMode: .chatgpt,
                        isCurrent: true
                    )
                ]
            )
        ) { records in
            guard !didResume,
                  let refreshed = records.first(where: {
                      $0.accountID == staleRecord.id && $0.snapshot?.account.email == "refreshed@example.com"
                  }) else {
                return
            }
            didResume = true
            continuation.resume(returning: records)
            #expect(refreshed.isCurrent == false)
        }
    }

    #expect(fetchCount == 1)
    #expect(finalRecords.map(\.accountID).sorted() == [currentRecord.id, staleRecord.id].sorted())
}

@MainActor
@Test
func vaultQuotaRefreshCoordinatorDropsCachedAccountsThatAreNoLongerSaved() async {
    let now = Date(timeIntervalSince1970: 1_800_000_200)
    let currentRuntime = makeRuntimeMaterial(id: "current-runtime", authMode: .chatgpt)
    let currentRecord = makeVaultRecord(
        id: stableAccountRecordID(for: currentRuntime),
        displayName: "current@example.com",
        authMode: .chatgpt,
        runtimeMaterial: currentRuntime
    )
    let currentProfile = buildProviderProfile(
        id: currentRecord.id,
        fallbackDisplayName: "current@example.com",
        source: .current,
        runtimeMaterial: currentRuntime,
        snapshot: makeSnapshot(
            email: "current@example.com",
            primaryRemaining: 81,
            secondaryRemaining: 79,
            fetchedAt: now
        ),
        healthStatus: .healthy,
        errorMessage: nil,
        isCurrent: true,
        quotaFetchedAt: now
    )
    let coordinator = VaultQuotaRefreshCoordinator { _ in
        Issue.record("snapshotFetcher should not run for the current-only request")
        return makeSnapshot(
            email: "unexpected@example.com",
            primaryRemaining: 0,
            secondaryRemaining: 0,
            fetchedAt: now
        )
    }

    let records = await withCheckedContinuation { continuation in
        var didResume = false
        coordinator.requestRefresh(
            .init(
                currentProfile: currentProfile,
                vaultAccounts: [currentRecord],
                cachedRecords: [
                    VaultQuotaSnapshotRecord(
                        accountID: "ghost-account",
                        snapshot: makeSnapshot(
                            email: "ghost@example.com",
                            primaryRemaining: 22,
                            secondaryRemaining: 18,
                            fetchedAt: now.addingTimeInterval(-300)
                        ),
                        healthStatus: .healthy,
                        errorSummary: nil,
                        fetchedAt: now.addingTimeInterval(-300),
                        authMode: .chatgpt,
                        isCurrent: false
                    )
                ]
            )
        ) { latest in
            guard !didResume, latest.count == 1 else {
                return
            }
            didResume = true
            continuation.resume(returning: latest)
        }
    }

    #expect(records.count == 1)
    #expect(records.first?.accountID == currentRecord.id)
}

@Test
func exhaustedAccountMenuTextShowsResetScheduleInsteadOfPercentages() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let exhausted = makeProfile(
            id: "exhausted",
            displayName: "exhausted@example.com",
            authMode: .chatgpt,
            snapshot: makeSnapshot(email: "exhausted@example.com", primaryRemaining: 0, secondaryRemaining: 20, fetchedAt: now),
            healthStatus: .healthy,
            errorMessage: nil,
            lastUsedAt: now
        )

        let text = allAccountsMenuText(
            for: exhausted,
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )

        let timeFormatter = DateFormatter()
        timeFormatter.locale = AppLocalization.locale
        timeFormatter.dateFormat = "HH:mm"

        let dateFormatter = DateFormatter()
        dateFormatter.locale = AppLocalization.locale
        dateFormatter.setLocalizedDateFormatFromTemplate("MMM d")

        #expect(text.contains("5h \(timeFormatter.string(from: Date(timeIntervalSince1970: 1_800_000_360)))"))
        #expect(text.contains("1w \(dateFormatter.string(from: Date(timeIntervalSince1970: 1_800_086_400)))"))
        #expect(text.contains("5h 0%") == false)
    }
}

@Test
func quotaOverviewDeduplicatesCurrentAndSavedProfilesByStableIdentity() {
    let now = Date(timeIntervalSince1970: 1_800_000_300)
    let currentRuntime = ProfileRuntimeMaterial(
        authData: Data(
            """
            {"auth_mode":"chatgpt","tokens":{"access_token":"token-current","account_id":"acct-identity-1"}}
            """.utf8
        ),
        configData: Data("model_provider = \"openai\"\n".utf8)
    )
    let savedRuntime = ProfileRuntimeMaterial(
        authData: Data(
            """
            {"auth_mode":"chatgpt","tokens":{"access_token":"token-saved","account_id":"acct-identity-1"}}
            """.utf8
        ),
        configData: Data(
            """
            model_provider = "custom"

            [model_providers.custom]
            name = "custom"
            requires_openai_auth = true
            base_url = "https://shell.wyzai.top/v1"
            """.utf8
        )
    )

    let current = buildProviderProfile(
        id: stableAccountRecordID(for: currentRuntime),
        fallbackDisplayName: "current@example.com",
        source: .current,
        runtimeMaterial: currentRuntime,
        snapshot: makeSnapshot(
            email: "current@example.com",
            primaryRemaining: 81,
            secondaryRemaining: 72,
            fetchedAt: now
        ),
        healthStatus: .healthy,
        errorMessage: nil,
        isCurrent: true,
        quotaFetchedAt: now
    )
    let saved = buildProviderProfile(
        id: stableAccountRecordID(for: savedRuntime),
        fallbackDisplayName: "Kris Team",
        source: .vault,
        runtimeMaterial: savedRuntime,
        snapshot: nil,
        healthStatus: .healthy,
        errorMessage: nil,
        isCurrent: false,
        lastUsedAt: now.addingTimeInterval(-60),
        quotaFetchedAt: nil
    )

    let state = buildQuotaOverviewState(
        currentProfile: current,
        vaultProfiles: [saved],
        refreshIntervalPreset: .fiveMinutes,
        now: now
    )

    #expect(state.chatGPTCount == 1)
    #expect(state.boardTiles.map { $0.profile.id } == [stableAccountRecordID(for: currentRuntime)])
    #expect(state.sections.count == 1)
    #expect(state.sections[0].profiles.count == 1)
}

@Test
func freeWeeklyOnlyAccountUsesWeeklyLabelsAndExhaustedSection() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let free = makeProfile(
            id: "free",
            displayName: "ai.krisxu@gmail.com",
            authMode: .chatgpt,
            snapshot: makeFreeWeeklySnapshot(
                email: "ai.krisxu@gmail.com",
                weeklyRemaining: 0,
                fetchedAt: now
            ),
            healthStatus: .healthy,
            errorMessage: nil,
            lastUsedAt: now
        )

        let state = buildQuotaOverviewState(
            currentProfile: free,
            vaultProfiles: [],
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )

        #expect(quotaTileState(for: free, refreshIntervalPreset: .fiveMinutes, now: now) == .lowQuota)
        #expect(state.sections.map { $0.title } == ["Quota Exhausted"])
        #expect(state.sections[0].profiles.map { $0.id } == ["free"])
        #expect(state.boardTiles.map { $0.profile.id } == ["free"])
        #expect(state.boardTiles[0].primaryText == "1w 0%")
        #expect(state.boardTiles[0].secondaryText.contains("1w "))

        let text = allAccountsMenuText(
            for: free,
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )
        #expect(text.contains("5h") == false)
        #expect(text.contains("1w") == true)
    }
}

@Test
func freeWeeklyOnlyAccountWithQuotaRemainsAvailable() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_200)
        let free = makeProfile(
            id: "free",
            displayName: "ai.krisxu@gmail.com",
            authMode: .chatgpt,
            snapshot: makeFreeWeeklySnapshot(
                email: "ai.krisxu@gmail.com",
                weeklyRemaining: 63,
                fetchedAt: now
            ),
            healthStatus: .healthy,
            errorMessage: nil,
            lastUsedAt: now
        )

        let state = buildQuotaOverviewState(
            currentProfile: free,
            vaultProfiles: [],
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )

        #expect(quotaTileState(for: free, refreshIntervalPreset: .fiveMinutes, now: now) == .healthy)
        #expect(state.sections.map { $0.title } == ["Available Quota"])
        #expect(state.sections[0].profiles.map { $0.id } == ["free"])
        #expect(state.boardTiles[0].primaryText == "1w 63%")
        #expect(state.boardTiles[0].secondaryText.isEmpty)

        let text = allAccountsMenuText(
            for: free,
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )
        #expect(text == "ai.krisxu@gmail.com · 1w 63%")
    }
}

private func makeProfile(
    id: String,
    displayName: String,
    authMode: CodexAuthMode,
    snapshot: CodexSnapshot?,
    healthStatus: ProfileHealthStatus = .healthy,
    errorMessage: String? = nil,
    lastUsedAt: Date? = nil
) -> ProviderProfile {
    let authData: Data
    let configData: Data
    if authMode == .apiKey {
        authData = Data(#"{"OPENAI_API_KEY":"sk-\#(id)","auth_mode":"apikey"}"#.utf8)
        configData = Data("""
        model_provider = "openai"
        base_url = "https://api.example.com/v1"
        model = "gpt-5.4"
        """.utf8)
    } else {
        authData = Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"token-\#(id)"}}"#.utf8)
        configData = Data(#"model_provider = "openai""#.utf8)
    }

    return ProviderProfile(
        id: id,
        displayName: displayName,
        source: .vault,
        runtimeMaterial: ProfileRuntimeMaterial(
            authData: authData,
            configData: configData
        ),
        authMode: authMode,
        providerID: authMode == .apiKey ? "openai" : "openai",
        providerDisplayName: authMode == .apiKey ? "openai" : nil,
        baseURLHost: authMode == .apiKey ? "api.example.com" : nil,
        model: authMode == .apiKey ? "gpt-5.4" : nil,
        snapshot: snapshot,
        healthStatus: healthStatus,
        errorMessage: errorMessage,
        isCurrent: id == "current",
        managedFileURLs: [],
        lastUsedAt: lastUsedAt
    )
}

private func makeRuntimeMaterial(id: String, authMode: CodexAuthMode) -> ProfileRuntimeMaterial {
    let authData: Data
    let configData: Data
    if authMode == .apiKey {
        authData = Data(#"{"OPENAI_API_KEY":"sk-\#(id)","auth_mode":"apikey"}"#.utf8)
        configData = Data(
            """
            model_provider = "openai"
            base_url = "https://api.example.com/v1"
            model = "gpt-5.4"
            """.utf8
        )
    } else {
        authData = Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"token-\#(id)","account_id":"\#(id)"}}"#.utf8)
        configData = Data(#"model_provider = "openai""#.utf8)
    }

    return ProfileRuntimeMaterial(authData: authData, configData: configData)
}

private func makeVaultRecord(
    id: String,
    displayName: String,
    authMode: CodexAuthMode,
    runtimeMaterial: ProfileRuntimeMaterial
) -> VaultAccountRecord {
    let directoryURL = URL(fileURLWithPath: "/tmp/\(id)", isDirectory: true)
    let metadata = VaultAccountMetadata(
        id: id,
        displayName: displayName,
        authMode: authMode,
        providerID: authMode == .apiKey ? "openai" : "openai",
        baseURL: authMode == .apiKey ? "https://api.example.com/v1" : nil,
        model: authMode == .apiKey ? "gpt-5.4" : nil,
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        lastUsedAt: nil,
        source: .currentRuntime,
        runtimeKey: stableAccountIdentityKey(for: runtimeMaterial)
    )

    return VaultAccountRecord(
        metadata: metadata,
        runtimeMaterial: runtimeMaterial,
        directoryURL: directoryURL,
        metadataURL: directoryURL.appendingPathComponent("metadata.json"),
        authURL: directoryURL.appendingPathComponent("auth.json"),
        configURL: directoryURL.appendingPathComponent("config.toml")
    )
}

private func makeSnapshot(
    email: String,
    primaryRemaining: Double,
    secondaryRemaining: Double,
    fetchedAt: Date
) -> CodexSnapshot {
    CodexSnapshot(
        account: CodexAccount(type: "chatgpt", email: email, planType: "plus"),
        rateLimits: RateLimitSnapshot(
            limitId: nil,
            limitName: nil,
            primary: RateLimitWindow(usedPercent: 100 - primaryRemaining, windowDurationMins: 300, resetsAt: 1_800_000_360),
            secondary: RateLimitWindow(usedPercent: 100 - secondaryRemaining, windowDurationMins: 10_080, resetsAt: 1_800_086_400),
            planType: "plus"
        ),
        fetchedAt: fetchedAt
    )
}

private func makeFreeWeeklySnapshot(
    email: String,
    weeklyRemaining: Double,
    fetchedAt: Date
) -> CodexSnapshot {
    CodexSnapshot(
        account: CodexAccount(type: "chatgpt", email: email, planType: "free"),
        rateLimits: RateLimitSnapshot(
            limitId: "codex",
            limitName: nil,
            primary: RateLimitWindow(
                usedPercent: 100 - weeklyRemaining,
                windowDurationMins: 10_080,
                resetsAt: 1_800_086_400
            ),
            secondary: nil,
            planType: "free"
        ),
        fetchedAt: fetchedAt
    )
}
