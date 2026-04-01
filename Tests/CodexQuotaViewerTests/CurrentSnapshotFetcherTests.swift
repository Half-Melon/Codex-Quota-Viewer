import Foundation
import Testing

@testable import CodexQuotaViewer

actor FetchCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

@Test
func currentSnapshotFetcherPrefersIsolatedRuntimeWhenAvailable() async throws {
    let expected = CodexSnapshot(
        account: CodexAccount(type: "chatgpt", email: "user@example.com", planType: "team"),
        rateLimits: RateLimitSnapshot(
            limitId: "limit",
            limitName: "limit",
            primary: RateLimitWindow(usedPercent: 20, windowDurationMins: 300, resetsAt: 1_800_000_000),
            secondary: nil,
            planType: "team"
        ),
        fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let runtime = ProfileRuntimeMaterial(
        authData: Data(#"{"auth_mode":"chatgpt"}"#.utf8),
        configData: Data("model_provider = \"openai\"\n".utf8)
    )
    let codexHomeURL = URL(fileURLWithPath: "/tmp/codex-home", isDirectory: true)

    let liveCalls = FetchCallCounter()
    let isolatedCalls = FetchCallCounter()

    let fetcher = CurrentSnapshotFetcher(
        fetchFromRuntimeMaterial: { material in
            await isolatedCalls.increment()
            #expect(material == runtime)
            return expected
        },
        fetchFromCodexHome: { _ in
            await liveCalls.increment()
            throw NSError(domain: "CurrentSnapshotFetcherTests", code: 1)
        }
    )

    let snapshot = try await fetcher.fetch(
        currentRuntimeMaterial: runtime,
        codexHomeURL: codexHomeURL
    )

    #expect(snapshot == expected)
    #expect(await isolatedCalls.value == 1)
    #expect(await liveCalls.value == 0)
}

@Test
func currentSnapshotFetcherFallsBackToLiveCodexHomeWhenRuntimeMissing() async throws {
    let expected = CodexSnapshot(
        account: CodexAccount(type: "chatgpt", email: "user@example.com", planType: "team"),
        rateLimits: RateLimitSnapshot(
            limitId: "limit",
            limitName: "limit",
            primary: RateLimitWindow(usedPercent: 20, windowDurationMins: 300, resetsAt: 1_800_000_000),
            secondary: nil,
            planType: "team"
        ),
        fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let codexHomeURL = URL(fileURLWithPath: "/tmp/codex-home", isDirectory: true)

    let liveCalls = FetchCallCounter()
    let isolatedCalls = FetchCallCounter()

    let fetcher = CurrentSnapshotFetcher(
        fetchFromRuntimeMaterial: { _ in
            await isolatedCalls.increment()
            throw NSError(domain: "CurrentSnapshotFetcherTests", code: 2)
        },
        fetchFromCodexHome: { url in
            await liveCalls.increment()
            #expect(url == codexHomeURL)
            return expected
        }
    )

    let snapshot = try await fetcher.fetch(
        currentRuntimeMaterial: nil,
        codexHomeURL: codexHomeURL
    )

    #expect(snapshot == expected)
    #expect(await isolatedCalls.value == 0)
    #expect(await liveCalls.value == 1)
}
