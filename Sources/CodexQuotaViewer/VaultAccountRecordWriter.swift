import Foundation

struct VaultAccountRecordWriter {
    let fileManager: FileManager
    private let privateDirectoryPermissions = NSNumber(value: Int16(0o700))
    private let privateFilePermissions = NSNumber(value: Int16(0o600))

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func write(
        _ record: VaultAccountRecord,
        writer: FileDataWriting = DirectFileDataWriter()
    ) throws {
        try fileManager.createDirectory(
            at: record.directoryURL,
            withIntermediateDirectories: true
        )
        try hardenDirectory(record.directoryURL)
        try writer.write(JSONEncoder.vaultEncoder.encode(record.metadata), to: record.metadataURL)
        try writer.write(record.runtimeMaterial.authData, to: record.authURL)
        try hardenFile(record.authURL)

        if let configData = record.runtimeMaterial.configData {
            try writer.write(configData, to: record.configURL)
            try hardenFile(record.configURL)
        } else if let protectedWriter = writer as? ProtectedFileMutationContext {
            try protectedWriter.removeItemIfExists(at: record.configURL)
        } else if fileManager.fileExists(atPath: record.configURL.path) {
            try fileManager.removeItem(at: record.configURL)
        }
    }

    private func hardenDirectory(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        try fileManager.setAttributes([.posixPermissions: privateDirectoryPermissions], ofItemAtPath: url.path)
    }

    private func hardenFile(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        try fileManager.setAttributes([.posixPermissions: privateFilePermissions], ofItemAtPath: url.path)
    }
}

private extension JSONEncoder {
    static let vaultEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
