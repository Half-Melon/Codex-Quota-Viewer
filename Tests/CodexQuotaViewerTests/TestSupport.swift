import Foundation

@testable import CodexQuotaViewer

private let localizationTestLock = NSLock()

struct TestHarness {
    let homeURL: URL
    let codexHomeURL: URL
    let appSupportURL: URL
}

struct ChatGPTNormalizationFixture {
    let encoder: JSONEncoder
    let legacyMetadata: VaultAccountMetadata
    let currentMetadata: VaultAccountMetadata
    let legacyRuntime: ProfileRuntimeMaterial
    let currentRuntime: ProfileRuntimeMaterial
}

func makeHarness() throws -> TestHarness {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexQuotaViewerTests-\(UUID().uuidString)", isDirectory: true)
    let homeURL = root.appendingPathComponent("home", isDirectory: true)
    let codexHomeURL = homeURL.appendingPathComponent(".codex", isDirectory: true)
    let appSupportURL = homeURL
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent(AppIdentity.supportDirectoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
    return TestHarness(homeURL: homeURL, codexHomeURL: codexHomeURL, appSupportURL: appSupportURL)
}

func makeVaultStore(_ harness: TestHarness) -> VaultAccountStore {
    VaultAccountStore(
        accountsRootURL: harness.appSupportURL.appendingPathComponent("Accounts", isDirectory: true)
    )
}

func makeBackupManager(_ harness: TestHarness) -> BackupManager {
    BackupManager(
        backupsRootURL: harness.appSupportURL.appendingPathComponent("SwitchBackups", isDirectory: true)
    )
}

func makeProtectedFilesProvider(
    for vault: VaultAccountStore
) -> ([String]) -> [URL] {
    { accountIDs in
        [vault.indexURL] + vault.protectedMutationFileURLs(forAccountIDs: accountIDs)
    }
}

func makeTestJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

func makeTestRuntimeMaterial(
    id: String,
    authMode: CodexAuthMode,
    accountID: String? = nil,
    apiBaseURL: String = "https://api.example.com/v1",
    model: String = "gpt-5.4",
    authData: Data? = nil,
    configData: Data? = nil
) -> ProfileRuntimeMaterial {
    if let authData {
        return ProfileRuntimeMaterial(authData: authData, configData: configData)
    }

    let resolvedAccountID = accountID ?? id

    if authMode == .apiKey {
        return ProfileRuntimeMaterial(
            authData: Data(#"{"OPENAI_API_KEY":"sk-\#(id)","auth_mode":"apikey"}"#.utf8),
            configData: configData ?? Data(
                """
                model_provider = "openai"
                base_url = "\(apiBaseURL)"
                model = "\(model)"
                """.utf8
            )
        )
    }

    return ProfileRuntimeMaterial(
        authData: Data(
            #"{"auth_mode":"chatgpt","tokens":{"access_token":"token-\#(id)","account_id":"\#(resolvedAccountID)"}}"#.utf8
        ),
        configData: configData ?? Data(#"model_provider = "openai""#.utf8)
    )
}

func makeTestProviderProfile(
    id: String,
    displayName: String,
    authMode: CodexAuthMode,
    snapshot: CodexSnapshot?,
    source: ProviderProfile.Source = .vault,
    isCurrent: Bool = false,
    lastUsedAt: Date? = nil,
    healthStatus: ProfileHealthStatus = .healthy,
    errorMessage: String? = nil,
    quotaFailureDisposition: QuotaFailureDisposition? = nil,
    runtimeMaterial: ProfileRuntimeMaterial? = nil,
    quotaFetchedAt: Date? = nil
) -> ProviderProfile {
    let runtimeMaterial = runtimeMaterial ?? makeTestRuntimeMaterial(id: id, authMode: authMode)

    return ProviderProfile(
        id: id,
        displayName: displayName,
        source: source,
        runtimeMaterial: runtimeMaterial,
        authMode: authMode,
        providerID: "openai",
        providerDisplayName: authMode == .apiKey ? "openai" : nil,
        baseURLHost: authMode == .apiKey ? "api.example.com" : nil,
        model: authMode == .apiKey ? "gpt-5.4" : nil,
        snapshot: snapshot,
        healthStatus: healthStatus,
        errorMessage: errorMessage,
        quotaFailureDisposition: quotaFailureDisposition,
        isCurrent: isCurrent,
        managedFileURLs: [],
        lastUsedAt: lastUsedAt,
        quotaFetchedAt: quotaFetchedAt
    )
}

func makeTestVaultRecord(
    from profile: ProviderProfile,
    source: VaultAccountSource = .currentRuntime,
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    baseDirectory: URL? = nil
) -> VaultAccountRecord {
    let directoryURL = baseDirectory ?? URL(fileURLWithPath: "/tmp/\(profile.id)", isDirectory: true)
    let metadata = VaultAccountMetadata(
        id: profile.id,
        displayName: profile.displayName,
        authMode: profile.authMode,
        providerID: profile.providerID,
        baseURL: profile.baseURLHost.map { "https://\($0)/v1" },
        model: profile.model,
        createdAt: createdAt,
        lastUsedAt: profile.lastUsedAt,
        source: source,
        runtimeKey: stableAccountIdentityKey(for: profile.runtimeMaterial)
    )

    return VaultAccountRecord(
        metadata: metadata,
        runtimeMaterial: profile.runtimeMaterial,
        directoryURL: directoryURL,
        metadataURL: directoryURL.appendingPathComponent("metadata.json"),
        authURL: directoryURL.appendingPathComponent("auth.json"),
        configURL: directoryURL.appendingPathComponent("config.toml")
    )
}

func writeTestVaultRecord(
    root: URL,
    metadata: VaultAccountMetadata,
    runtime: ProfileRuntimeMaterial,
    encoder: JSONEncoder = makeTestJSONEncoder()
) throws {
    let directory = root.appendingPathComponent(metadata.id, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try encoder.encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))
    try runtime.authData.write(to: directory.appendingPathComponent("auth.json"))
    try runtime.configData?.write(to: directory.appendingPathComponent("config.toml"))
}

func makeTestSnapshot(
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
            primary: RateLimitWindow(
                usedPercent: 100 - primaryRemaining,
                windowDurationMins: 300,
                resetsAt: 1_800_000_360
            ),
            secondary: RateLimitWindow(
                usedPercent: 100 - secondaryRemaining,
                windowDurationMins: 10_080,
                resetsAt: 1_800_086_400
            ),
            planType: "plus"
        ),
        fetchedAt: fetchedAt
    )
}

