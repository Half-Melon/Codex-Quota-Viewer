import Foundation

enum CodexRPCError: LocalizedError, Equatable {
    case missingExecutable
    case timeout
    case notLoggedIn
    case invalidResponse(String)
    case rpc(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return AppLocalization.localized(en: "Could not find the codex executable.", zh: "找不到 codex 可执行文件。")
        case .timeout:
            return AppLocalization.localized(en: "Timed out while reading quota.", zh: "读取额度超时。")
        case .notLoggedIn:
            return AppLocalization.localized(
                en: "The current account is not signed in, or auth.json is invalid.",
                zh: "当前账号未登录，或 auth.json 无效。"
            )
        case .invalidResponse(let message):
            return AppLocalization.localized(
                en: "Codex returned an invalid response: \(message)",
                zh: "Codex 返回了无效响应：\(message)"
            )
        case .rpc(let message):
            return message
        }
    }
}

private struct AccountReadResponse: Decodable {
    let account: CodexAccount?
}

private struct RateLimitsReadResponse: Decodable {
    let rateLimits: RateLimitSnapshot
}

func fallbackRateLimitsSnapshot(
    requestID: String?,
    errorCode: Int,
    message: String
) -> RateLimitSnapshot? {
    guard requestID == "3", errorCode == -32600 else {
        return nil
    }

    let normalized = message
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

    guard normalized.contains("chatgpt authentication required to read rate limits") else {
        return nil
    }

    return RateLimitSnapshot(
        limitId: nil,
        limitName: nil,
        primary: nil,
        secondary: nil,
        planType: nil
    )
}

private func quotaUnavailableRateLimitsSnapshot() -> RateLimitSnapshot {
    RateLimitSnapshot(
        limitId: nil,
        limitName: nil,
        primary: nil,
        secondary: nil,
        planType: nil
    )
}

struct CodexRPCClient: Sendable {
    func fetchSnapshot(codexHomeURL: URL) async throws -> CodexSnapshot {
        let homeURL = codexHomeURL.deletingLastPathComponent()
        return try await fetchSnapshot(
            homeOverride: homeURL,
            codexHomeOverride: codexHomeURL
        )
    }

    func fetchSnapshot(authData: Data, configData: Data? = nil) async throws -> CodexSnapshot {
        let fileManager = FileManager.default
        let tempHome = fileManager.temporaryDirectory
            .appendingPathComponent("\(AppIdentity.temporaryDirectoryPrefix)-\(UUID().uuidString)", isDirectory: true)
        let tempCodexHome = tempHome.appendingPathComponent(".codex", isDirectory: true)

        try fileManager.createDirectory(
            at: tempCodexHome,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let authURL = tempCodexHome.appendingPathComponent("auth.json", isDirectory: false)
        try authData.write(to: authURL, options: .atomic)

        if let configData {
            let configURL = tempCodexHome.appendingPathComponent("config.toml", isDirectory: false)
            try configData.write(to: configURL, options: .atomic)
        }

        defer {
            try? fileManager.removeItem(at: tempHome)
        }

        return try await fetchSnapshot(
            homeOverride: tempHome,
            codexHomeOverride: tempCodexHome
        )
    }

    private func fetchSnapshot(
        homeOverride: URL?,
        codexHomeOverride: URL?
    ) async throws -> CodexSnapshot {
        let launch = try launchConfiguration()

        let process = Process()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments

        var environment = ProcessInfo.processInfo.environment
        let effectiveHome = homeOverride ?? FileManager.default.homeDirectoryForCurrentUser
        environment["HOME"] = effectiveHome.path
        if let codexHomeOverride {
            environment["CODEX_HOME"] = codexHomeOverride.path
        } else {
            environment.removeValue(forKey: "CODEX_HOME")
        }
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        defer {
            if process.isRunning {
                process.terminate()
            }
            try? stdin.fileHandleForWriting.close()
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }

        return try await withThrowingTaskGroup(of: CodexSnapshot.self) { group in
            group.addTask {
                try await self.readSnapshot(
                    from: stdout.fileHandleForReading,
                    stderrHandle: stderr.fileHandleForReading,
                    process: process,
                    to: stdin.fileHandleForWriting
                )
            }

            group.addTask {
                try await Task.sleep(for: .seconds(10))
                if process.isRunning {
                    process.terminate()
                }
                throw CodexRPCError.timeout
            }

            guard let result = try await group.next() else {
                throw CodexRPCError.invalidResponse("No output was received.")
            }

            group.cancelAll()
            return result
        }
    }

    private func readSnapshot(
        from outputHandle: FileHandle,
        stderrHandle: FileHandle,
        process: Process,
        to inputHandle: FileHandle
    ) async throws -> CodexSnapshot {
        let decoder = JSONDecoder()

        try sendRequest(
            id: "1",
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": AppIdentity.rpcClientName,
                    "version": AppIdentity.rpcClientVersion,
                ],
                "protocolVersion": 2,
            ],
            to: inputHandle
        )

