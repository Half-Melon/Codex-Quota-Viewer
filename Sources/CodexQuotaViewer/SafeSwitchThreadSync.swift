import Foundation

enum LocalSQLiteQueryError: LocalizedError {
    case sqliteUnavailable
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .sqliteUnavailable:
            return "sqlite3 is required to inspect local thread metadata."
        case .queryFailed(let message):
            return message
        }
    }
}

struct RolloutProviderSyncResult: Equatable {
    let updatedFiles: [URL]
}

final class RolloutProviderSynchronizer {
    private let fileManager = FileManager.default

    func plannedUpdates(in roots: [URL], targetProvider: String) throws -> [URL] {
        var updates: [URL] = []

        for fileURL in try rolloutFiles(in: roots) {
            if try updatedContentIfNeeded(for: fileURL, targetProvider: targetProvider) != nil {
                updates.append(fileURL)
            }
        }

        return updates.sorted { $0.path < $1.path }
    }

    func syncProviders(
        in roots: [URL],
        targetProvider: String,
        writer: FileDataWriting = DirectFileDataWriter()
    ) throws -> RolloutProviderSyncResult {
        var updatedFiles: [URL] = []

        for fileURL in try rolloutFiles(in: roots) {
            guard let updatedContent = try updatedContentIfNeeded(for: fileURL, targetProvider: targetProvider) else {
                continue
            }

            try writer.write(updatedContent, to: fileURL)
            updatedFiles.append(fileURL)
        }

        return RolloutProviderSyncResult(updatedFiles: updatedFiles.sorted { $0.path < $1.path })
    }

    func providerCounts(in roots: [URL]) throws -> [ProviderCount] {
        var counts: [String: Int] = [:]

        for fileURL in try rolloutFiles(in: roots) {
            guard let provider = try sessionMetaProvider(in: fileURL) else {
                continue
            }
            counts[provider, default: 0] += 1
        }

        return counts
            .map { ProviderCount(providerID: $0.key, count: $0.value) }
            .sorted {
                if $0.count == $1.count {
                    return $0.providerID < $1.providerID
                }
                return $0.count > $1.count
            }
    }

    func sessionMetaProvider(in fileURL: URL) throws -> String? {
        guard let firstLine = try readFirstLine(in: fileURL),
              !firstLine.isEmpty else {
            return nil
        }

        guard let object = try JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else {
            return nil
        }

        return payload["model_provider"] as? String
    }

    private func rolloutFiles(in roots: [URL]) throws -> [URL] {
        var files: [URL] = []

        for root in roots {
            guard fileManager.fileExists(atPath: root.path) else {
                continue
            }

            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jsonl" else { continue }
                files.append(fileURL)
            }
        }

        return files
    }

    private func updatedContentIfNeeded(
        for fileURL: URL,
        targetProvider: String
    ) throws -> Data? {
        guard let firstLine = try readFirstLine(in: fileURL),
              !firstLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        guard var object = try JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any],
              let type = object["type"] as? String,
              type == "session_meta",
              var payload = object["payload"] as? [String: Any] else {
            return nil
        }

        let existingProvider = (payload["model_provider"] as? String) ?? ""
        guard existingProvider != targetProvider else {
            return nil
        }

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")

        payload["model_provider"] = targetProvider
        object["payload"] = payload

        let firstLineData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let firstLineString = String(data: firstLineData, encoding: .utf8) ?? firstLine
        var nextLines = lines
        nextLines[0] = firstLineString
        return Data(nextLines.joined(separator: "\n").utf8)
    }

    private func readFirstLine(in fileURL: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        var buffer = Data()

        while true {
            let chunk = try handle.read(upToCount: 4096) ?? Data()
            if chunk.isEmpty {
                break
            }

            if let newlineIndex = chunk.firstIndex(of: 0x0A) {
                buffer.append(chunk.prefix(upTo: newlineIndex))
                break
            }

            buffer.append(chunk)
        }

        if buffer.last == 0x0D {
            buffer.removeLast()
        }

        guard !buffer.isEmpty else {
            return nil
        }

        return String(data: buffer, encoding: .utf8)
    }
}

final class LocalThreadSyncInspector {
    typealias QueryRunner = (URL, String) throws -> String

    private let rolloutSynchronizer: RolloutProviderSynchronizer
    private let queryRunner: QueryRunner

    init(
        rolloutSynchronizer: RolloutProviderSynchronizer = RolloutProviderSynchronizer(),
        queryRunner: QueryRunner? = nil
    ) {
        self.rolloutSynchronizer = rolloutSynchronizer
        self.queryRunner = queryRunner ?? Self.defaultQueryRunner
    }

    func inspect(
        store: ProfileStore,
        expectedProviderID: String?
    ) -> LocalThreadSyncStatus {
        let rolloutProviders = (try? rolloutSynchronizer.providerCounts(
            in: [store.sessionsRootURL, store.archivedSessionsRootURL]
        )) ?? []

        let threadProviders: [ProviderCount]
        if FileManager.default.fileExists(atPath: store.stateDatabaseURL.path) {
            do {
                threadProviders = try stateThreadProviderCounts(databaseURL: store.stateDatabaseURL)
            } catch {
                return .unavailable("State DB could not be read.")
            }
        } else {
            threadProviders = []
        }

        if rolloutProviders.isEmpty, threadProviders.isEmpty {
            return .unavailable("No local threads found.")
        }

        let normalizedExpected = expectedProviderID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateExpected = (normalizedExpected?.isEmpty == false)
            ? normalizedExpected
            : ([rolloutProviders, threadProviders]
                .flatMap { $0 }
                .first?.providerID)

        guard let expected = candidateExpected else {
            return .unavailable("Provider metadata is unavailable.")
        }

        let rolloutMismatch = rolloutProviders.contains { $0.providerID != expected }
        let threadMismatch = threadProviders.contains { $0.providerID != expected }

        if rolloutMismatch || threadMismatch {
            return .repairNeeded(
                expectedProvider: expected,
                rolloutProviders: rolloutProviders,
                threadProviders: threadProviders
            )
        }

        return .healthy(expectedProvider: expected)
    }

    private func stateThreadProviderCounts(databaseURL: URL) throws -> [ProviderCount] {
        let sql = """
        SELECT COALESCE(TRIM(model_provider), ''), COUNT(*)
        FROM threads
        GROUP BY COALESCE(TRIM(model_provider), '')
        ORDER BY COUNT(*) DESC, COALESCE(TRIM(model_provider), '') ASC;
        """

        let output = try queryRunner(databaseURL, sql)
        return output
            .components(separatedBy: .newlines)
            .compactMap { line -> ProviderCount? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return nil
                }

                let columns = trimmed.components(separatedBy: "\t")
                guard columns.count == 2,
                      let count = Int(columns[1]) else {
                    return nil
                }

                return ProviderCount(providerID: columns[0], count: count)
            }
    }

    private static func defaultQueryRunner(dbURL: URL, sql: String) throws -> String {
        let sqliteURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        guard FileManager.default.isExecutableFile(atPath: sqliteURL.path) else {
            throw LocalSQLiteQueryError.sqliteUnavailable
        }

        let process = Process()
        process.executableURL = sqliteURL
        process.arguments = [
            "-readonly",
            "-separator",
            "\t",
            dbURL.path,
            sql,
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalSQLiteQueryError.queryFailed(errorText ?? "Unknown sqlite error")
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: outputData, encoding: .utf8) ?? ""
    }
}
