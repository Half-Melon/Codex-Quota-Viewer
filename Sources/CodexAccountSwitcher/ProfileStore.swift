import Foundation

struct MigrationResult {
    var migratedCount = 0
    var errors: [String] = []

    var hasChanges: Bool {
        migratedCount > 0
    }
}

struct LoadIssue: Equatable {
    let message: String
}

struct ProfilesLoadResult {
    let profiles: [CodexProfile]
    let issues: [LoadIssue]
}

struct SettingsLoadResult {
    let settings: AppSettings
    let issues: [LoadIssue]
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
    static let credentialService = "CodexAccountSwitcher"
    static let legacyCredentialService = "CodexQuickSwitch"

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let credentialStore: any CredentialStore
    private let legacyCredentialStore: (any CredentialStore)?
    private let legacyBaseURL: URL?

    let baseURL: URL
    let profilesDirectoryURL: URL
    let settingsURL: URL
    let currentAuthURL: URL

    init(
        baseURL: URL? = nil,
        currentAuthURL: URL? = nil,
        credentialStore: (any CredentialStore)? = nil,
        legacyBaseURL: URL? = nil,
        legacyCredentialStore: (any CredentialStore)? = nil
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
            .appendingPathComponent("CodexAccountSwitcher", isDirectory: true)
        self.legacyBaseURL = legacyBaseURL ?? {
            guard baseURL == nil else { return nil }
            return home
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("CodexQuickSwitch", isDirectory: true)
        }()
        self.legacyCredentialStore = legacyCredentialStore ?? {
            guard credentialStore == nil else { return nil }
            return KeychainCredentialStore(service: Self.legacyCredentialService)
        }()
        profilesDirectoryURL = self.baseURL.appendingPathComponent("profiles", isDirectory: true)
        settingsURL = self.baseURL.appendingPathComponent("settings.json", isDirectory: false)
        self.currentAuthURL = currentAuthURL ?? home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
    }

    func loadProfiles() -> [CodexProfile] {
        loadProfilesResult().profiles
    }

    func loadProfilesResult() -> ProfilesLoadResult {
        ensureDirectoriesExist()

        let urls = (try? fileManager.contentsOfDirectory(
            at: profilesDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var issues: [LoadIssue] = []

        let profiles = urls
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".auth.json") }
            .compactMap { url -> CodexProfile? in
                do {
                    let data = try Data(contentsOf: url)
                    return try decoder.decode(CodexProfile.self, from: data)
                } catch {
                    issues.append(
                        LoadIssue(message: "档案文件损坏：\(url.lastPathComponent)")
                    )
                    return nil
                }
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

        return ProfilesLoadResult(profiles: profiles, issues: issues)
    }

    func loadSettings() -> AppSettings {
        loadSettingsResult().settings
    }

    func loadSettingsResult() -> SettingsLoadResult {
        ensureDirectoriesExist()

        guard fileManager.fileExists(atPath: settingsURL.path) else {
            return SettingsLoadResult(settings: AppSettings(lastActiveProfileID: nil), issues: [])
        }

        do {
            let data = try Data(contentsOf: settingsURL)
            let settings = try decoder.decode(AppSettings.self, from: data)
            return SettingsLoadResult(settings: settings, issues: [])
        } catch {
            return SettingsLoadResult(
                settings: AppSettings(lastActiveProfileID: nil),
                issues: [LoadIssue(message: "设置文件损坏：\(settingsURL.lastPathComponent)")]
            )
        }
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
        let profileURL = profileURL(for: profile.id)
        let account = credentialAccount(for: profile.id)

        if let authData {
            let previousCredential = try readCredentialIfExists(account: account)

            do {
                try credentialStore.upsert(data: authData, account: account)
                try data.write(to: profileURL, options: .atomic)
            } catch {
                try? restoreCredential(previousCredential, account: account)
                throw error
            }
        } else {
            try data.write(to: profileURL, options: .atomic)
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
        let shouldCheckLegacyService = settings.storageVersion < AppSettings.currentStorageVersion
        guard settings.storageVersion < AppSettings.currentStorageVersion || !legacyFiles.isEmpty || shouldCheckLegacyService else {
            return MigrationResult()
        }

        var result = MigrationResult()
        migrateLegacyKeychainEntriesIfNeeded(result: &result)

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
        migrateLegacyStorageLocationIfNeeded()
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

    private func readCredentialIfExists(account: String) throws -> Data? {
        if try credentialStore.contains(account: account) {
            return try credentialStore.read(account: account)
        }
        return nil
    }

    private func restoreCredential(_ data: Data?, account: String) throws {
        if let data {
            try credentialStore.upsert(data: data, account: account)
        } else {
            try credentialStore.delete(account: account)
        }
    }

    private func migrateLegacyStorageLocationIfNeeded() {
        guard let legacyBaseURL,
              legacyBaseURL.path != baseURL.path,
              fileManager.fileExists(atPath: legacyBaseURL.path) else {
            return
        }

        let parentURL = baseURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: baseURL.path) {
            try? fileManager.moveItem(at: legacyBaseURL, to: baseURL)
            return
        }

        let legacyItems = (try? fileManager.contentsOfDirectory(
            at: legacyBaseURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for legacyItem in legacyItems {
            let targetURL = baseURL.appendingPathComponent(legacyItem.lastPathComponent, isDirectory: false)
            guard !fileManager.fileExists(atPath: targetURL.path) else { continue }
            try? fileManager.moveItem(at: legacyItem, to: targetURL)
        }

        try? fileManager.removeItem(at: legacyBaseURL)
    }

    private func migrateLegacyKeychainEntriesIfNeeded(result: inout MigrationResult) {
        guard let legacyCredentialStore else { return }

        for profile in loadProfiles() {
            let account = credentialAccount(for: profile.id)

            do {
                if try credentialStore.contains(account: account) {
                    continue
                }

                guard try legacyCredentialStore.contains(account: account) else {
                    continue
                }

                let data = try legacyCredentialStore.read(account: account)
                try credentialStore.upsert(data: data, account: account)
                try legacyCredentialStore.delete(account: account)
                result.migratedCount += 1
            } catch {
                result.errors.append("迁移旧 Keychain 凭据失败：\(profile.name)")
            }
        }
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
