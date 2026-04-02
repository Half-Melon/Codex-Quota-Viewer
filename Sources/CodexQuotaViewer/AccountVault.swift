import Foundation

enum VaultAccountSource: String, Codable, Equatable {
    case currentRuntime
    case manualChatGPT
    case manualAPI

    var label: String {
        switch self {
        case .currentRuntime:
            return AppLocalization.localized(en: "Captured from current Codex runtime", zh: "来自当前 Codex 运行时")
        case .manualChatGPT:
            return AppLocalization.localized(en: "Added with ChatGPT login", zh: "通过 ChatGPT 登录添加")
        case .manualAPI:
            return AppLocalization.localized(en: "Added as API account", zh: "作为 API 账号添加")
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case Self.currentRuntime.rawValue:
            self = .currentRuntime
        case Self.manualChatGPT.rawValue:
            self = .manualChatGPT
        case Self.manualAPI.rawValue:
            self = .manualAPI
        case "legacyCCSwitch":
            self = .currentRuntime
        default:
            self = .currentRuntime
        }
    }
}

struct VaultAccountMetadata: Codable, Equatable, Identifiable {
    let id: String
    var displayName: String
    let authMode: CodexAuthMode
    let providerID: String?
    let baseURL: String?
    let model: String?
    let createdAt: Date
    var lastUsedAt: Date?
    var source: VaultAccountSource
    let runtimeKey: String

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case authMode
        case providerID
        case baseURL
        case model
        case createdAt
        case lastUsedAt
        case source
        case runtimeKey
        case isImportedFromCCSwitch
    }

    init(
        id: String,
        displayName: String,
        authMode: CodexAuthMode,
        providerID: String?,
        baseURL: String?,
        model: String?,
        createdAt: Date,
        lastUsedAt: Date? = nil,
        source: VaultAccountSource,
        runtimeKey: String
    ) {
        self.id = id
        self.displayName = displayName
        self.authMode = authMode
        self.providerID = providerID
        self.baseURL = baseURL
        self.model = model
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.source = source
        self.runtimeKey = runtimeKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        authMode = try container.decode(CodexAuthMode.self, forKey: .authMode)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        let decodedSource = try container.decodeIfPresent(VaultAccountSource.self, forKey: .source)
        source = sanitizeLegacyVaultSource(decodedSource, authMode: authMode)
        runtimeKey = try container.decode(String.self, forKey: .runtimeKey)
        _ = try container.decodeIfPresent(Bool.self, forKey: .isImportedFromCCSwitch)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(authMode, forKey: .authMode)
        try container.encodeIfPresent(providerID, forKey: .providerID)
        try container.encodeIfPresent(baseURL, forKey: .baseURL)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try container.encode(source, forKey: .source)
        try container.encode(runtimeKey, forKey: .runtimeKey)
    }
}

struct VaultAccountRecord: Equatable, Identifiable {
    let metadata: VaultAccountMetadata
    let runtimeMaterial: ProfileRuntimeMaterial
    let directoryURL: URL
    let metadataURL: URL
    let authURL: URL
    let configURL: URL

    var id: String { metadata.id }

    var protectedFileURLs: [URL] {
        [
            metadataURL,
            authURL,
            configURL,
        ]
    }
}

struct AccountVaultSnapshot: Equatable {
    let accounts: [VaultAccountRecord]
}

struct VaultAccountUpsertResult: Equatable {
    let record: VaultAccountRecord
    let inserted: Bool
    let updated: Bool
}

struct VaultAccountNormalizationPlan {
    let originalRecords: [VaultAccountRecord]
    let normalizedRecords: [VaultAccountRecord]
    let obsoleteRecordIDs: [String]
    let idMapping: [String: String]

    var hasChanges: Bool {
        guard originalRecords.count == normalizedRecords.count,
              obsoleteRecordIDs.isEmpty else {
            return true
        }

        return zip(originalRecords, normalizedRecords).contains { $0 != $1 }
    }
}

private struct NormalizationCandidate {
    let original: VaultAccountRecord
    let normalizedRuntime: ProfileRuntimeMaterial
    let targetID: String
}

