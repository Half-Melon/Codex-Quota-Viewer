import Foundation

struct VaultAccountRecordWriter {
    let fileManager: FileManager

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
        try writer.write(JSONEncoder.vaultEncoder.encode(record.metadata), to: record.metadataURL)
        try writer.write(record.runtimeMaterial.authData, to: record.authURL)

        if let configData = record.runtimeMaterial.configData {
            try writer.write(configData, to: record.configURL)
        } else if let protectedWriter = writer as? ProtectedFileMutationContext {
            try protectedWriter.removeItemIfExists(at: record.configURL)
        } else if fileManager.fileExists(atPath: record.configURL.path) {
            try fileManager.removeItem(at: record.configURL)
        }
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
