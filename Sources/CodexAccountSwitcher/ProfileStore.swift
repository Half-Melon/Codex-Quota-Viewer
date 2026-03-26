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

private struct StoredCredentialBundle: Codable {
    var items: [String: Data]
}

enum ProfileStoreError: LocalizedError {
    case profileNotFound

    var errorDescription: String? {
        switch self {
        case .profileNotFound:
            return "找不到指定账号。"
        }
    }
}

final class ProfileStore {
    static let credentialService = "CodexAccountSwitcher"
    static let legacyCredentialService = "CodexQuickSwitch"
    static let bundledCredentialAccount = "__credential_bundle_v1__"

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let credentialStore: any CredentialStore
    private let legacyCredentialStore: (any CredentialStore)?
    private let legacyBaseURL: URL?
    private let credentialCacheLock = NSLock()
    private var cachedCredentialsByAccount: [String: Data]?

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
                        LoadIssue(message: "账号文件损坏：\(url.lastPathComponent)")
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
            let previousCredentials = try readAllCredentialsByAccount()
            var updatedCredentials = previousCredentials
            updatedCredentials[account] = authData

            do {
                try writeAllCredentialsByAccount(updatedCredentials)
                try data.write(to: profileURL, options: .atomic)
            } catch {
                try? writeAllCredentialsByAccount(previousCredentials)
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
        let account = credentialAccount(for: profileID)
        guard let data = try readAllCredentialsByAccount()[account] else {
            throw CredentialStoreError.itemNotFound
        }
        return data
    }

    func readAllAuthData() throws -> [UUID: Data] {
        Dictionary(
            uniqueKeysWithValues: try readAllCredentialsByAccount().compactMap { account, data in
                guard let profileID = UUID(uuidString: account) else { return nil }
                return (profileID, data)
            }
        )
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
        let account = credentialAccount(for: id)
        let previousCredentials = try readAllCredentialsByAccount()
        var updatedCredentials = previousCredentials
        updatedCredentials.removeValue(forKey: account)

        do {
            try writeAllCredentialsByAccount(updatedCredentials)

            if fileManager.fileExists(atPath: profileURL.path) {
                try fileManager.removeItem(at: profileURL)
            }
        } catch {
            try? writeAllCredentialsByAccount(previousCredentials)
            throw error
        }
    }

