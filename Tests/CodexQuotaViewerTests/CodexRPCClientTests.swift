import Foundation
import Testing

@testable import CodexQuotaViewer

actor FakeChannelFactory {
    private(set) var createdKeys: [String] = []
    private var snapshotsByKey: [String: CodexSnapshot]

    init(snapshotsByKey: [String: CodexSnapshot]) {
        self.snapshotsByKey = snapshotsByKey
    }

    func makeChannel(runtimeMaterial: ProfileRuntimeMaterial) -> any CodexRPCChanneling {
        let key = runtimeIdentityKey(for: runtimeMaterial)
        createdKeys.append(key)
        let snapshot = snapshotsByKey[key] ?? CodexSnapshot(
            account: CodexAccount(type: "chatgpt", email: "\(key)@example.com", planType: "team"),
            rateLimits: RateLimitSnapshot(
                limitId: "limit",
                limitName: "limit",
                primary: RateLimitWindow(usedPercent: 20, windowDurationMins: 300, resetsAt: 1_800_000_000),
                secondary: nil,
                planType: "team"
            ),
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        return FakeChannel(snapshot: snapshot)
    }
}

actor FakeChannel: CodexRPCChanneling {
    private let snapshot: CodexSnapshot
    private(set) var invalidationCount = 0

    init(snapshot: CodexSnapshot) {
        self.snapshot = snapshot
    }

    func fetchSnapshot(timeout: TimeInterval) async throws -> CodexSnapshot {
        _ = timeout
        return snapshot
    }

    func invalidate() async {
        invalidationCount += 1
    }
}

@Test
func codexRPCChannelInvalidationStateDefersCleanupUntilActiveFetchEnds() {
    var state = CodexRPCChannelInvalidationState()

    let didBeginFetch = state.beginFetch()
    let invalidationDisposition = state.beginInvalidation()
    let didBeginSecondFetch = state.beginFetch()
    let shouldCleanupAfterFetchEnds = state.endFetch()

    #expect(didBeginFetch)
    #expect(invalidationDisposition == .deferCleanup)
    #expect(didBeginSecondFetch == false)
    #expect(shouldCleanupAfterFetchEnds)
}

@Test
func codexRPCChannelInvalidationStateCleansUpImmediatelyWithoutActiveFetch() {
    var state = CodexRPCChannelInvalidationState()

    let firstInvalidationDisposition = state.beginInvalidation()
    let secondInvalidationDisposition = state.beginInvalidation()
    let didBeginFetch = state.beginFetch()

    #expect(firstInvalidationDisposition == .cleanupNow)
    #expect(secondInvalidationDisposition == .none)
    #expect(didBeginFetch == false)
}

@Test
func codexRPCChannelPoolReusesChannelWithinTTLForSameRuntime() async throws {
    let runtime = makeTestRuntimeMaterial(id: "pooled-runtime", authMode: .chatgpt)
    let key = runtimeIdentityKey(for: canonicalRuntimeMaterialForStorage(runtime))
    let snapshot = makeTestSnapshot(
        email: "pooled@example.com",
        primaryRemaining: 90,
        secondaryRemaining: 80,
        fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let factory = FakeChannelFactory(snapshotsByKey: [key: snapshot])
    let pool = CodexRPCChannelPool(
        ttl: 180,
        channelFactory: { runtimeMaterial in
            await factory.makeChannel(runtimeMaterial: runtimeMaterial)
        }
    )

    let first = try await pool.fetchSnapshot(runtimeMaterial: runtime, timeout: 6)
    let second = try await pool.fetchSnapshot(runtimeMaterial: runtime, timeout: 12)

    #expect(first == snapshot)
    #expect(second == snapshot)
    #expect(await factory.createdKeys == [key])
}

@Test
func codexRPCChannelPoolUsesDifferentKeysWhenRuntimeConfigChanges() async throws {
    let runtimeA = makeTestRuntimeMaterial(
        id: "same-auth",
        authMode: .chatgpt,
        configData: Data("model_provider = \"openai\"\nmodel = \"gpt-5.4\"\n".utf8)
    )
    let runtimeB = makeTestRuntimeMaterial(
        id: "same-auth",
        authMode: .chatgpt,
        configData: Data("model_provider = \"openai\"\nmodel = \"gpt-4.1\"\n".utf8)
    )
    let keyA = runtimeIdentityKey(for: canonicalRuntimeMaterialForStorage(runtimeA))
    let keyB = runtimeIdentityKey(for: canonicalRuntimeMaterialForStorage(runtimeB))
    let factory = FakeChannelFactory(
        snapshotsByKey: [
            keyA: makeTestSnapshot(email: "a@example.com", primaryRemaining: 70, secondaryRemaining: 60, fetchedAt: Date(timeIntervalSince1970: 1_800_000_100)),
            keyB: makeTestSnapshot(email: "b@example.com", primaryRemaining: 71, secondaryRemaining: 61, fetchedAt: Date(timeIntervalSince1970: 1_800_000_200)),
        ]
    )
    let pool = CodexRPCChannelPool(
        ttl: 180,
        channelFactory: { runtimeMaterial in
            await factory.makeChannel(runtimeMaterial: runtimeMaterial)
        }
    )

    _ = try await pool.fetchSnapshot(runtimeMaterial: runtimeA, timeout: 6)
    _ = try await pool.fetchSnapshot(runtimeMaterial: runtimeB, timeout: 6)

    #expect(keyA != keyB)
    #expect(await factory.createdKeys == [keyA, keyB])
}

@Test
func codexRPCChannelPoolRecreatesChannelAfterTTLExpires() async throws {
    let runtime = makeTestRuntimeMaterial(id: "ttl-runtime", authMode: .chatgpt)
    let key = runtimeIdentityKey(for: canonicalRuntimeMaterialForStorage(runtime))
    let factory = FakeChannelFactory(
        snapshotsByKey: [
            key: makeTestSnapshot(email: "ttl@example.com", primaryRemaining: 80, secondaryRemaining: 70, fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))
        ]
    )
    let pool = CodexRPCChannelPool(
        ttl: 0.01,
        channelFactory: { runtimeMaterial in
            await factory.makeChannel(runtimeMaterial: runtimeMaterial)
        }
    )

    _ = try await pool.fetchSnapshot(runtimeMaterial: runtime, timeout: 6)
    try await Task.sleep(nanoseconds: 25_000_000)
    _ = try await pool.fetchSnapshot(runtimeMaterial: runtime, timeout: 6)

    #expect(await factory.createdKeys == [key, key])
}