        var account: CodexAccount?
        var rateLimits: RateLimitSnapshot?

        for try await line in outputHandle.bytes.lines {
            guard !line.isEmpty else { continue }

            let message = try decodeMessage(from: line)
            let id = message["id"] as? String

            if let error = message["error"] as? [String: Any] {
                let code = error["code"] as? Int ?? 0
                let detail = error["message"] as? String ?? "Unknown error"
                if let fallback = fallbackRateLimitsSnapshot(
                    requestID: id,
                    errorCode: code,
                    message: detail
                ) {
                    rateLimits = fallback
                    if let account {
                        return CodexSnapshot(account: account, rateLimits: fallback, fetchedAt: Date())
                    }
                    continue
                }
                if code == -32600 {
                    throw CodexRPCError.notLoggedIn
                }
                throw CodexRPCError.rpc(detail)
            }

            guard let id else { continue }
            let resultObject = message["result"]

            switch id {
            case "1":
                try sendRequest(id: "2", method: "account/read", params: [:], to: inputHandle)

            case "2":
                guard let resultObject else {
                    throw CodexRPCError.invalidResponse("account/read is missing result.")
                }
                let data = try JSONSerialization.data(withJSONObject: resultObject)
                let result = try decoder.decode(AccountReadResponse.self, from: data)
                guard let accountValue = result.account else {
                    throw CodexRPCError.notLoggedIn
                }
                account = accountValue

                if accountValue.type == "apiKey" {
                    rateLimits = quotaUnavailableRateLimitsSnapshot()
                } else {
                    try sendRequest(id: "3", method: "account/rateLimits/read", params: [:], to: inputHandle)
                }

            case "3":
                guard let resultObject else {
                    throw CodexRPCError.invalidResponse("account/rateLimits/read is missing result.")
                }
                let data = try JSONSerialization.data(withJSONObject: resultObject)
                let result = try decoder.decode(RateLimitsReadResponse.self, from: data)
                rateLimits = result.rateLimits

            default:
                break
            }

            if let account, let rateLimits {
                return CodexSnapshot(account: account, rateLimits: rateLimits, fetchedAt: Date())
            }
        }

        process.waitUntilExit()

        let stderrText = try readPipeText(from: stderrHandle)
        if let failureError = codexProcessFailureError(
            terminationStatus: process.terminationStatus,
            stderrText: stderrText
        ) {
            throw failureError
        }

        throw CodexRPCError.invalidResponse("app-server exited early.")
    }

    private func sendRequest(
        id: String,
        method: String,
        params: [String: Any],
        to handle: FileHandle
    ) throws {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]

        let data = try JSONSerialization.data(withJSONObject: body)
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }

    private func decodeMessage(from line: String) throws -> [String: Any] {
        let data = Data(line.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexRPCError.invalidResponse(line)
        }
        return object
    }

    private func readPipeText(from handle: FileHandle) throws -> String {
        let data = handle.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func launchConfiguration() throws -> (executableURL: URL, arguments: [String]) {
        let fileManager = FileManager.default
        let bundled = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
        if fileManager.isExecutableFile(atPath: bundled.path) {
            return (bundled, ["-s", "read-only", "-a", "untrusted", "app-server"])
        }

        let env = URL(fileURLWithPath: "/usr/bin/env")
        if fileManager.isExecutableFile(atPath: env.path) {
            return (env, ["codex", "-s", "read-only", "-a", "untrusted", "app-server"])
        }

        throw CodexRPCError.missingExecutable
    }
}

func codexProcessFailureError(
    terminationStatus: Int32,
    stderrText: String
) -> CodexRPCError? {
    if !stderrText.isEmpty {
        let lowered = stderrText.lowercased()
        if lowered.contains("codex"), lowered.contains("no such file") {
            return .missingExecutable
        }

        if terminationStatus != 0 {
            return .rpc("app-server failed to start (exit \(terminationStatus)): \(stderrText)")
        }
        return .rpc(stderrText)
    }

    guard terminationStatus != 0 else {
        return nil
    }

    return .rpc("app-server exited early with status \(terminationStatus).")
}
