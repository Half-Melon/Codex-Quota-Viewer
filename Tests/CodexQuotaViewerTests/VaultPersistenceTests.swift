import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func vaultAccountRecordWriterRemovesObsoleteConfigFile() throws {
    let harness = try makeHarness()
    let directoryURL = harness.appSupportURL.appendingPathComponent("Accounts/acct-1", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    let recordWithConfig = VaultAccountRecord(
        metadata: VaultAccountMetadata(
            id: "acct-1",
            displayName: "Example",
            authMode: .unknown,
            providerID: nil,
            baseURL: nil,
            model: nil,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            source: .currentRuntime,
            runtimeKey: "runtime-1"
        ),
        runtimeMaterial: ProfileRuntimeMaterial(
            authData: Data(#"{"auth_mode":"unknown"}"#.utf8),
            configData: Data("model_provider = \"custom\"\n".utf8)
        ),
        directoryURL: directoryURL,
        metadataURL: directoryURL.appendingPathComponent("metadata.json"),
        authURL: directoryURL.appendingPathComponent("auth.json"),
        configURL: directoryURL.appendingPathComponent("config.toml")
    )
    let recordWithoutConfig = VaultAccountRecord(
        metadata: recordWithConfig.metadata,
        runtimeMaterial: ProfileRuntimeMaterial(
            authData: Data(#"{"auth_mode":"unknown"}"#.utf8),
            configData: nil
        ),
        directoryURL: directoryURL,
        metadataURL: recordWithConfig.metadataURL,
        authURL: recordWithConfig.authURL,
        configURL: recordWithConfig.configURL
    )

    let writer = VaultAccountRecordWriter(fileManager: .default)
    try writer.write(recordWithConfig)
    #expect(FileManager.default.fileExists(atPath: recordWithConfig.configURL.path))

    try writer.write(recordWithoutConfig)
    #expect(!FileManager.default.fileExists(atPath: recordWithoutConfig.configURL.path))
}
