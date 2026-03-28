import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func runtimeIdentityKeyNormalizesEquivalentAuthJSON() {
    let first = Data(#"{"refresh_token":"r","access_token":"a"}"#.utf8)
    let second = Data(#"{"access_token":"a","refresh_token":"r"}"#.utf8)

    #expect(runtimeIdentityKey(authData: first) == runtimeIdentityKey(authData: second))
}

@Test
func shouldAutoRefreshWhenMenuOpensRespectsManualPreset() {
    #expect(shouldAutoRefreshWhenMenuOpens(.manual) == false)
    #expect(shouldAutoRefreshWhenMenuOpens(.fiveMinutes) == true)
}

@Test
func isSnapshotDataStaleUsesManualFallbackThreshold() {
    let now = Date(timeIntervalSince1970: 3_000)

    #expect(
        isSnapshotDataStale(
            lastRefreshAt: now.addingTimeInterval(-(29 * 60)),
            refreshIntervalPreset: .manual,
            now: now
        ) == false
    )
    #expect(
        isSnapshotDataStale(
            lastRefreshAt: now.addingTimeInterval(-(31 * 60)),
            refreshIntervalPreset: .manual,
            now: now
        ) == true
    )
}

@Test
func shouldHideDuplicateCCSwitchSnapshotMatchesCurrentEmailCaseInsensitively() {
    let current = CodexSnapshot(
        account: CodexAccount(type: "chatgpt", email: "User@Example.com", planType: "pro"),
        rateLimits: RateLimitSnapshot(
            limitId: nil,
            limitName: nil,
            primary: RateLimitWindow(usedPercent: 10, windowDurationMins: 300, resetsAt: nil),
            secondary: RateLimitWindow(usedPercent: 20, windowDurationMins: 10080, resetsAt: nil),
            planType: "pro"
        ),
        fetchedAt: Date(timeIntervalSince1970: 1_000)
    )
    let duplicate = CodexSnapshot(
        account: CodexAccount(type: "chatgpt", email: "user@example.com", planType: "plus"),
        rateLimits: RateLimitSnapshot(
            limitId: nil,
            limitName: nil,
            primary: RateLimitWindow(usedPercent: 30, windowDurationMins: 300, resetsAt: nil),
            secondary: RateLimitWindow(usedPercent: 40, windowDurationMins: 10080, resetsAt: nil),
            planType: "plus"
        ),
        fetchedAt: Date(timeIntervalSince1970: 2_000)
    )

    #expect(shouldHideDuplicateCCSwitchSnapshot(duplicate, currentSnapshot: current) == true)
}

@Test
func resolveProfileIndicatorKindKeepsHealthyUnknownPlanOutOfErrorState() {
    let snapshot = CodexSnapshot(
        account: CodexAccount(type: "chatgpt", email: "user@example.com", planType: nil),
        rateLimits: RateLimitSnapshot(
            limitId: nil,
            limitName: nil,
            primary: RateLimitWindow(usedPercent: 10, windowDurationMins: 300, resetsAt: nil),
            secondary: RateLimitWindow(usedPercent: 10, windowDurationMins: 10080, resetsAt: nil),
            planType: nil
        ),
        fetchedAt: Date(timeIntervalSince1970: 1_000)
    )

    #expect(resolveProfileIndicatorKind(snapshot: snapshot, health: .healthy) == .neutral)
}

@Test
func codexProcessFailureErrorUsesMissingExecutableWhenShellCodexIsAbsent() {
    #expect(
        codexProcessFailureError(
            terminationStatus: 127,
            stderrText: "env: codex: No such file or directory"
        ) == .missingExecutable
    )
}

@Test
func codexProcessFailureErrorPreservesStderrDetails() {
    #expect(
        codexProcessFailureError(
            terminationStatus: 70,
            stderrText: "permission denied"
        ) == .rpc("app-server 启动失败（exit 70）：permission denied")
    )
}
