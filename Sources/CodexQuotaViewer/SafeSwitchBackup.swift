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
    private let allowedPaths: Set<String>

    init(restorePoint: RestorePointManifest) {
        allowedPaths = Set(restorePoint.files.map(\.originalPath))
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
        let path = url.standardizedFileURL.path
        guard allowedPaths.contains(path) else {
            throw BackupManagerError.backupCoverageMissing(path)
        }
    }
}

final class BackupManager {
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maxRestorePoints = 20
    private let privateDirectoryPermissions = NSNumber(value: Int16(0o700))
    private let privateFilePermissions = NSNumber(value: Int16(0o600))

    let backupsRootURL: URL

    init(backupsRootURL: URL) {
        self.backupsRootURL = backupsRootURL

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

        let protectedFiles = deduplicatedPaths(files)
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

    func restoreLatestRestorePoint() throws -> RestorePointManifest {
        guard let manifestURL = try latestManifestURL() else {
            throw BackupManagerError.noRestorePoint
        }

        let manifest = try loadManifest(at: manifestURL)
        let restorePointURL = manifestURL.deletingLastPathComponent()

        for file in manifest.files {
            let destinationURL = URL(fileURLWithPath: file.originalPath, isDirectory: false)

            if file.exists {
                guard let backupRelativePath = file.backupRelativePath else {
                    throw BackupManagerError.manifestMissing(manifestURL.path)
                }

                let backupURL = restorePointURL.appendingPathComponent(backupRelativePath, isDirectory: false)
                guard fileManager.fileExists(atPath: backupURL.path) else {
                    throw BackupManagerError.manifestMissing(backupURL.path)
                }

                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: backupURL, to: destinationURL)
            } else if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
        }

        return manifest
    }

    private func latestManifestURL() throws -> URL? {
        guard fileManager.fileExists(atPath: backupsRootURL.path) else {
            return nil
        }

        return try sortedRestorePointManifestURLs().first
    }

    private func loadManifest(at manifestURL: URL) throws -> RestorePointManifest {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw BackupManagerError.manifestMissing(manifestURL.path)
        }
        return try decoder.decode(RestorePointManifest.self, from: Data(contentsOf: manifestURL))
    }

    private func pruneIfNeeded() throws {
        let manifestURLs = try sortedRestorePointManifestURLs()
        guard manifestURLs.count > maxRestorePoints else {
            return
        }

        for manifestURL in manifestURLs.dropFirst(maxRestorePoints) {
            try? fileManager.removeItem(at: manifestURL.deletingLastPathComponent())
        }
    }

    private func sortedRestorePointManifestURLs() throws -> [URL] {
        let entries = try fileManager.contentsOfDirectory(
            at: backupsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try entries
            .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            .map { directoryURL -> (URL, Date)? in
                let manifestURL = directoryURL.appendingPathComponent("manifest.json", isDirectory: false)
                guard let manifest = try? loadManifest(at: manifestURL) else {
                    return nil
                }
                return (manifestURL, manifest.createdAt)
            }
            .compactMap { $0 }
            .sorted {
                if $0.1 == $1.1 {
                    return $0.0.deletingLastPathComponent().lastPathComponent > $1.0.deletingLastPathComponent().lastPathComponent
                }
                return $0.1 > $1.1
            }
            .map(\.0)
    }

    private func deduplicatedPaths(_ files: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        for url in files {
            let standardizedURL = url.standardizedFileURL
            guard seen.insert(standardizedURL.path).inserted else {
                continue
            }
            result.append(standardizedURL)
        }

        return result.sorted { $0.path < $1.path }
    }

    private func sanitizedFileName(for url: URL) -> String {
        let basename = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
        let invalidSet = CharacterSet(charactersIn: "/:")
        return basename.components(separatedBy: invalidSet).joined(separator: "_")
    }

    private func sha256(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
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
}
