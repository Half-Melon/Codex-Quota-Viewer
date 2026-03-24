import Foundation

enum CodexRPCError: LocalizedError {
    case missingExecutable
    case timeout
    case notLoggedIn
    case invalidResponse(String)
    case rpc(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "找不到 codex 可执行文件。"
        case .timeout:
            return "读取额度超时。"
        case .notLoggedIn:
            return "当前账号未登录或 auth.json 无效。"
        case .invalidResponse(let message):
            return "Codex 返回了无效结果：\(message)"
        case .rpc(let message):
            return message
        }
    }
}

private struct AccountReadResponse: Decodable {
    let account: CodexAccount?
    let requiresOpenaiAuth: Bool
}

private struct RateLimitsReadResponse: Decodable {
    let rateLimits: RateLimitSnapshot
}

struct CodexRPCClient: Sendable, CodexRPCClientProtocol {
    func fetchCurrentSnapshot() async throws -> CodexSnapshot {
        try await fetchSnapshot(homeOverride: nil)
    }

    func fetchSnapshot(authData: Data) async throws -> CodexSnapshot {
        let fileManager = FileManager.default
        let tempHome = fileManager.temporaryDirectory
            .appendingPathComponent("CodexAccountSwitcher-\(UUID().uuidString)", isDirectory: true)

        try fileManager.createDirectory(
            at: tempHome.appendingPathComponent(".codex", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let authURL = tempHome
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
        try authData.write(to: authURL, options: .atomic)

        defer {
            try? fileManager.removeItem(at: tempHome)
        }

        return try await fetchSnapshot(homeOverride: tempHome)
    }

    private func fetchSnapshot(homeOverride: URL?) async throws -> CodexSnapshot {
        let launch = try launchConfiguration()

        let process = Process()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments

        var environment = ProcessInfo.processInfo.environment
        if let homeOverride {
            environment["HOME"] = homeOverride.path
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
                throw CodexRPCError.invalidResponse("没有拿到任何输出。")
            }

            group.cancelAll()
            return result
        }
    }

    private func readSnapshot(
        from outputHandle: FileHandle,
        to inputHandle: FileHandle
    ) async throws -> CodexSnapshot {
        let decoder = JSONDecoder()

        try sendRequest(
            id: "1",
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "CodexAccountSwitcher",
                    "version": "0.1.0",
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

            if let error = message["error"] as? [String: Any] {
                let code = error["code"] as? Int ?? 0
                let detail = error["message"] as? String ?? "未知错误"
                if code == -32600 {
                    throw CodexRPCError.notLoggedIn
                }
                throw CodexRPCError.rpc(detail)
            }

            guard let id = message["id"] as? String else { continue }
            let resultObject = message["result"]

            switch id {
            case "1":
                try sendRequest(id: "2", method: "account/read", params: [:], to: inputHandle)
                try sendRequest(id: "3", method: "account/rateLimits/read", params: [:], to: inputHandle)

            case "2":
                guard let resultObject else {
                    throw CodexRPCError.invalidResponse("account/read 缺少 result。")
                }
                let data = try JSONSerialization.data(withJSONObject: resultObject)
                let result = try decoder.decode(AccountReadResponse.self, from: data)
                guard let accountValue = result.account else {
                    throw CodexRPCError.notLoggedIn
                }
                account = accountValue

            case "3":
                guard let resultObject else {
                    throw CodexRPCError.invalidResponse("account/rateLimits/read 缺少 result。")
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

        throw CodexRPCError.invalidResponse("app-server 提前结束。")
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
