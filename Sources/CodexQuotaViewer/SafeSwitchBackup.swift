import CryptoKit
import Foundation

struct RestorePointFileRecord: Codable, Equatable {
    let originalPath: String
    let backupRelativePath: String?
    let exists: Bool
    let sha256: String?
    let fileSize: UInt64?
    let modifiedAt: Date?
}

struct RestorePointManifest: Codable, Equatable {
    let id: String
    let createdAt: Date
    let reason: String
    let summary: String
    let codexWasRunning: Bool
    let files: [RestorePointFileRecord]
}

enum BackupManagerError: LocalizedError {
    case noRestorePoint
    case manifestMissing(String)
    case backupCoverageMissing(String)
    case restorePointCorrupted(String)

    var errorDescription: String? {
        switch self {
        case .noRestorePoint:
            return AppLocalization.localized(en: "No restore point is available.", zh: "当前没有可用的还原点。")
        case .manifestMissing(let path):
            return AppLocalization.localized(
                en: "Restore point manifest is missing: \(path)",
                zh: "还原点 manifest 缺失：\(path)"
            )
        case .backupCoverageMissing(let path):
            return AppLocalization.localized(
                en: "Refusing to modify an unprotected file: \(path)",
                zh: "拒绝修改未受保护的文件：\(path)"
            )
        case .restorePointCorrupted(let path):
            return AppLocalization.localized(
                en: "Restore point data is corrupted: \(path)",
                zh: "还原点数据已损坏：\(path)"
            )
        }
    }
}

protocol FileDataWriting {
    func write(_ data: Data, to url: URL) throws
}

struct DirectFileDataWriter: FileDataWriting {
    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

final class ProtectedFileMutationContext: FileDataWriting {
    private let allowedPathKeys: Set<String>

    init(restorePoint: RestorePointManifest) {
        allowedPathKeys = Set(restorePoint.files.map { Self.coverageKey(forPath: $0.originalPath) })
    }

    func write(_ data: Data, to url: URL) throws {
        try assertCovered(url)
        try DirectFileDataWriter().write(data, to: url)
    }

