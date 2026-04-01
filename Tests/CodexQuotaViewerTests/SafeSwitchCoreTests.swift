import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func mergeRuntimeConfigPreservesUserSettingsAndReplacesProviderBlocks() throws {
        let current = """
        personality = "pragmatic"
        model_reasoning_effort = "xhigh"
        model_provider = "legacy"

        [model_providers.legacy]
        name = "Legacy"
        base_url = "https://legacy.example.com/v1"

        [mcp_servers.demo]
        command = "demo"
        """

        let target = """
        model_provider = "openai"
        model = "gpt-5.4"

        [model_providers.openai]
        name = "OpenAI"
        base_url = "https://api.openai.com/v1"
        """

        let merged = try mergeRuntimeConfig(
            currentConfigData: Data(current.utf8),
            targetConfigData: Data(target.utf8)
        )

        let text = try merged.utf8String()
        #expect(text.contains("personality = \"pragmatic\""))
        #expect(text.contains("model_reasoning_effort = \"xhigh\""))
        #expect(text.contains("model_provider = \"openai\""))
        #expect(text.contains("model = \"gpt-5.4\""))
        #expect(text.contains("[model_providers.openai]"))
        #expect(text.contains("[mcp_servers.demo]"))
        #expect(text.contains("[model_providers.legacy]"))
        #expect(text.contains("model_provider = \"legacy\"") == false)
    }

@Test
func buildProviderProfileCanonicalizesOpenAICompatibleAPIProfileToOpenAI() throws {
        let runtime = ProfileRuntimeMaterial(
            authData: Data(#"{"OPENAI_API_KEY":"sk-test"}"#.utf8),
            configData: Data(
                """
                model_provider = "custom"
                model = "gpt-5.4"

                [model_providers.custom]
                name = "custom"
                wire_api = "responses"
                requires_openai_auth = true
                base_url = "https://shell.wyzai.top/v1"
                """.utf8
            )
        )

        let profile = buildProviderProfile(
            id: "api-target",
            fallbackDisplayName: "API",
            source: .vault,
            runtimeMaterial: runtime,
            snapshot: nil,
            healthStatus: .healthy,
            errorMessage: nil,
            isCurrent: false
        )

        #expect(profile.authMode == .apiKey)
        #expect(profile.providerID == "openai")
        #expect(profile.threadProviderID == "custom")
        #expect(profile.baseURLHost == "shell.wyzai.top")
    }

@Test
func statusEvaluatorBuildsLocalizedRepairRecommendation() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.zh, preferredLanguages: ["zh-Hans-CN"])
        let state = StatusEvaluator().currentState(
            currentProfile: nil,
            availableTargets: [],
            codexIsRunning: true,
            localThreadSyncStatus: .repairNeeded(
                expectedProvider: "openai",
                rolloutProviders: [ProviderCount(providerID: "legacy", count: 2)],
                threadProviders: [ProviderCount(providerID: "legacy", count: 2)]
            ),
            latestRestorePoint: nil
        )

        #expect(state.recommendation?.action == .repairNow)
        #expect(state.recommendation?.message == "本地线程元数据与当前 provider 不一致。建议先执行修复，再继续操作。")
    }
}

@Test
func localThreadSyncStatusLabelsAndDetailsFollowActiveLanguage() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.zh, preferredLanguages: ["zh-Hans-CN"])
        let healthy = LocalThreadSyncStatus.healthy(expectedProvider: "openai")
        let repair = LocalThreadSyncStatus.repairNeeded(
            expectedProvider: "openai",
            rolloutProviders: [ProviderCount(providerID: "legacy", count: 2)],
            threadProviders: [ProviderCount(providerID: "legacy", count: 2)]
        )

        #expect(healthy.label == "正常")
        #expect(healthy.detail == "Provider 已对齐：openai")
        #expect(repair.label == "需要修复")
        #expect(repair.detail == "预期 openai · Rollout legacy:2 · Threads legacy:2")
    }
}

