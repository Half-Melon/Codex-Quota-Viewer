import Foundation

struct MigrationResult {
    var migratedCount = 0
    var errors: [String] = []

    var hasChanges: Bool {
        migratedCount > 0
    }
}

enum ProfileStoreError: LocalizedError {
    case profileNotFound

    var errorDescription: String? {
        switch self {
        case .profileNotFound:
            return "找不到指定档案。"
        }
    }
}

final class ProfileStore {
    static let credentialService = "CodexQuickSwitch"

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let credentialStore: any CredentialStore

    let baseURL: URL
    let profilesDirectoryURL: URL
    let settingsURL: URL
    let currentAuthURL: URL

    init(
        baseURL: URL? = nil,
        currentAuthURL: URL? = nil,
        credentialStore: (any CredentialStore)? = nil
    ) {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.credentialStore = credentialStore ?? KeychainCredentialStore(service: Self.credentialService)

        let home = fileManager.homeDirectoryForCurrentUser
        self.baseURL = baseURL ?? home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("CodexQuickSwitch", isDirectory: true)
        profilesDirectoryURL = self.baseURL.appendingPathComponent("profiles", isDirectory: true)
        settingsURL = self.baseURL.appendingPathComponent("settings.json", isDirectory: false)
        self.currentAuthURL = currentAuthURL ?? home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
    }

    func loadProfiles() -> [CodexProfile] {
        ensureDirectoriesExist()

        let urls = (try? fileManager.contentsOfDirectory(
            at: profilesDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".auth.json") }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(CodexProfile.self, from: data)
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func loadSettings() -> AppSettings {
        ensureDirectoriesExist()

        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? decoder.decode(AppSettings.self, from: data) else {
            return AppSettings(lastActiveProfileID: nil)
        }

        return settings
    }

    func saveSettings(_ settings: AppSettings) throws {
        ensureDirectoriesExist()
        let data = try encoder.encode(settings)
        try data.write(to: settingsURL, options: .atomic)
    }

    func createProfile(
        name: String,
        authData: Data,
        snapshot: CachedProfileSnapshot?
    ) throws -> CodexProfile {
        ensureDirectoriesExist()

        let now = Date()
        let profile = CodexProfile(
            id: UUID(),
            name: name,
            cachedSnapshot: snapshot,
            createdAt: now,
            updatedAt: now
        )

        try save(profile, authData: authData)
        return profile
    }

    func save(_ profile: CodexProfile, authData: Data? = nil) throws {
        ensureDirectoriesExist()

        let data = try encoder.encode(profile)
        try data.write(to: profileURL(for: profile.id), options: .atomic)

        if let authData {
            try credentialStore.upsert(
                data: authData,
                account: credentialAccount(for: profile.id)
            )
        }
    }

    func updateProfile(
        id: UUID,
        name: String? = nil,
        authData: Data? = nil,
        snapshot: CachedProfileSnapshot? = nil
    ) throws {
        var profiles = loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError.profileNotFound
        }

        if let name {
            profiles[index].name = name
        }

        if let snapshot {
            profiles[index].cachedSnapshot = snapshot
        }

        profiles[index].updatedAt = Date()
        try save(profiles[index], authData: authData)
    }

    func readAuthData(for profileID: UUID) throws -> Data {
        try credentialStore.read(account: credentialAccount(for: profileID))
    }

    func currentAuthData() throws -> Data {
        try Data(contentsOf: currentAuthURL)
    }

    func overwriteCurrentAuthData(_ data: Data) throws {
        ensureDirectoriesExist()
        try fileManager.createDirectory(
            at: currentAuthURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: currentAuthURL, options: .atomic)
    }

    func deleteProfile(id: UUID) throws {
        let profileURL = profileURL(for: id)
        if fileManager.fileExists(atPath: profileURL.path) {
            try fileManager.removeItem(at: profileURL)
        }

        try credentialStore.delete(account: credentialAccount(for: id))
    }

    func migrateLegacyCredentialsIfNeeded(settings: inout AppSettings) -> MigrationResult {
        ensureDirectoriesExist()

        let legacyFiles = legacyAuthSidecarURLs()
        guard settings.storageVersion < AppSettings.currentStorageVersion || !legacyFiles.isEmpty else {
            return MigrationResult()
        }

        var result = MigrationResult()

        for legacyURL in legacyFiles {
            let fileName = legacyURL.lastPathComponent

            guard let profileID = legacyProfileID(from: legacyURL) else {
                result.errors.append("旧档案文件无法识别：\(fileName)")
                continue
            }

            let profileURL = profileURL(for: profileID)
            guard fileManager.fileExists(atPath: profileURL.path) else {
                result.errors.append("旧档案凭据缺少对应 metadata：\(fileName)")
                continue
            }

            do {
                let account = credentialAccount(for: profileID)
                if try credentialStore.contains(account: account) {
                    try fileManager.removeItem(at: legacyURL)
                    continue
                }

                let data = try Data(contentsOf: legacyURL)
                try credentialStore.upsert(data: data, account: account)
                try fileManager.removeItem(at: legacyURL)
                result.migratedCount += 1
            } catch {
                result.errors.append("迁移 \(fileName) 失败：\(error.localizedDescription)")
            }
        }

        if legacyAuthSidecarURLs().isEmpty {
            settings.storageVersion = AppSettings.currentStorageVersion
        }

        return result
    }

    private func ensureDirectoriesExist() {
        try? fileManager.createDirectory(
            at: profilesDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func profileURL(for id: UUID) -> URL {
        profilesDirectoryURL.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func authURL(for id: UUID) -> URL {
        profilesDirectoryURL.appendingPathComponent("\(id.uuidString).auth.json", isDirectory: false)
    }

    private func credentialAccount(for id: UUID) -> String {
        id.uuidString
    }

    private func legacyAuthSidecarURLs() -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: profilesDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { $0.lastPathComponent.hasSuffix(".auth.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func legacyProfileID(from url: URL) -> UUID? {
        let fileName = url.lastPathComponent
        guard fileName.hasSuffix(".auth.json") else { return nil }
        let rawID = String(fileName.dropLast(".auth.json".count))
        return UUID(uuidString: rawID)
    }
}
