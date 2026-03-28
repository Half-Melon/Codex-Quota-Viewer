import Foundation

struct CCSwitchCodexProvider: Equatable {
    let name: String
    let runtimeMaterial: ProfileRuntimeMaterial
}

enum CCSwitchCodexStoreError: LocalizedError {
    case sqliteUnavailable
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .sqliteUnavailable:
            return "System sqlite3 is unavailable, so CC Switch data cannot be read."
        case .queryFailed(let message):
            return "Failed to read CC Switch data: \(message)"
        }
    }
}

final class CCSwitchCodexStore {
    typealias QueryRunner = (URL, String) throws -> String

    private let dbURL: URL
    private let queryRunner: QueryRunner
    private let fileManager = FileManager.default

    init(
        dbURL: URL? = nil,
        queryRunner: QueryRunner? = nil
    ) {
        let home = fileManager.homeDirectoryForCurrentUser
        self.dbURL = dbURL ?? home
            .appendingPathComponent(".cc-switch", isDirectory: true)
            .appendingPathComponent("cc-switch.db", isDirectory: false)
        self.queryRunner = queryRunner ?? Self.defaultQueryRunner
    }

    func loadLoggedInOrdinaryProviders() throws -> [CCSwitchCodexProvider] {
        guard fileManager.fileExists(atPath: dbURL.path) else {
            return []
        }

        let sql = """
        SELECT hex(id), hex(name), hex(settings_config)
        FROM providers
        WHERE app_type = 'codex'
        ORDER BY COALESCE(sort_index, 999999), created_at ASC, id ASC;
        """

        let output = try queryRunner(dbURL, sql)
        return Self.parseProviders(from: output)
    }

    static func parseProviders(from output: String) -> [CCSwitchCodexProvider] {
        var providers: [CCSwitchCodexProvider] = []
        var seenRuntimeKeys = Set<String>()

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let columns = line.components(separatedBy: "\t")
            guard columns.count >= 3,
                  let providerID = decodeHexString(columns[0]),
                  let name = decodeHexString(columns[1]),
                  let settingsJSONString = decodeHexString(columns[2]),
                  let settingsData = settingsJSONString.data(using: .utf8),
                  let settingsObject = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
                  let authObject = settingsObject["auth"] as? [String: Any],
                  isLikelyOrdinaryLogin(authObject: authObject),
                  JSONSerialization.isValidJSONObject(authObject),
                  let authData = try? JSONSerialization.data(withJSONObject: authObject, options: [.sortedKeys]) else {
                continue
            }

            let configString = settingsObject["config"] as? String
            let configData = configString?.isEmpty == false ? Data(configString!.utf8) : nil

            if apiKeyProfileDetails(authData: authData, configData: configData) != nil {
                continue
            }

            let runtimeMaterial = ProfileRuntimeMaterial(authData: authData, configData: configData)
            let runtimeKey = runtimeIdentityKey(for: runtimeMaterial)
            guard seenRuntimeKeys.insert(runtimeKey).inserted else {
                continue
            }

            providers.append(
                CCSwitchCodexProvider(
                    name: name.isEmpty ? providerID : name,
                    runtimeMaterial: runtimeMaterial
                )
            )
        }

        return providers
    }

    private static func isLikelyOrdinaryLogin(authObject: [String: Any]) -> Bool {
        guard !authObject.isEmpty else {
            return false
        }

        if let apiKey = authObject["OPENAI_API_KEY"] as? String,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }

        if let authMode = authObject["auth_mode"] as? String,
           authMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "apikey" {
            return false
        }

        return true
    }

    private static func decodeHexString(_ hex: String) -> String? {
        guard hex.count.isMultiple(of: 2) else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }

        return String(data: data, encoding: .utf8)
    }

    private static func defaultQueryRunner(dbURL: URL, sql: String) throws -> String {
        let sqliteURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        guard FileManager.default.isExecutableFile(atPath: sqliteURL.path) else {
            throw CCSwitchCodexStoreError.sqliteUnavailable
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

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CCSwitchCodexStoreError.queryFailed(errorText?.isEmpty == false ? errorText! : "Unknown error")
        }

        return String(data: outputData, encoding: .utf8) ?? ""
    }
}