@Test
func backupManagerCapturesAndRestoresLatestRestorePoint() throws {
        let harness = try makeHarness()
        let backupRoot = harness.appSupportURL.appendingPathComponent("SwitchBackups", isDirectory: true)
        let fileURL = harness.codexHomeURL.appendingPathComponent("auth.json", isDirectory: false)

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("before".utf8).write(to: fileURL, options: .atomic)

        let manager = BackupManager(backupsRootURL: backupRoot)
        let manifest = try manager.createRestorePoint(
            reason: "test backup",
            summary: "capture auth",
            files: [fileURL],
            codexWasRunning: true
        )

        try Data("after".utf8).write(to: fileURL, options: .atomic)
        let restored = try manager.restoreLatestRestorePoint()

        #expect(manifest.id == restored.id)
        #expect(restored.files.count == 1)
        #expect(try Data(contentsOf: fileURL).utf8String() == "before")
    }

@Test
func rolloutProviderSynchronizerRewritesSessionMetaAcrossRoots() throws {
        let harness = try makeHarness()
        let activeURL = try writeRollout(
            under: harness.codexHomeURL.appendingPathComponent("sessions", isDirectory: true),
            id: "active-session",
            provider: "legacy"
        )
        let archivedURL = try writeRollout(
            under: harness.codexHomeURL.appendingPathComponent("archived_sessions", isDirectory: true),
            id: "archived-session",
            provider: "legacy"
        )

        let synchronizer = RolloutProviderSynchronizer()
        let result = try synchronizer.syncProviders(
            in: [
                harness.codexHomeURL.appendingPathComponent("sessions", isDirectory: true),
                harness.codexHomeURL.appendingPathComponent("archived_sessions", isDirectory: true),
            ],
            targetProvider: "openai"
        )

        #expect(result.updatedFiles.count == 2)
        #expect(try readSessionMetaProvider(from: activeURL) == "openai")
        #expect(try readSessionMetaProvider(from: archivedURL) == "openai")
    }

@MainActor
@Test
func switchOrchestratorAppliesRuntimeSynchronizesRolloutsAndRequestsRepair() async throws {
        let harness = try makeHarness()
        try seedCurrentRuntime(in: harness, provider: "legacy")
        let rolloutURL = try writeRollout(
            under: harness.codexHomeURL.appendingPathComponent("sessions", isDirectory: true),
            id: "switch-session",
            provider: "legacy"
        )

        let repairer = RepairerSpy()
        let desktop = DesktopControllerSpy(isRunning: true)
        let orchestrator = makeOrchestrator(
            harness: harness,
            repairer: repairer,
            desktop: desktop
        )

        let target = ProviderProfile(
            id: "target-openai",
            displayName: "Target OpenAI",
            source: .vault,
            runtimeMaterial: ProfileRuntimeMaterial(
                authData: Data("{\"auth_mode\":\"chatgpt\"}".utf8),
                configData: Data("""
                model_provider = "openai"
                model = "gpt-5.4"
                """.utf8)
            ),
            authMode: .chatgpt,
            providerID: "openai",
            providerDisplayName: "OpenAI",
            baseURLHost: nil,
            model: "gpt-5.4",
            snapshot: nil,
            healthStatus: .healthy,
            errorMessage: nil,
            isCurrent: false
        )

        let result = try await orchestrator.perform(targetProfile: target)

        #expect(result.updatedRolloutCount == 1)
        #expect(repairer.invocationCount == 1)
        #expect(desktop.closeInvocationCount == 1)
        #expect(desktop.reopenInvocationCount == 1)
        #expect(try readSessionMetaProvider(from: rolloutURL) == "openai")
        #expect(
            try Data(contentsOf: harness.codexHomeURL.appendingPathComponent("auth.json")).utf8String()
                == "{\"auth_mode\":\"chatgpt\"}"
        )

        let mergedConfig = try Data(
            contentsOf: harness.codexHomeURL.appendingPathComponent("config.toml")
        ).utf8String()
        #expect(mergedConfig.contains("personality = \"pragmatic\""))
        #expect(mergedConfig.contains("model_provider = \"openai\""))
        #expect(result.restorePoint.files.contains { $0.originalPath.hasSuffix("/auth.json") })
    }