    func removeItemIfExists(at url: URL) throws {
        try assertCovered(url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    private func assertCovered(_ url: URL) throws {
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let displayPath = resolvedURL.path
        let pathKey = Self.coverageKey(for: resolvedURL)
        guard allowedPathKeys.contains(pathKey) else {
            throw BackupManagerError.backupCoverageMissing(displayPath)
        }
    }

    private static func coverageKey(for url: URL) -> String {
        url.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
            .lowercased()
    }

    private static func coverageKey(forPath path: String) -> String {
        coverageKey(for: URL(fileURLWithPath: path))
    }
}

final class BackupManager {
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maxRestorePoints = 20
    private let privateDirectoryPermissions = NSNumber(value: Int16(0o700))
    private let privateFilePermissions = NSNumber(value: Int16(0o600))
    private let protectedRestorePointIDsProvider: () -> Set<String>

    let backupsRootURL: URL

    init(
        backupsRootURL: URL,
        protectedRestorePointIDsProvider: @escaping () -> Set<String> = { [] }
    ) {
        self.backupsRootURL = backupsRootURL
        self.protectedRestorePointIDsProvider = protectedRestorePointIDsProvider

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func createRestorePoint(
        reason: String,
        summary: String,
        files: [URL],
        codexWasRunning: Bool
    ) throws -> RestorePointManifest {
        try fileManager.createDirectory(
            at: backupsRootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: privateDirectoryPermissions]
        )

        let createdAt = Date()
        let id = "\(Self.timestampFormatter.string(from: createdAt))-\(UUID().uuidString.prefix(8))"
        let restorePointURL = backupsRootURL.appendingPathComponent(id, isDirectory: true)
        let filesDirectoryURL = restorePointURL.appendingPathComponent("files", isDirectory: true)

        try fileManager.createDirectory(
            at: filesDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: privateDirectoryPermissions]
        )
        try setPermissions(for: restorePointURL, value: privateDirectoryPermissions)
        try setPermissions(for: filesDirectoryURL, value: privateDirectoryPermissions)

        let protectedFiles = deduplicatedStandardizedFileURLs(files)
        var records: [RestorePointFileRecord] = []

        for (index, fileURL) in protectedFiles.enumerated() {
            let standardizedURL = fileURL.standardizedFileURL
            let path = standardizedURL.path
            guard fileManager.fileExists(atPath: path) else {
                records.append(
                    RestorePointFileRecord(
                        originalPath: path,
                        backupRelativePath: nil,
                        exists: false,
                        sha256: nil,
                        fileSize: nil,
                        modifiedAt: nil
                    )
                )
                continue
            }

            let attributes = try? fileManager.attributesOfItem(atPath: path)
            let data = try Data(contentsOf: standardizedURL)
            let backupName = String(format: "%03d-%@", index, sanitizedFileName(for: standardizedURL))
            let backupRelativePath = "files/\(backupName)"
            let backupURL = restorePointURL.appendingPathComponent(backupRelativePath, isDirectory: false)

            try fileManager.createDirectory(
                at: backupURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: privateDirectoryPermissions]
            )
            try data.write(to: backupURL, options: .atomic)
            try setPermissions(for: backupURL, value: privateFilePermissions)

            records.append(
                RestorePointFileRecord(
                    originalPath: path,
                    backupRelativePath: backupRelativePath,
                    exists: true,
                    sha256: sha256(of: data),
                    fileSize: (attributes?[.size] as? NSNumber)?.uint64Value,
                    modifiedAt: attributes?[.modificationDate] as? Date
                )
            )
        }

        let manifest = RestorePointManifest(
            id: id,
            createdAt: createdAt,
            reason: reason,
            summary: summary,
            codexWasRunning: codexWasRunning,
            files: records
        )
        try encoder.encode(manifest).write(
            to: restorePointURL.appendingPathComponent("manifest.json", isDirectory: false),
            options: .atomic
        )
        try setPermissions(
            for: restorePointURL.appendingPathComponent("manifest.json", isDirectory: false),
            value: privateFilePermissions
        )

        try pruneIfNeeded()
        return manifest
    }

    func latestRestorePoint() throws -> RestorePointManifest? {
        let manifestURL = try latestManifestURL()
        guard let manifestURL else {
            return nil
        }
        return try loadManifest(at: manifestURL)
    }

    func restorePoint(id: String) throws -> RestorePointManifest {
        let manifestURL = try restorePointManifestURL(id: id)
        return try loadManifest(at: manifestURL)
    }

    func restoreLatestRestorePoint() throws -> RestorePointManifest {
        guard let manifestURL = try latestManifestURL() else {
            throw BackupManagerError.noRestorePoint
        }

        let manifest = try loadManifest(at: manifestURL)
        return try restoreRestorePoint(manifest, restorePointURL: manifestURL.deletingLastPathComponent())
    }

    @discardableResult
    func restoreRestorePoint(_ manifest: RestorePointManifest) throws -> RestorePointManifest {
        let restorePointURL = backupsRootURL.appendingPathComponent(manifest.id, isDirectory: true)
        return try restoreRestorePoint(manifest, restorePointURL: restorePointURL)
    }

    @discardableResult
    func restoreRestorePoint(id: String) throws -> RestorePointManifest {
        let manifestURL = try restorePointManifestURL(id: id)
        let manifest = try loadManifest(at: manifestURL)
        return try restoreRestorePoint(manifest, restorePointURL: manifestURL.deletingLastPathComponent())
    }