enum VaultAccountStoreError: LocalizedError {
    case missingAccount(String)

    var errorDescription: String? {
        switch self {
        case .missingAccount(let id):
            return "Saved account not found: \(id)"
        }
    }
}

final class VaultAccountStore {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let recordWriter: VaultAccountRecordWriter

    let accountsRootURL: URL
    let indexURL: URL

    init(
        accountsRootURL: URL,
        indexURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.accountsRootURL = accountsRootURL
        self.indexURL = indexURL ?? accountsRootURL.appendingPathComponent("accounts.json", isDirectory: false)
        self.fileManager = fileManager
        self.recordWriter = VaultAccountRecordWriter(fileManager: fileManager)

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadSnapshot() throws -> AccountVaultSnapshot {
        try ensureAccountsDirectoryExists()

        let indexedMetadata = (try? loadIndex()) ?? []
        let indexedIDs = indexedMetadata.map(\.id)

        let directories = try fileManager.contentsOfDirectory(
            at: accountsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        var recordsByID: [String: VaultAccountRecord] = [:]
        for directoryURL in directories {
            guard let record = try loadRecord(at: directoryURL) else {
                continue
            }
            recordsByID[record.id] = record
        }

        var ordered: [VaultAccountRecord] = []
        for id in indexedIDs {
            if let record = recordsByID.removeValue(forKey: id) {
                ordered.append(record)
            }
        }

        ordered.append(contentsOf: recordsByID.values.sorted {
            $0.metadata.displayName.localizedCaseInsensitiveCompare($1.metadata.displayName) == .orderedAscending
        })

        return AccountVaultSnapshot(accounts: ordered)
    }

    func createAPIAccount(
        displayName: String,
        apiKey: String,
        baseURL: String,
        model: String,
        writer: FileDataWriting = DirectFileDataWriter()
    ) throws -> VaultAccountRecord {
        let runtime = ProfileRuntimeMaterial(
            authData: makeAPIKeyAuthData(apiKey: apiKey),
            configData: synthesizedOpenAICompatibleConfig(
                baseURL: baseURL,
                model: model
            )
        )

        return try upsertAccount(
            fallbackDisplayName: displayName,
            source: .manualAPI,
            runtimeMaterial: runtime,
            writer: writer
        ).record
    }

    func upsertAccount(
        fallbackDisplayName: String,
        source: VaultAccountSource,
        runtimeMaterial: ProfileRuntimeMaterial,
        writer: FileDataWriting = DirectFileDataWriter()
    ) throws -> VaultAccountUpsertResult {
        try ensureAccountsDirectoryExists()

        let canonicalRuntime = canonicalRuntimeMaterialForStorage(runtimeMaterial)
        let accountID = accountID(for: canonicalRuntime)
        let snapshot = try loadSnapshot()

        if let existing = snapshot.accounts.first(where: { $0.id == accountID }) {
            let merged = mergedRecord(
                existing: existing,
                fallbackDisplayName: fallbackDisplayName,
                source: source,
                runtimeMaterial: canonicalRuntime,
            )

            if merged != existing {
                try writeRecord(merged, writer: writer)
                try syncIndex(
                    records: snapshot.accounts.map { $0.id == existing.id ? merged : $0 },
                    writer: writer
                )
                return VaultAccountUpsertResult(record: merged, inserted: false, updated: true)
            }

            return VaultAccountUpsertResult(record: existing, inserted: false, updated: false)
        }

        let summary = summarizeRuntimeConfig(canonicalRuntime.configData)
        let now = Date()
        let metadata = VaultAccountMetadata(
            id: accountID,
            displayName: fallbackDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? defaultDisplayName(for: source, authMode: resolveAuthMode(authData: canonicalRuntime.authData))
                : fallbackDisplayName,
            authMode: resolvedStoredAuthMode(for: canonicalRuntime),
            providerID: summary.providerID,
            baseURL: summary.baseURL,
            model: summary.model,
            createdAt: now,
            lastUsedAt: nil,
            source: source,
            runtimeKey: stableAccountIdentityKey(for: canonicalRuntime)
        )
        let record = makeRecord(metadata: metadata, runtimeMaterial: canonicalRuntime)
        try writeRecord(record, writer: writer)
        try syncIndex(records: snapshot.accounts + [record], writer: writer)
        return VaultAccountUpsertResult(record: record, inserted: true, updated: false)
    }

    func normalizationPlan() throws -> VaultAccountNormalizationPlan? {
        let snapshot = try loadSnapshot()
        guard !snapshot.accounts.isEmpty else {
            return nil
        }

        let candidates = snapshot.accounts.map { record in
            let normalizedRuntime = canonicalRuntimeMaterialForStorage(record.runtimeMaterial)
            return NormalizationCandidate(
                original: record,
                normalizedRuntime: normalizedRuntime,
                targetID: accountID(for: normalizedRuntime)
            )
        }

        var grouped: [String: [NormalizationCandidate]] = [:]
        for candidate in candidates {
            grouped[candidate.targetID, default: []].append(candidate)
        }

        var normalizedRecords: [VaultAccountRecord] = []
        var emittedIDs = Set<String>()
        for candidate in candidates {
            guard emittedIDs.insert(candidate.targetID).inserted,
                  let group = grouped[candidate.targetID] else {
                continue
            }
            normalizedRecords.append(makeNormalizedRecord(targetID: candidate.targetID, from: group))
        }

        let normalizedIDs = Set(normalizedRecords.map(\.id))
        let obsoleteRecordIDs = snapshot.accounts
            .map(\.id)
            .filter { !normalizedIDs.contains($0) }
        let mapping = Dictionary(uniqueKeysWithValues: candidates.map { ($0.original.id, $0.targetID) })

        let plan = VaultAccountNormalizationPlan(
            originalRecords: snapshot.accounts,
            normalizedRecords: normalizedRecords,
            obsoleteRecordIDs: obsoleteRecordIDs,
            idMapping: mapping
        )
        return plan.hasChanges ? plan : nil
    }

    func applyNormalizationPlan(
        _ plan: VaultAccountNormalizationPlan,
        writer: FileDataWriting = DirectFileDataWriter()
    ) throws {
        for record in plan.normalizedRecords {
            try writeRecord(record, writer: writer)
        }

        try syncIndex(records: plan.normalizedRecords, writer: writer)

        let keptIDs = Set(plan.normalizedRecords.map(\.id))
        for original in plan.originalRecords where !keptIDs.contains(original.id) {
            try? fileManager.removeItem(at: original.metadataURL)
            try? fileManager.removeItem(at: original.authURL)
            try? fileManager.removeItem(at: original.configURL)
            try? fileManager.removeItem(at: original.directoryURL)
        }
    }

    func renameAccount(
        id: String,
        newDisplayName: String,
        writer: FileDataWriting = DirectFileDataWriter()
    ) throws -> VaultAccountRecord {
        let snapshot = try loadSnapshot()
        guard var existing = snapshot.accounts.first(where: { $0.id == id }) else {
            throw VaultAccountStoreError.missingAccount(id)
        }

        existing = makeRecord(
            metadata: {
                var metadata = existing.metadata
                metadata.displayName = newDisplayName
                return metadata
            }(),
            runtimeMaterial: existing.runtimeMaterial
        )

        try writeRecord(existing, writer: writer)
        try syncIndex(records: snapshot.accounts.map { $0.id == id ? existing : $0 }, writer: writer)
        return existing
    }

    func noteAccountUsed(
        id: String,
        writer: FileDataWriting = DirectFileDataWriter()
    ) throws -> VaultAccountRecord {
        let snapshot = try loadSnapshot()
        guard var existing = snapshot.accounts.first(where: { $0.id == id }) else {
            throw VaultAccountStoreError.missingAccount(id)
        }

        existing = makeRecord(
            metadata: {
                var metadata = existing.metadata
                metadata.lastUsedAt = Date()
                return metadata
            }(),
            runtimeMaterial: existing.runtimeMaterial
        )

        try writeRecord(existing, writer: writer)
        try syncIndex(records: snapshot.accounts.map { $0.id == id ? existing : $0 }, writer: writer)
        return existing
    }

    func forgetAccount(
        id: String,
        writer: ProtectedFileMutationContext
    ) throws {
        let snapshot = try loadSnapshot()
        guard let existing = snapshot.accounts.first(where: { $0.id == id }) else {
            throw VaultAccountStoreError.missingAccount(id)
        }

        try writer.removeItemIfExists(at: existing.metadataURL)
        try writer.removeItemIfExists(at: existing.authURL)
        try writer.removeItemIfExists(at: existing.configURL)
        try syncIndex(records: snapshot.accounts.filter { $0.id != id }, writer: writer)

        try? fileManager.removeItem(at: existing.directoryURL)
    }

    func protectedMutationFileURLs(forAccountIDs ids: [String]) -> [URL] {
        var urls = [indexURL]
        for id in ids {
            let urlsForAccount = protectedMutationFileURLs(forAccountID: id)
            urls.append(contentsOf: urlsForAccount)
        }
        return urls
    }

    func protectedMutationFileURLs(forAccountID id: String) -> [URL] {
        let directoryURL = accountDirectoryURL(for: id)
        return [
            directoryURL.appendingPathComponent("metadata.json", isDirectory: false),
            directoryURL.appendingPathComponent("auth.json", isDirectory: false),
            directoryURL.appendingPathComponent("config.toml", isDirectory: false),
        ]
    }

    func allProtectedFileURLs() throws -> [URL] {
        let snapshot = try loadSnapshot()
        return [indexURL] + snapshot.accounts.flatMap(\.protectedFileURLs)
    }

    func accountID(for runtimeMaterial: ProfileRuntimeMaterial) -> String {
        stableAccountRecordID(for: runtimeMaterial)
    }

    private func loadIndex() throws -> [VaultAccountMetadata] {
        guard fileManager.fileExists(atPath: indexURL.path) else {
            return []
        }
        return try decoder.decode([VaultAccountMetadata].self, from: Data(contentsOf: indexURL))
    }

    private func loadRecord(at directoryURL: URL) throws -> VaultAccountRecord? {
        let metadataURL = directoryURL.appendingPathComponent("metadata.json", isDirectory: false)
        let authURL = directoryURL.appendingPathComponent("auth.json", isDirectory: false)
        let configURL = directoryURL.appendingPathComponent("config.toml", isDirectory: false)

        guard fileManager.fileExists(atPath: metadataURL.path),
              fileManager.fileExists(atPath: authURL.path) else {
            return nil
        }

        let metadata = try decoder.decode(VaultAccountMetadata.self, from: Data(contentsOf: metadataURL))
        let authData = try Data(contentsOf: authURL)
        let configData = fileManager.fileExists(atPath: configURL.path)
            ? try Data(contentsOf: configURL)
            : nil

        return VaultAccountRecord(
            metadata: metadata,
            runtimeMaterial: ProfileRuntimeMaterial(authData: authData, configData: configData),
            directoryURL: directoryURL,
            metadataURL: metadataURL,
            authURL: authURL,
            configURL: configURL
        )
    }

    private func makeRecord(
        metadata: VaultAccountMetadata,
        runtimeMaterial: ProfileRuntimeMaterial
    ) -> VaultAccountRecord {
        let directoryURL = accountDirectoryURL(for: metadata.id)
        return VaultAccountRecord(
            metadata: metadata,
            runtimeMaterial: runtimeMaterial,
            directoryURL: directoryURL,
            metadataURL: directoryURL.appendingPathComponent("metadata.json", isDirectory: false),
            authURL: directoryURL.appendingPathComponent("auth.json", isDirectory: false),
            configURL: directoryURL.appendingPathComponent("config.toml", isDirectory: false)
        )
    }

    private func writeRecord(_ record: VaultAccountRecord, writer: FileDataWriting) throws {
        try recordWriter.write(record, writer: writer)
    }

    private func syncIndex(records: [VaultAccountRecord], writer: FileDataWriting) throws {
        let orderedMetadata = records
            .map(\.metadata)
            .sorted { lhs, rhs in
                if lhs.lastUsedAt != rhs.lastUsedAt {
                    return (lhs.lastUsedAt ?? lhs.createdAt) > (rhs.lastUsedAt ?? rhs.createdAt)
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        try writer.write(encoder.encode(orderedMetadata), to: indexURL)
    }

    private func ensureAccountsDirectoryExists() throws {
        try fileManager.createDirectory(
            at: accountsRootURL,
            withIntermediateDirectories: true
        )
    }

    private func accountDirectoryURL(for id: String) -> URL {
        accountsRootURL.appendingPathComponent(id, isDirectory: true)
    }

    private func defaultDisplayName(
        for source: VaultAccountSource,
        authMode: CodexAuthMode
    ) -> String {
        switch (source, authMode) {
        case (.manualAPI, _):
            return AppLocalization.localized(en: "API Account", zh: "API 账号")
        case (.manualChatGPT, _):
            return AppLocalization.localized(en: "ChatGPT Account", zh: "ChatGPT 账号")
        case (.currentRuntime, _):
            return AppLocalization.localized(en: "Current Account", zh: "当前账号")
        }
    }

    private func resolvedStoredAuthMode(for runtimeMaterial: ProfileRuntimeMaterial) -> CodexAuthMode {
        let authMode = resolveAuthMode(authData: runtimeMaterial.authData)
        return authMode == .unknown ? .chatgpt : authMode
    }

    private func mergedRecord(
        existing: VaultAccountRecord,
        fallbackDisplayName: String,
        source: VaultAccountSource,
        runtimeMaterial: ProfileRuntimeMaterial
    ) -> VaultAccountRecord {
        let summary = summarizeRuntimeConfig(runtimeMaterial.configData)
        let trimmedFallback = fallbackDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let mergedDisplayName = shouldReplaceDisplayName(
            existing.metadata.displayName,
            existingSource: existing.metadata.source,
            with: trimmedFallback,
            candidateSource: source
        )
            ? trimmedFallback
            : existing.metadata.displayName
        let mergedSource = sourcePriority(existing.metadata.source) <= sourcePriority(source)
            ? existing.metadata.source
            : source

        let metadata = VaultAccountMetadata(
            id: existing.metadata.id,
            displayName: mergedDisplayName,
            authMode: resolvedStoredAuthMode(for: runtimeMaterial),
            providerID: summary.providerID,
            baseURL: summary.baseURL,
            model: summary.model,
            createdAt: existing.metadata.createdAt,
            lastUsedAt: existing.metadata.lastUsedAt,
            source: mergedSource,
            runtimeKey: stableAccountIdentityKey(for: runtimeMaterial)
        )
        return makeRecord(metadata: metadata, runtimeMaterial: runtimeMaterial)
    }

    private func makeNormalizedRecord(
        targetID: String,
        from candidates: [NormalizationCandidate]
    ) -> VaultAccountRecord {
        let preferred = candidates.sorted(by: normalizationCandidateComparator).first ?? candidates[0]
        let summary = summarizeRuntimeConfig(preferred.normalizedRuntime.configData)
        let mergedCreatedAt = candidates.map { $0.original.metadata.createdAt }.min() ?? preferred.original.metadata.createdAt
        let mergedLastUsedAt = candidates.compactMap { $0.original.metadata.lastUsedAt }.max()
        let mergedDisplayName = preferredDisplayName(from: candidates) ?? preferred.original.metadata.displayName

        let metadata = VaultAccountMetadata(
            id: targetID,
            displayName: mergedDisplayName,
            authMode: resolvedStoredAuthMode(for: preferred.normalizedRuntime),
            providerID: summary.providerID,
            baseURL: summary.baseURL,
            model: summary.model,
            createdAt: mergedCreatedAt,
            lastUsedAt: mergedLastUsedAt,
            source: preferred.original.metadata.source,
            runtimeKey: stableAccountIdentityKey(for: preferred.normalizedRuntime)
        )
        return makeRecord(metadata: metadata, runtimeMaterial: preferred.normalizedRuntime)
    }

    private func normalizationCandidateComparator(
        lhs: NormalizationCandidate,
        rhs: NormalizationCandidate
    ) -> Bool {
        let lhsRefresh = authLastRefreshDate(from: lhs.original.runtimeMaterial.authData) ?? .distantPast
        let rhsRefresh = authLastRefreshDate(from: rhs.original.runtimeMaterial.authData) ?? .distantPast
        if lhsRefresh != rhsRefresh {
            return lhsRefresh > rhsRefresh
        }

        let lhsPriority = sourcePriority(lhs.original.metadata.source)
        let rhsPriority = sourcePriority(rhs.original.metadata.source)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        let lhsLastUsed = lhs.original.metadata.lastUsedAt ?? .distantPast
        let rhsLastUsed = rhs.original.metadata.lastUsedAt ?? .distantPast
        if lhsLastUsed != rhsLastUsed {
            return lhsLastUsed > rhsLastUsed
        }

        return lhs.original.metadata.createdAt > rhs.original.metadata.createdAt
    }

    private func preferredDisplayName(from candidates: [NormalizationCandidate]) -> String? {
        candidates
            .map(\.original.metadata)
            .sorted(by: displayNameMetadataComparator)
            .map(\.displayName)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func displayNameMetadataComparator(lhs: VaultAccountMetadata, rhs: VaultAccountMetadata) -> Bool {
        let lhsScore = displayNameSpecificityScore(lhs.displayName, source: lhs.source)
        let rhsScore = displayNameSpecificityScore(rhs.displayName, source: rhs.source)
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }

        let lhsLastUsed = lhs.lastUsedAt ?? lhs.createdAt
        let rhsLastUsed = rhs.lastUsedAt ?? rhs.createdAt
        if lhsLastUsed != rhsLastUsed {
            return lhsLastUsed > rhsLastUsed
        }

        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    private func displayNameSpecificityScore(_ displayName: String, source: VaultAccountSource) -> Int {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return 0
        }

        var score = 0
        if trimmed.contains("@") {
            score += 100
            if trimmed != trimmed.lowercased() {
                score += 5
            }
        }
        if !genericDisplayNames.contains(trimmed.lowercased()) {
            score += 20
        }
        score += max(0, 10 - displayNameSourcePriority(source))
        return score
    }

    private func sourcePriority(_ source: VaultAccountSource) -> Int {
        switch source {
        case .manualChatGPT, .manualAPI:
            return 0
        case .currentRuntime:
            return 1
        }
    }

    private func displayNameSourcePriority(_ source: VaultAccountSource) -> Int {
        switch source {
        case .manualChatGPT, .manualAPI:
            return 0
        case .currentRuntime:
            return 1
        }
    }

    private func shouldReplaceDisplayName(
        _ existing: String,
        existingSource: VaultAccountSource,
        with candidate: String,
        candidateSource: VaultAccountSource
    ) -> Bool {
        guard !candidate.isEmpty else {
            return false
        }

        return displayNameSpecificityScore(candidate, source: candidateSource)
            > displayNameSpecificityScore(existing, source: existingSource)
    }
}

private let genericDisplayNames: Set<String> = [
    "chatgpt account",
    "api account",
    "current account",
    "chatgpt 账号",
    "api 账号",
    "当前账号",
    "openai",
]

private func sanitizeLegacyVaultSource(
    _ source: VaultAccountSource?,
    authMode: CodexAuthMode
) -> VaultAccountSource {
    guard let source else {
        return authMode == .apiKey ? .manualAPI : .currentRuntime
    }

    switch source {
    case .currentRuntime:
        return .currentRuntime
    case .manualChatGPT:
        return .manualChatGPT
    case .manualAPI:
        return .manualAPI
    }
}

private func authLastRefreshDate(from authData: Data) -> Date? {
    guard let envelope = try? JSONDecoder().decode(AuthEnvelope.self, from: authData),
          let lastRefresh = envelope.lastRefresh else {
        return nil
    }

    return ISO8601DateFormatter().date(from: lastRefresh)
}