@MainActor
@Test
func switchOrchestratorPreservesWorkingOpenAICompatibleAPIConfigBeforeSwitch() async throws {
        let harness = try makeHarness()
        try seedCurrentRuntime(in: harness, provider: "openai")
        let rolloutURL = try writeRollout(
            under: harness.codexHomeURL.appendingPathComponent("sessions", isDirectory: true),
            id: "api-switch-session",
            provider: "openai"
        )

        let repairer = RepairerSpy()
        let desktop = DesktopControllerSpy(isRunning: true)
        let orchestrator = makeOrchestrator(
            harness: harness,
            repairer: repairer,
            desktop: desktop
        )

        let target = ProviderProfile(
            id: "target-api",
            displayName: "API Target",
            source: .vault,
            runtimeMaterial: ProfileRuntimeMaterial(
                authData: Data(#"{"OPENAI_API_KEY":"sk-test"}"#.utf8),
                configData: Data(
                    """
                    model_provider = "custom"
                    model = "gpt-5.4"

                    [model_providers.custom]
                    name = "custom"
                    wire_api = "responses"
                    requires_openai_auth = true
                    base_url = "https://shell.wyzai.top/v1"
                    """.utf8
                )
            ),
            authMode: .apiKey,
            providerID: "openai",
            providerDisplayName: "openai",
            baseURLHost: "shell.wyzai.top",
            model: "gpt-5.4",
            snapshot: nil,
            healthStatus: .healthy,
            errorMessage: nil,
            isCurrent: false
        )

        let result = try await orchestrator.perform(targetProfile: target)
        let mergedConfig = try Data(
            contentsOf: harness.codexHomeURL.appendingPathComponent("config.toml")
        ).utf8String()

        #expect(result.updatedRolloutCount == 1)
        #expect(repairer.invocationCount == 1)
        #expect(try readSessionMetaProvider(from: rolloutURL) == "custom")
        #expect(mergedConfig.contains("model_provider = \"custom\""))
        #expect(mergedConfig.contains("[model_providers.custom]"))
        #expect(mergedConfig.contains("wire_api = \"responses\""))
        #expect(mergedConfig.contains("requires_openai_auth = true"))
        #expect(mergedConfig.contains("base_url = \"https://shell.wyzai.top/v1\""))
        #expect(mergedConfig.contains("model = \"gpt-5.4\""))
    }

@MainActor
@Test
func rollbackManagerRestoresLatestRestorePointAndReopensCodexWhenNeeded() async throws {
        let harness = try makeHarness()
        let authURL = harness.codexHomeURL.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(
            at: authURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("before".utf8).write(to: authURL, options: .atomic)

        let backupManager = BackupManager(
            backupsRootURL: harness.appSupportURL.appendingPathComponent("SwitchBackups", isDirectory: true)
        )
        _ = try backupManager.createRestorePoint(
            reason: "rollback",
            summary: "restore auth",
            files: [authURL],
            codexWasRunning: true
        )

        try Data("after".utf8).write(to: authURL, options: .atomic)
        let desktop = DesktopControllerSpy(isRunning: true)
        let rollbackManager = RollbackManager(
            backupManager: backupManager,
            desktopController: desktop
        )

        let manifest = try await rollbackManager.rollbackLatest()

        #expect(try Data(contentsOf: authURL).utf8String() == "before")
        #expect(manifest.files.count == 1)
        #expect(desktop.closeInvocationCount == 1)
        #expect(desktop.reopenInvocationCount == 1)
}

@MainActor
private func makeOrchestrator(
    harness: TestHarness,
    repairer: RepairerSpy,
    desktop: DesktopControllerSpy
) -> SwitchOrchestrator {
    let store = ProfileStore(
        baseURL: harness.appSupportURL,
        currentAuthURL: harness.codexHomeURL.appendingPathComponent("auth.json"),
        homeDirectoryOverride: harness.homeURL
    )

    return SwitchOrchestrator(
        store: store,
        backupManager: BackupManager(
            backupsRootURL: harness.appSupportURL.appendingPathComponent("SwitchBackups", isDirectory: true)
        ),
        rolloutSynchronizer: RolloutProviderSynchronizer(),
        repairClient: repairer,
        desktopController: desktop
    )
}

private func seedCurrentRuntime(in harness: TestHarness, provider: String) throws {
    try FileManager.default.createDirectory(
        at: harness.codexHomeURL,
        withIntermediateDirectories: true
    )
    try Data("{\"auth_mode\":\"chatgpt\",\"last_refresh\":\"2026-03-31T00:00:00Z\"}".utf8)
        .write(to: harness.codexHomeURL.appendingPathComponent("auth.json"), options: .atomic)
    try Data(
        """
        personality = "pragmatic"
        model_reasoning_effort = "xhigh"
        model_provider = "\(provider)"

        [model_providers.\(provider)]
        name = "Legacy"
        base_url = "https://legacy.example.com/v1"
        """.utf8
    )
    .write(to: harness.codexHomeURL.appendingPathComponent("config.toml"), options: .atomic)
}

private func writeRollout(under root: URL, id: String, provider: String) throws -> URL {
    let folder = root
        .appendingPathComponent("2026", isDirectory: true)
        .appendingPathComponent("03", isDirectory: true)
        .appendingPathComponent("31", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fileURL = folder.appendingPathComponent("rollout-\(id).jsonl", isDirectory: false)
    let text = """
    {"timestamp":"2026-03-31T00:00:00Z","type":"session_meta","payload":{"id":"\(id)","timestamp":"2026-03-31T00:00:00Z","cwd":"/tmp","source":"vscode","originator":"Codex Desktop","cli_version":"0.118.0-alpha.2","model_provider":"\(provider)"}}
    {"timestamp":"2026-03-31T00:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"hello"}}
    """
    try Data(text.utf8).write(to: fileURL, options: .atomic)
    return fileURL
}

private func readSessionMetaProvider(from fileURL: URL) throws -> String {
    guard let line = try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n").first else {
        throw NSError(domain: "SafeSwitchCoreTests", code: 2)
    }
    let data = Data(line.utf8)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let payload = object["payload"] as? [String: Any],
          let provider = payload["model_provider"] as? String else {
        throw NSError(domain: "SafeSwitchCoreTests", code: 3)
    }
    return provider
}

private final class RepairerSpy: OfficialThreadRepairing {
    private(set) var invocationCount = 0

    func rescanAndRepair() async throws -> OfficialRepairSummary {
        invocationCount += 1
        return OfficialRepairSummary(
            createdThreads: 0,
            updatedThreads: 1,
            updatedSessionIndexEntries: 1,
            removedBrokenThreads: 0,
            hiddenSnapshotOnlySessions: 0
        )
    }
}

@MainActor
private final class DesktopControllerSpy: CodexDesktopControlling {
    private(set) var closeInvocationCount = 0
    private(set) var reopenInvocationCount = 0
    var isRunning: Bool

    init(isRunning: Bool) {
        self.isRunning = isRunning
    }

    func closeIfRunning() async throws -> Bool {
        let wasRunning = isRunning
        if wasRunning {
            closeInvocationCount += 1
            isRunning = false
        }
        return wasRunning
    }

    func reopenIfNeeded(previouslyRunning: Bool) async throws {
        guard previouslyRunning else { return }
        reopenInvocationCount += 1
        isRunning = true
    }
}