    @discardableResult
    private func restoreRestorePoint(
        _ manifest: RestorePointManifest,
        restorePointURL: URL
    ) throws -> RestorePointManifest {
        guard fileManager.fileExists(atPath: restorePointURL.path) else {
            throw BackupManagerError.manifestMissing(restorePointURL.path)
        }

        let transactionURL = backupsRootURL.appendingPathComponent(
            ".restore-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagedDirectoryURL = transactionURL.appendingPathComponent("staged", isDirectory: true)
        let rollbackDirectoryURL = transactionURL.appendingPathComponent("rollback", isDirectory: true)

        try fileManager.createDirectory(
            at: stagedDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: privateDirectoryPermissions]
        )
        try fileManager.createDirectory(
            at: rollbackDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: privateDirectoryPermissions]
        )
        defer {
            try? fileManager.removeItem(at: transactionURL)
        }

        let operations = try stagedRestoreOperations(
            for: manifest,
            restorePointURL: restorePointURL,
            stagedDirectoryURL: stagedDirectoryURL,
            rollbackDirectoryURL: rollbackDirectoryURL
        )
        var appliedOperations: [RestoreOperation] = []

        do {
            for operation in operations {
                try applyRestoreOperation(operation)
                appliedOperations.append(operation)
            }
        } catch {
            try rollbackRestoreOperations(appliedOperations.reversed())
            throw error
        }

        return manifest
    }

    private func latestManifestURL() throws -> URL? {
        guard fileManager.fileExists(atPath: backupsRootURL.path) else {
            return nil
        }

        guard let latestDirectoryURL = try restorePointDirectoryURLs()
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
            .first else {
            return nil
        }

        return latestDirectoryURL.appendingPathComponent("manifest.json", isDirectory: false)
    }