    func migrateLegacyCredentialsIfNeeded(settings: inout AppSettings) -> MigrationResult {
        ensureDirectoriesExist()

        let legacyFiles = legacyAuthSidecarURLs()
        let shouldCheckLegacyService = settings.storageVersion < AppSettings.currentStorageVersion
        guard settings.storageVersion < AppSettings.currentStorageVersion || !legacyFiles.isEmpty || shouldCheckLegacyService else {
            return MigrationResult()
        }

        var result = MigrationResult()
        let profiles = loadProfiles()
        var bundledCredentials = (try? readCredentialBundleFromStore()) ?? [:]
        var bundleChanged = false
        let legacySidecarsByProfileID: [UUID: URL] = Dictionary(
            uniqueKeysWithValues: legacyFiles.compactMap { url in
                guard let profileID = legacyProfileID(from: url) else { return nil }
                return (profileID, url)
            }
        )
        var rawCurrentAccountsToDelete = Set<String>()
        var rawLegacyAccountsToDelete = Set<String>()
        var sidecarsToDelete: [URL] = []

        for legacyURL in legacyFiles where legacyProfileID(from: legacyURL) == nil {
            result.errors.append("旧账号文件无法识别：\(legacyURL.lastPathComponent)")
        }

        for profile in profiles {
            let account = credentialAccount(for: profile.id)
            let sidecarURL = legacySidecarsByProfileID[profile.id]

            if let sidecarURL,
               !fileManager.fileExists(atPath: profileURL(for: profile.id).path) {
                result.errors.append("旧账号凭据缺少对应 metadata：\(sidecarURL.lastPathComponent)")
                continue
            }

            if bundledCredentials[account] == nil {
                do {
                    if let data = try readLegacyCredentialData(
                        account: account,
                        sidecarURL: sidecarURL
                    ) {
                        bundledCredentials[account] = data
                        bundleChanged = true
                        result.migratedCount += 1
                    }
                } catch {
                    result.errors.append("迁移账号 \(profile.name) 失败：\(error.localizedDescription)")
                    continue
                }
            }

            guard bundledCredentials[account] != nil else { continue }

            do {
                if try credentialStore.contains(account: account) {
                    rawCurrentAccountsToDelete.insert(account)
                }
            } catch {
                result.errors.append("检查旧 Keychain 凭据失败：\(profile.name)")
            }

            do {
                if try legacyCredentialStore?.contains(account: account) == true {
                    rawLegacyAccountsToDelete.insert(account)
                }
            } catch {
                result.errors.append("检查旧 Keychain 服务失败：\(profile.name)")
            }

            if let sidecarURL {
                sidecarsToDelete.append(sidecarURL)
            }
        }

        if bundleChanged {
            do {
                try writeAllCredentialsByAccount(bundledCredentials)
            } catch {
                result.errors.append("迁移账号凭据失败：\(error.localizedDescription)")
                return result
            }
        } else {
            cacheCredentials(bundledCredentials)
        }

        for account in rawCurrentAccountsToDelete {
            try? credentialStore.delete(account: account)
        }

        for account in rawLegacyAccountsToDelete {
            try? legacyCredentialStore?.delete(account: account)
        }

        for sidecarURL in sidecarsToDelete {
            try? fileManager.removeItem(at: sidecarURL)
        }

        if !hasLegacyArtifacts(for: profiles) {
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

    private func credentialAccount(for id: UUID) -> String {
        id.uuidString
    }

    private func readAllCredentialsByAccount() throws -> [String: Data] {
        if let cached = cachedCredentials() {
            return cached
        }

        let loaded = try readCredentialBundleFromStore()
        cacheCredentials(loaded)
        return loaded
    }

    private func writeAllCredentialsByAccount(_ credentials: [String: Data]) throws {
        if credentials.isEmpty {
            try credentialStore.delete(account: Self.bundledCredentialAccount)
            cacheCredentials([:])
            return
        }

        let data = try encoder.encode(StoredCredentialBundle(items: credentials))
        try credentialStore.upsert(data: data, account: Self.bundledCredentialAccount)
        cacheCredentials(credentials)
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

    private func readCredentialBundleFromStore() throws -> [String: Data] {
        do {
            let data = try credentialStore.read(account: Self.bundledCredentialAccount)
            let bundle = try decoder.decode(StoredCredentialBundle.self, from: data)
            return bundle.items
        } catch CredentialStoreError.itemNotFound {
            return [:]
        } catch is DecodingError {
            throw CredentialStoreError.invalidStoredData
        }
    }

    private func readLegacyCredentialData(
        account: String,
        sidecarURL: URL?
    ) throws -> Data? {
        if try credentialStore.contains(account: account) {
            return try credentialStore.read(account: account)
        }

        if let sidecarURL {
            return try Data(contentsOf: sidecarURL)
        }

        if try legacyCredentialStore?.contains(account: account) == true {
            return try legacyCredentialStore?.read(account: account)
        }

        return nil
    }

    private func hasLegacyArtifacts(for profiles: [CodexProfile]) -> Bool {
        if !legacyAuthSidecarURLs().isEmpty {
            return true
        }

        for profile in profiles {
            let account = credentialAccount(for: profile.id)
            if (try? credentialStore.contains(account: account)) == true {
                return true
            }

            if (try? legacyCredentialStore?.contains(account: account)) == true {
                return true
            }
        }

        return false
    }

    private func cachedCredentials() -> [String: Data]? {
        credentialCacheLock.lock()
        defer { credentialCacheLock.unlock() }
        return cachedCredentialsByAccount
    }

    private func cacheCredentials(_ credentials: [String: Data]) {
        credentialCacheLock.lock()
        cachedCredentialsByAccount = credentials
        credentialCacheLock.unlock()
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
