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

    let baseURL: URL
    let settingsURL: URL
    let currentAuthURL: URL
    let currentConfigURL: URL

    init(
        baseURL: URL? = nil,
        currentAuthURL: URL? = nil,
        homeDirectoryOverride: URL? = nil
    ) {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        decoder = JSONDecoder()

        let home = homeDirectoryOverride ?? fileManager.homeDirectoryForCurrentUser
        let defaultBaseURL = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(AppIdentity.supportDirectoryName, isDirectory: true)
        self.baseURL = baseURL ?? defaultBaseURL
        settingsURL = self.baseURL.appendingPathComponent("settings.json", isDirectory: false)
        self.currentAuthURL = currentAuthURL ?? home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
        currentConfigURL = self.currentAuthURL.deletingLastPathComponent()
            .appendingPathComponent("config.toml", isDirectory: false)
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
                issues: [LoadIssue(message: "设置文件损坏：\(settingsURL.lastPathComponent)")]
            )
        }
    }

    func saveSettings(_ settings: AppSettings) throws {
        ensureBaseDirectoryExists()
        let data = try encoder.encode(settings)
        try data.write(to: settingsURL, options: .atomic)
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

    private func ensureBaseDirectoryExists() {
        try? fileManager.createDirectory(
            at: baseURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
}
