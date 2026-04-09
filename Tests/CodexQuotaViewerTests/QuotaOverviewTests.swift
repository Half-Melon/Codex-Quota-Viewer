import Foundation
import Testing

@testable import CodexQuotaViewer

actor ConcurrentRefreshTracker {
    private(set) var activeCount = 0
    private(set) var maxActiveCount = 0

    func begin() {
        activeCount += 1
        maxActiveCount = max(maxActiveCount, activeCount)
    }

    func end() {
        activeCount -= 1
    }
}

@Test
func vaultQuotaCacheStorePersistsSnapshotRecords() throws {
    let harness = try makeHarness()
    let store = VaultQuotaCacheStore(cacheURL: harness.appSupportURL.appendingPathComponent("quota-cache.json"))
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let records = [
        VaultQuotaSnapshotRecord(
            accountID: "acct-chatgpt",
            snapshot: makeTestSnapshot(email: "primary@example.com", primaryRemaining: 72, secondaryRemaining: 61, fetchedAt: now),
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
        let current = makeTestProviderProfile(
            id: "current",
            displayName: "current@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(email: "current@example.com", primaryRemaining: 84, secondaryRemaining: 74, fetchedAt: now),
            isCurrent: true,
            lastUsedAt: now
        )
        let needsLogin = makeTestProviderProfile(
            id: "needs-login",
            displayName: "needs-login@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            lastUsedAt: now.addingTimeInterval(-10),
            healthStatus: .needsLogin,
            errorMessage: "Sign in required"
        )
        let expired = makeTestProviderProfile(
            id: "expired",
            displayName: "expired@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            lastUsedAt: now.addingTimeInterval(-20),
            healthStatus: .expired,
            errorMessage: "Session expired"
        )
        let exhausted = makeTestProviderProfile(
            id: "exhausted",
            displayName: "exhausted@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(email: "exhausted@example.com", primaryRemaining: 0, secondaryRemaining: 44, fetchedAt: now),
            lastUsedAt: now.addingTimeInterval(-30)
        )
        let stale = makeTestProviderProfile(
            id: "stale",
            displayName: "stale@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(email: "stale@example.com", primaryRemaining: 65, secondaryRemaining: 58, fetchedAt: staleTime),
            lastUsedAt: now.addingTimeInterval(-40)
        )
        let healthyA = makeTestProviderProfile(
            id: "healthy-a",
            displayName: "healthy-a@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(email: "healthy-a@example.com", primaryRemaining: 76, secondaryRemaining: 67, fetchedAt: now),
            lastUsedAt: now.addingTimeInterval(-50)
        )
        let healthyB = makeTestProviderProfile(
            id: "healthy-b",
            displayName: "healthy-b@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(email: "healthy-b@example.com", primaryRemaining: 92, secondaryRemaining: 88, fetchedAt: now),
            lastUsedAt: now.addingTimeInterval(-60)
        )
        let healthyHidden = makeTestProviderProfile(
            id: "healthy-hidden",
            displayName: "healthy-hidden@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(email: "healthy-hidden@example.com", primaryRemaining: 91, secondaryRemaining: 77, fetchedAt: now),
            lastUsedAt: now.addingTimeInterval(-70)
        )
        let api = makeTestProviderProfile(
            id: "api",
            displayName: "api account",
            authMode: .apiKey,
            snapshot: nil,
            lastUsedAt: now.addingTimeInterval(-80),
            healthStatus: .healthy,
            errorMessage: nil
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
        let current = makeTestProviderProfile(
            id: "current",
            displayName: "current@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(email: "current@example.com", primaryRemaining: 81, secondaryRemaining: 79, fetchedAt: now),
            isCurrent: true,
            lastUsedAt: now
        )
        let exhausted = makeTestProviderProfile(
            id: "exhausted",
            displayName: "exhausted@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(email: "exhausted@example.com", primaryRemaining: 0, secondaryRemaining: 20, fetchedAt: now),
            lastUsedAt: now.addingTimeInterval(-10),
            healthStatus: .healthy,
            errorMessage: nil
        )
        let healthy = makeTestProviderProfile(
            id: "healthy",
            displayName: "healthy@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(email: "healthy@example.com", primaryRemaining: 66, secondaryRemaining: 64, fetchedAt: now),
            lastUsedAt: now.addingTimeInterval(-20)
        )
        let api = makeTestProviderProfile(
            id: "api",
            displayName: "api account",
            authMode: .apiKey,
            snapshot: nil,
            lastUsedAt: now.addingTimeInterval(-30),
            healthStatus: .healthy,
            errorMessage: nil
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
    let currentRuntime = makeTestRuntimeMaterial(id: "current-runtime", authMode: .chatgpt)
    let staleRuntime = makeTestRuntimeMaterial(id: "stale-runtime", authMode: .chatgpt)
    let currentRecord = makeTestVaultRecord(
        from: makeTestProviderProfile(
            id: stableAccountRecordID(for: currentRuntime),
            displayName: "current@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            runtimeMaterial: currentRuntime
        ),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let staleRecord = makeTestVaultRecord(
        from: makeTestProviderProfile(
            id: stableAccountRecordID(for: staleRuntime),
            displayName: "stale@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            runtimeMaterial: staleRuntime
        ),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let currentProfile = buildProviderProfile(
        id: currentRecord.id,
        fallbackDisplayName: "current@example.com",
        source: .current,
        runtimeMaterial: currentRuntime,
        snapshot: makeTestSnapshot(
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
        return makeTestSnapshot(
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
                        snapshot: makeTestSnapshot(
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
    let currentRuntime = makeTestRuntimeMaterial(id: "current-runtime", authMode: .chatgpt)
    let currentRecord = makeTestVaultRecord(
        from: makeTestProviderProfile(
            id: stableAccountRecordID(for: currentRuntime),
            displayName: "current@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            runtimeMaterial: currentRuntime
        ),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let currentProfile = buildProviderProfile(
        id: currentRecord.id,
        fallbackDisplayName: "current@example.com",
        source: .current,
        runtimeMaterial: currentRuntime,
        snapshot: makeTestSnapshot(
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
        return makeTestSnapshot(
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
                        snapshot: makeTestSnapshot(
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

@MainActor
@Test
func vaultQuotaRefreshCoordinatorCoalescesEquivalentRequestsWithoutSecondFetchRound() async {
    let now = Date(timeIntervalSince1970: 1_800_000_220)
    let runtimeMaterial = makeTestRuntimeMaterial(id: "coalesced-runtime", authMode: .chatgpt)
    let record = makeTestVaultRecord(
        from: makeTestProviderProfile(
            id: stableAccountRecordID(for: runtimeMaterial),
            displayName: "coalesced@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            runtimeMaterial: runtimeMaterial
        ),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    var fetchCount = 0
    let coordinator = VaultQuotaRefreshCoordinator { _ in
        fetchCount += 1
        try await Task.sleep(nanoseconds: 40_000_000)
        return makeTestSnapshot(
            email: "coalesced@example.com",
            primaryRemaining: 64,
            secondaryRemaining: 52,
            fetchedAt: now
        )
    }
    let request = VaultQuotaRefreshCoordinator.Request(
        currentProfile: nil,
        vaultAccounts: [record],
        cachedRecords: []
    )

    let records = await withCheckedContinuation { continuation in
        var resumed = false
        coordinator.requestRefresh(
            request,
            onUpdate: { _ in }
        ) { _ in
            Issue.record("The superseded completion handler should not fire.")
        }
        coordinator.requestRefresh(
            request,
            onUpdate: { _ in }
        ) { latest in
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: latest)
        }
    }

    #expect(fetchCount == 1)
    #expect(records.count == 1)
    #expect(records.first?.accountID == record.id)
}

@MainActor
@Test
func vaultQuotaRefreshCoordinatorCurrentOnlyScopePreservesCachedNonCurrentRecordsWithoutFetchingThem() async {
    let now = Date(timeIntervalSince1970: 1_800_000_240)
    let currentRuntime = makeTestRuntimeMaterial(id: "current-only-runtime", authMode: .chatgpt)
    let savedRuntime = makeTestRuntimeMaterial(id: "saved-runtime", authMode: .chatgpt)
    let currentRecord = makeTestVaultRecord(
        from: makeTestProviderProfile(
            id: stableAccountRecordID(for: currentRuntime),
            displayName: "current@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            runtimeMaterial: currentRuntime
        ),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let savedRecord = makeTestVaultRecord(
        from: makeTestProviderProfile(
            id: stableAccountRecordID(for: savedRuntime),
            displayName: "saved@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            runtimeMaterial: savedRuntime
        ),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let currentProfile = buildProviderProfile(
        id: currentRecord.id,
        fallbackDisplayName: "current@example.com",
        source: .current,
        runtimeMaterial: currentRuntime,
        snapshot: makeTestSnapshot(
            email: "current@example.com",
            primaryRemaining: 90,
            secondaryRemaining: 80,
            fetchedAt: now
        ),
        healthStatus: .healthy,
        errorMessage: nil,
        isCurrent: true,
        quotaFetchedAt: now
    )

    var fetchCount = 0
    let coordinator = VaultQuotaRefreshCoordinator { _ in
        fetchCount += 1
        return makeTestSnapshot(
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
                vaultAccounts: [currentRecord, savedRecord],
                cachedRecords: [
                    VaultQuotaSnapshotRecord(
                        accountID: savedRecord.id,
                        snapshot: makeTestSnapshot(
                            email: "saved@example.com",
                            primaryRemaining: 35,
                            secondaryRemaining: 25,
                            fetchedAt: now.addingTimeInterval(-600)
                        ),
                        healthStatus: .healthy,
                        errorSummary: nil,
                        fetchedAt: now.addingTimeInterval(-600),
                        authMode: .chatgpt,
                        isCurrent: false
                    )
                ],
                refreshScope: .currentOnly
            )
        ) { latest in
            guard !didResume, latest.count == 2 else {
                return
            }
            didResume = true
            continuation.resume(returning: latest)
        }
    }

    #expect(fetchCount == 0)
    #expect(records.first(where: { $0.accountID == currentRecord.id })?.snapshot?.account.email == "current@example.com")
    #expect(records.first(where: { $0.accountID == savedRecord.id })?.snapshot?.account.email == "saved@example.com")
}

@MainActor
@Test
func vaultQuotaRefreshCoordinatorBoundsConcurrentAllAccountsFetches() async {
    let now = Date(timeIntervalSince1970: 1_800_000_260)
    let tracker = ConcurrentRefreshTracker()
    let records = (1...4).map { index in
        makeTestVaultRecord(
            from: makeTestProviderProfile(
                id: "acct-\(index)",
                displayName: "account-\(index)@example.com",
                authMode: .chatgpt,
                snapshot: nil,
                runtimeMaterial: makeTestRuntimeMaterial(
                    id: "runtime-\(index)",
                    authMode: .chatgpt,
                    accountID: "acct-\(index)"
                )
            ),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
    let coordinator = VaultQuotaRefreshCoordinator(maxConcurrentChatGPTRefreshes: 2) { runtimeMaterial in
        await tracker.begin()
        try? await Task.sleep(nanoseconds: 50_000_000)
        await tracker.end()
        return makeTestSnapshot(
            email: "\(stableAccountRecordID(for: runtimeMaterial))@example.com",
            primaryRemaining: 60,
            secondaryRemaining: 50,
            fetchedAt: now
        )
    }

    let refreshed = await withCheckedContinuation { continuation in
        var didResume = false
        coordinator.requestRefresh(
            .init(
                currentProfile: nil,
                vaultAccounts: records,
                cachedRecords: [],
                refreshScope: .allAccounts
            )
        ) { latest in
            guard !didResume, latest.count == records.count, latest.allSatisfy({ $0.snapshot != nil }) else {
                return
            }
            didResume = true
            continuation.resume(returning: latest)
        }
    }

    #expect(refreshed.count == 4)
    #expect(await tracker.maxActiveCount <= 2)
}

@Test
func exhaustedAccountMenuTextShowsResetScheduleInsteadOfPercentages() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let exhausted = makeTestProviderProfile(
            id: "exhausted",
            displayName: "exhausted@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(email: "exhausted@example.com", primaryRemaining: 0, secondaryRemaining: 20, fetchedAt: now),
            lastUsedAt: now,
            healthStatus: .healthy,
            errorMessage: nil
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
        snapshot: makeTestSnapshot(
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
        let free = makeTestProviderProfile(
            id: "free",
            displayName: "ai.krisxu@gmail.com",
            authMode: .chatgpt,
            snapshot: makeTestFreeWeeklySnapshot(
                email: "ai.krisxu@gmail.com",
                weeklyRemaining: 0,
                fetchedAt: now
            ),
            isCurrent: true,
            lastUsedAt: now,
            healthStatus: .healthy,
            errorMessage: nil
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
        let free = makeTestProviderProfile(
            id: "free",
            displayName: "ai.krisxu@gmail.com",
            authMode: .chatgpt,
            snapshot: makeTestFreeWeeklySnapshot(
                email: "ai.krisxu@gmail.com",
                weeklyRemaining: 63,
                fetchedAt: now
            ),
            isCurrent: true,
            lastUsedAt: now,
            healthStatus: .healthy,
            errorMessage: nil
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