func makeTestFreeWeeklySnapshot(
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

func makeChatGPTNormalizationFixture() -> ChatGPTNormalizationFixture {
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    return ChatGPTNormalizationFixture(
        encoder: makeTestJSONEncoder(),
        legacyMetadata: VaultAccountMetadata(
            id: "acct-legacy-1",
            displayName: "Krisxu9@gmail.com",
            authMode: .chatgpt,
            providerID: "openai",
            baseURL: nil,
            model: nil,
            createdAt: createdAt,
            lastUsedAt: nil,
            source: .currentRuntime,
            runtimeKey: "legacy"
        ),
        currentMetadata: VaultAccountMetadata(
            id: "acct-current-1",
            displayName: "krisxu9@gmail.com",
            authMode: .chatgpt,
            providerID: "openai",
            baseURL: "https://shell.wyzai.top",
            model: "gpt-5.4",
            createdAt: createdAt.addingTimeInterval(60),
            lastUsedAt: createdAt.addingTimeInterval(120),
            source: .currentRuntime,
            runtimeKey: "current"
        ),
        legacyRuntime: ProfileRuntimeMaterial(
            authData: Data(
                """
                {"auth_mode":"chatgpt","last_refresh":"2026-03-30T02:33:21.958042Z","tokens":{"access_token":"token-1","refresh_token":"refresh-1","account_id":"acct-9"}}
                """.utf8
            ),
            configData: Data("model_provider = \"openai\"\n".utf8)
        ),
        currentRuntime: ProfileRuntimeMaterial(
            authData: Data(
                """
                {"auth_mode":"chatgpt","last_refresh":"2026-03-31T01:45:41.950247Z","tokens":{"access_token":"token-2","refresh_token":"refresh-2","account_id":"acct-9"}}
                """.utf8
            ),
            configData: Data(
                """
                model_provider = "custom"
                model = "gpt-5.4"

                [model_providers.custom]
                name = "custom"
                requires_openai_auth = true
                base_url = "https://shell.wyzai.top/v1"
                """.utf8
            )
        )
    )
}

extension Data {
    func utf8String() throws -> String {
        guard let string = String(data: self, encoding: .utf8) else {
            throw NSError(domain: "CodexQuotaViewerTests", code: 1)
        }
        return string
    }
}

@discardableResult
func withExclusiveAppLocalization<T>(_ body: () throws -> T) rethrows -> T {
    localizationTestLock.lock()
    defer {
        AppLocalization.setPreferredLanguage(.system, preferredLanguages: Locale.preferredLanguages)
        localizationTestLock.unlock()
    }
    return try body()
}