    private func loadManifest(at manifestURL: URL) throws -> RestorePointManifest {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw BackupManagerError.manifestMissing(manifestURL.path)
        }
        return try decoder.decode(RestorePointManifest.self, from: Data(contentsOf: manifestURL))
    }

    private func restorePointManifestURL(id: String) throws -> URL {
        let sanitizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedID.isEmpty,
              sanitizedID == URL(fileURLWithPath: sanitizedID).lastPathComponent else {
            throw BackupManagerError.manifestMissing(id)
        }

        return backupsRootURL
            .appendingPathComponent(sanitizedID, isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
    }

    private func pruneIfNeeded() throws {
        let restorePointURLs = try sortedRestorePointDirectoryURLs()
        guard restorePointURLs.count > maxRestorePoints else {
            return
        }

        let protectedIDs = protectedRestorePointIDsProvider()
        for restorePointURL in restorePointURLs.dropFirst(maxRestorePoints)
            where !protectedIDs.contains(restorePointURL.lastPathComponent) {
            try? fileManager.removeItem(at: restorePointURL)
        }
    }

    private func sortedRestorePointManifestURLs() throws -> [URL] {
        try sortedRestorePointDirectoryURLs().map {
            $0.appendingPathComponent("manifest.json", isDirectory: false)
        }
    }

    private func sortedRestorePointDirectoryURLs() throws -> [URL] {
        try restorePointDirectoryURLs()
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func restorePointDirectoryURLs() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: backupsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
    }

    private func sanitizedFileName(for url: URL) -> String {
        let basename = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
        let invalidSet = CharacterSet(charactersIn: "/:")
        return basename.components(separatedBy: invalidSet).joined(separator: "_")
    }

    private func sha256(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return hexString(for: digest)
    }

    private func setPermissions(for url: URL, value: NSNumber) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.setAttributes([.posixPermissions: value], ofItemAtPath: url.path)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    private func stagedRestoreOperations(
        for manifest: RestorePointManifest,
        restorePointURL: URL,
        stagedDirectoryURL: URL,
        rollbackDirectoryURL: URL
    ) throws -> [RestoreOperation] {
        try manifest.files.enumerated().map { index, file in
            let destinationURL = URL(fileURLWithPath: file.originalPath, isDirectory: false)
            let fileLabel = String(format: "%03d-%@", index, sanitizedFileName(for: destinationURL))
            let rollbackURL = rollbackDirectoryURL.appendingPathComponent(fileLabel, isDirectory: false)
            let existedBefore = fileManager.fileExists(atPath: destinationURL.path)

            if existedBefore {
                try fileManager.createDirectory(
                    at: rollbackURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: privateDirectoryPermissions]
                )
                try fileManager.copyItem(at: destinationURL, to: rollbackURL)
                try setPermissions(for: rollbackURL, value: privateFilePermissions)
            }

            if file.exists {
                guard let backupRelativePath = file.backupRelativePath else {
                    throw BackupManagerError.manifestMissing(restorePointURL.path)
                }

                let backupURL = restorePointURL.appendingPathComponent(backupRelativePath, isDirectory: false)
                guard fileManager.fileExists(atPath: backupURL.path) else {
                    throw BackupManagerError.manifestMissing(backupURL.path)
                }

                let backupData = try Data(contentsOf: backupURL)
                if let expectedSHA256 = file.sha256,
                   sha256(of: backupData) != expectedSHA256 {
                    throw BackupManagerError.restorePointCorrupted(backupURL.path)
                }
                if let fileSize = file.fileSize,
                   UInt64(backupData.count) != fileSize {
                    throw BackupManagerError.restorePointCorrupted(backupURL.path)
                }

                let stagedURL = stagedDirectoryURL.appendingPathComponent(fileLabel, isDirectory: false)
                try fileManager.createDirectory(
                    at: stagedURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: privateDirectoryPermissions]
                )
                try backupData.write(to: stagedURL, options: .atomic)
                try setPermissions(for: stagedURL, value: privateFilePermissions)

                return RestoreOperation(
                    destinationURL: destinationURL,
                    kind: .write(stagedURL),
                    existedBefore: existedBefore,
                    rollbackURL: existedBefore ? rollbackURL : nil
                )
            }

            return RestoreOperation(
                destinationURL: destinationURL,
                kind: .remove,
                existedBefore: existedBefore,
                rollbackURL: existedBefore ? rollbackURL : nil
            )
        }
    }

    private func applyRestoreOperation(_ operation: RestoreOperation) throws {
        switch operation.kind {
        case .write(let stagedURL):
            try fileManager.createDirectory(
                at: operation.destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if operation.existedBefore && fileManager.fileExists(atPath: operation.destinationURL.path) {
                _ = try fileManager.replaceItemAt(
                    operation.destinationURL,
                    withItemAt: stagedURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                if fileManager.fileExists(atPath: operation.destinationURL.path) {
                    try fileManager.removeItem(at: operation.destinationURL)
                }
                try fileManager.moveItem(at: stagedURL, to: operation.destinationURL)
            }
        case .remove:
            guard fileManager.fileExists(atPath: operation.destinationURL.path) else {
                return
            }
            try fileManager.removeItem(at: operation.destinationURL)
        }
    }

    private func rollbackRestoreOperations<S: Sequence>(_ operations: S) throws where S.Element == RestoreOperation {
        for operation in operations {
            if let rollbackURL = operation.rollbackURL,
               fileManager.fileExists(atPath: rollbackURL.path) {
                try fileManager.createDirectory(
                    at: operation.destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: operation.destinationURL.path) {
                    try fileManager.removeItem(at: operation.destinationURL)
                }
                try fileManager.copyItem(at: rollbackURL, to: operation.destinationURL)
                continue
            }

            if !operation.existedBefore,
               fileManager.fileExists(atPath: operation.destinationURL.path) {
                try fileManager.removeItem(at: operation.destinationURL)
            }
        }
    }
}

private struct RestoreOperation {
    enum Kind {
        case write(URL)
        case remove
    }

    let destinationURL: URL
    let kind: Kind
    let existedBefore: Bool
    let rollbackURL: URL?
}
