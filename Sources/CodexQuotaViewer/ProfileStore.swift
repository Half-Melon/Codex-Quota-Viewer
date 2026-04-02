import Foundation

struct LoadIssue: Equatable {
    let message: String
}

struct SettingsLoadResult {
    let settings: AppSettings
    let issues: [LoadIssue]
}

final class ProfileStore {
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    let homeURL: URL
    let baseURL: URL
    let settingsURL: URL
    let accountsRootURL: URL
    let accountsIndexURL: URL
    let quotaCacheURL: URL
    let sessionManagerUIConfigURL: URL
    let codexHomeURL: URL
    let currentAuthURL: URL
    let currentConfigURL: URL
    let sessionsRootURL: URL
    let archivedSessionsRootURL: URL
    let stateDatabaseURL: URL
    let stateDatabaseWALURL: URL
    let stateDatabaseSHMURL: URL
    let sessionIndexURL: URL
    let sessionManagerHomeURL: URL
    let sessionManagerDatabaseURL: URL
    let sessionManagerDatabaseWALURL: URL
    let sessionManagerDatabaseSHMURL: URL

    init(
        baseURL: URL? = nil,
        currentAuthURL: URL? = nil,
        homeDirectoryOverride: URL? = nil
    ) {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        decoder = JSONDecoder()

        let home = homeDirectoryOverride ?? fileManager.homeDirectoryForCurrentUser
        homeURL = home
        let defaultBaseURL = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(AppIdentity.supportDirectoryName, isDirectory: true)
        self.baseURL = baseURL ?? defaultBaseURL
        settingsURL = self.baseURL.appendingPathComponent("settings.json", isDirectory: false)
        accountsRootURL = self.baseURL.appendingPathComponent("Accounts", isDirectory: true)
        accountsIndexURL = accountsRootURL.appendingPathComponent("accounts.json", isDirectory: false)
        quotaCacheURL = self.baseURL.appendingPathComponent("quota-cache.json", isDirectory: false)
        sessionManagerUIConfigURL = self.baseURL.appendingPathComponent("session-manager-ui.json", isDirectory: false)
        codexHomeURL = (currentAuthURL ?? home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false))
            .deletingLastPathComponent()
        self.currentAuthURL = currentAuthURL ?? codexHomeURL
            .appendingPathComponent("auth.json", isDirectory: false)
        currentConfigURL = codexHomeURL
            .appendingPathComponent("config.toml", isDirectory: false)
        sessionsRootURL = codexHomeURL.appendingPathComponent("sessions", isDirectory: true)
        archivedSessionsRootURL = codexHomeURL.appendingPathComponent("archived_sessions", isDirectory: true)
        stateDatabaseURL = codexHomeURL.appendingPathComponent("state_5.sqlite", isDirectory: false)
        stateDatabaseWALURL = codexHomeURL.appendingPathComponent("state_5.sqlite-wal", isDirectory: false)
        stateDatabaseSHMURL = codexHomeURL.appendingPathComponent("state_5.sqlite-shm", isDirectory: false)
        sessionIndexURL = codexHomeURL.appendingPathComponent("session_index.jsonl", isDirectory: false)
        sessionManagerHomeURL = home.appendingPathComponent(".codex-session-manager", isDirectory: true)
        sessionManagerDatabaseURL = sessionManagerHomeURL.appendingPathComponent("index.db", isDirectory: false)
        sessionManagerDatabaseWALURL = sessionManagerHomeURL.appendingPathComponent("index.db-wal", isDirectory: false)
        sessionManagerDatabaseSHMURL = sessionManagerHomeURL.appendingPathComponent("index.db-shm", isDirectory: false)
    }

    func loadSettingsResult() -> SettingsLoadResult {
        ensureBaseDirectoryExists()

        guard fileManager.fileExists(atPath: settingsURL.path) else {
            return SettingsLoadResult(settings: AppSettings(), issues: [])
        }

        do {
            let data = try Data(contentsOf: settingsURL)
            let settings = try decoder.decode(AppSettings.self, from: data)
            return SettingsLoadResult(settings: settings, issues: [])
        } catch {
            return SettingsLoadResult(
                settings: AppSettings(),
                issues: [
                    LoadIssue(
                        message: AppLocalization.localized(
                            en: "Settings file is corrupted: \(settingsURL.lastPathComponent)",
                            zh: "设置文件已损坏：\(settingsURL.lastPathComponent)"
                        )
                    )
                ]
            )
        }
    }

    func saveSettings(
        _ settings: AppSettings,
        writer: FileDataWriting = DirectFileDataWriter()
    ) throws {
        ensureBaseDirectoryExists()
        let data = try encoder.encode(settings)
        try writer.write(data, to: settingsURL)
    }

    func loadSessionManagerUIConfig() -> SessionManagerUIConfig? {
        ensureBaseDirectoryExists()

        guard fileManager.fileExists(atPath: sessionManagerUIConfigURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: sessionManagerUIConfigURL)
            return try decoder.decode(SessionManagerUIConfig.self, from: data)
        } catch {
            return nil
        }
    }

    func saveSessionManagerUIConfig(
        _ config: SessionManagerUIConfig,
        writer: FileDataWriting = DirectFileDataWriter()
    ) throws {
        ensureBaseDirectoryExists()
        let data = try encoder.encode(config)
        try writer.write(data, to: sessionManagerUIConfigURL)
    }

    func currentAuthData() throws -> Data {
        try Data(contentsOf: currentAuthURL)
    }

    func currentConfigData() throws -> Data? {
        guard fileManager.fileExists(atPath: currentConfigURL.path) else {
            return nil
        }
        return try Data(contentsOf: currentConfigURL)
    }

    func currentRuntimeMaterial() throws -> ProfileRuntimeMaterial {
        ProfileRuntimeMaterial(
            authData: try currentAuthData(),
            configData: try currentConfigData()
        )
    }

    func protectedMutationFileURLs(additionalFiles: [URL] = []) -> [URL] {
        [
            currentAuthURL,
            currentConfigURL,
            settingsURL,
            sessionManagerUIConfigURL,
            accountsIndexURL,
            stateDatabaseURL,
            stateDatabaseWALURL,
            stateDatabaseSHMURL,
            sessionIndexURL,
            sessionManagerDatabaseURL,
            sessionManagerDatabaseWALURL,
            sessionManagerDatabaseSHMURL,
        ] + additionalFiles
    }

    func accountMutationFileURLs(additionalFiles: [URL] = []) -> [URL] {
        [
            settingsURL,
            accountsIndexURL,
        ] + additionalFiles
    }

    private func ensureBaseDirectoryExists() {
        try? fileManager.createDirectory(
            at: baseURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try? fileManager.createDirectory(
            at: accountsRootURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
}
