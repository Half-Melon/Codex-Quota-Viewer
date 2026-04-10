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

protocol CodexRPCChanneling: Sendable {
    func fetchSnapshot(timeout: TimeInterval) async throws -> CodexSnapshot
    func invalidate() async
}

protocol CodexRPCChannelInvalidating: Sendable {
    func invalidateAllReusableChannels() async
    func invalidateReusableChannel(for runtimeMaterial: ProfileRuntimeMaterial) async
}

private struct AccountReadResponse: Decodable {
    let account: CodexAccount?
}

private struct RateLimitsReadResponse: Decodable {
    let rateLimits: RateLimitSnapshot
}

private struct TemporaryCodexRuntime {
    let tempHomeURL: URL
    let tempCodexHomeURL: URL
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

actor CodexRPCChannelPool {
    typealias ChannelFactory = @Sendable (ProfileRuntimeMaterial) async throws -> any CodexRPCChanneling

    private struct Entry {
        let channel: any CodexRPCChanneling
        var expiresAt: Date
    }

    private let ttl: TimeInterval
    private let channelFactory: ChannelFactory
    private let nowProvider: @Sendable () -> Date
    private var entries: [String: Entry] = [:]

    init(
        ttl: TimeInterval = 180,
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        channelFactory: @escaping ChannelFactory
    ) {
        self.ttl = ttl
        self.nowProvider = nowProvider
        self.channelFactory = channelFactory
    }

    func fetchSnapshot(
        runtimeMaterial: ProfileRuntimeMaterial,
        timeout: TimeInterval
    ) async throws -> CodexSnapshot {
        await cleanupExpiredChannels()

        let canonicalRuntime = canonicalRuntimeMaterialForStorage(runtimeMaterial)
        let key = runtimeIdentityKey(for: canonicalRuntime)
        let channel = try await reusableChannel(forKey: key, runtimeMaterial: canonicalRuntime)

        do {
            let snapshot = try await channel.fetchSnapshot(timeout: timeout)
            entries[key]?.expiresAt = nowProvider().addingTimeInterval(ttl)
            return snapshot
        } catch {
            await invalidateChannel(forKey: key)
            throw error
        }
    }

    func invalidateAll() async {
        let channels = entries.values.map(\.channel)
        entries.removeAll()
        for channel in channels {
            await channel.invalidate()
        }
    }

    func invalidate(runtimeMaterial: ProfileRuntimeMaterial) async {
        let canonicalRuntime = canonicalRuntimeMaterialForStorage(runtimeMaterial)
        let key = runtimeIdentityKey(for: canonicalRuntime)
        await invalidateChannel(forKey: key)
    }

    private func reusableChannel(
        forKey key: String,
        runtimeMaterial: ProfileRuntimeMaterial
    ) async throws -> any CodexRPCChanneling {
        if let existing = entries[key] {
            return existing.channel
        }

        let channel = try await channelFactory(runtimeMaterial)
        entries[key] = Entry(
            channel: channel,
            expiresAt: nowProvider().addingTimeInterval(ttl)
        )
        return channel
    }

    private func cleanupExpiredChannels() async {
        let now = nowProvider()
        let expiredKeys = entries.compactMap { key, entry in
            entry.expiresAt <= now ? key : nil
        }

        for key in expiredKeys {
            await invalidateChannel(forKey: key)
        }
    }

    private func invalidateChannel(forKey key: String) async {
        guard let entry = entries.removeValue(forKey: key) else {
            return
        }
        await entry.channel.invalidate()
    }
}

enum CodexRPCChannelInvalidationDisposition: Equatable {
    case none
    case deferCleanup
    case cleanupNow
}

struct CodexRPCChannelInvalidationState {
    private(set) var activeFetchCount = 0
    private(set) var isInvalidated = false

    mutating func beginFetch() -> Bool {
        guard !isInvalidated else {
            return false
        }

        activeFetchCount += 1
        return true
    }

    mutating func endFetch() -> Bool {
        if activeFetchCount > 0 {
            activeFetchCount -= 1
        }

        return isInvalidated && activeFetchCount == 0
    }

    mutating func beginInvalidation() -> CodexRPCChannelInvalidationDisposition {
        guard !isInvalidated else {
            return .none
        }

        isInvalidated = true
        return activeFetchCount > 0 ? .deferCleanup : .cleanupNow
    }
}

actor CodexRPCChannel: CodexRPCChanneling {
    private let process: Process
    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    private let stderrHandle: FileHandle
    private let temporaryHomeURL: URL
    private let decoder = JSONDecoder()
    private var outputIterator: FileHandle.AsyncBytes.Iterator
    private var bufferedOutput = Data()
    private var nextRequestNumber = 0
    private var isInitialized = false
    private var invalidationState = CodexRPCChannelInvalidationState()
    private var didCloseInputHandle = false
    private var didFinalizeCleanup = false

    static func make(
        runtimeMaterial: ProfileRuntimeMaterial,
        fileManager: FileManager = .default
    ) throws -> CodexRPCChannel {
        let launch = try defaultLaunchConfiguration()
        let runtime = try prepareTemporaryCodexRuntime(
            authData: runtimeMaterial.authData,
            configData: runtimeMaterial.configData,
            fileManager: fileManager
        )

        let process = Process()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = runtime.tempHomeURL.path
        environment["CODEX_HOME"] = runtime.tempCodexHomeURL.path
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            try? fileManager.removeItem(at: runtime.tempHomeURL)
            throw error
        }

        return CodexRPCChannel(
            process: process,
            inputHandle: stdin.fileHandleForWriting,
            outputHandle: stdout.fileHandleForReading,
            stderrHandle: stderr.fileHandleForReading,
            temporaryHomeURL: runtime.tempHomeURL
        )
    }

    private init(
        process: Process,
        inputHandle: FileHandle,
        outputHandle: FileHandle,
        stderrHandle: FileHandle,
        temporaryHomeURL: URL
    ) {
        self.process = process
        self.inputHandle = inputHandle
        self.outputHandle = outputHandle
        self.stderrHandle = stderrHandle
        self.temporaryHomeURL = temporaryHomeURL
        outputIterator = outputHandle.bytes.makeAsyncIterator()
    }

    func fetchSnapshot(timeout: TimeInterval) async throws -> CodexSnapshot {
        guard invalidationState.beginFetch() else {
            throw CodexRPCError.invalidResponse("app-server exited early.")
        }
        defer {
            if invalidationState.endFetch() {
                finalizeCleanup()
            }
        }

        return try await withThrowingTaskGroup(of: CodexSnapshot.self) { group in
            group.addTask {
                try await self.fetchSnapshotUnsafe()
            }

            group.addTask {
                try await sleepForTimeout(timeout)
                await self.invalidate()
                throw CodexRPCError.timeout
            }

            guard let result = try await group.next() else {
                throw CodexRPCError.invalidResponse("No output was received.")
            }

            group.cancelAll()
            return result
        }
    }

    func invalidate() async {
        switch invalidationState.beginInvalidation() {
        case .none:
            return
        case .deferCleanup:
            terminateProcessIfRunning()
        case .cleanupNow:
            terminateProcessIfRunning()
            finalizeCleanup()
        }
    }

    private func fetchSnapshotUnsafe() async throws -> CodexSnapshot {
        try await ensureInitialized()

        let accountRequestID = makeRequestID()
        try sendRequest(
            id: accountRequestID,
            method: "account/read",
            params: [:],
            to: inputHandle
        )
        let accountMessage = try await readMessage(for: accountRequestID)
        let account = try parseAccount(from: accountMessage)

        if account.type == "apiKey" {
            return CodexSnapshot(
                account: account,
                rateLimits: quotaUnavailableRateLimitsSnapshot(),
                fetchedAt: Date()
            )
        }

        let rateLimitsRequestID = makeRequestID()
        try sendRequest(
            id: rateLimitsRequestID,
            method: "account/rateLimits/read",
            params: [:],
            to: inputHandle
        )
        let rateLimitsMessage = try await readMessage(for: rateLimitsRequestID)
        let rateLimits = try parseRateLimits(
            from: rateLimitsMessage,
            requestID: rateLimitsRequestID
        )

        return CodexSnapshot(account: account, rateLimits: rateLimits, fetchedAt: Date())
    }

    private func ensureInitialized() async throws {
        guard !isInitialized else {
            return
        }

        let initializeRequestID = makeRequestID()
        try sendRequest(
            id: initializeRequestID,
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
        let initializeMessage = try await readMessage(for: initializeRequestID)
        if let rpcError = rpcError(from: initializeMessage) {
            throw rpcError
        }
        isInitialized = true
    }

    private func readMessage(for requestID: String) async throws -> [String: Any] {
        while let line = try await nextOutputLine() {
            if Task.isCancelled {
                throw CancellationError()
            }

            guard !line.isEmpty else {
                continue
            }

            let message = try decodeMessage(from: line)
            guard let id = message["id"] as? String else {
                continue
            }

            if id == requestID {
                return message
            }
        }

        throw try streamEndedError()
    }

    private func nextOutputLine() async throws -> String? {
        while true {
            if let newlineIndex = bufferedOutput.firstIndex(of: 0x0A) {
                var lineData = bufferedOutput.prefix(upTo: newlineIndex)
                bufferedOutput.removeSubrange(...newlineIndex)
                if lineData.last == 0x0D {
                    lineData.removeLast()
                }
                return String(data: lineData, encoding: .utf8)
            }

            var iterator = outputIterator
            guard let nextByte = try await iterator.next() else {
                outputIterator = iterator
                guard !bufferedOutput.isEmpty else {
                    return nil
                }

                let lineData = bufferedOutput
                bufferedOutput.removeAll(keepingCapacity: true)
                return String(data: lineData, encoding: .utf8)
            }

            outputIterator = iterator
            bufferedOutput.append(nextByte)
        }
    }

    private func parseAccount(from message: [String: Any]) throws -> CodexAccount {
        if let rpcError = rpcError(from: message) {
            throw rpcError
        }

        guard let resultObject = message["result"] else {
            throw CodexRPCError.invalidResponse("account/read is missing result.")
        }

        let data = try JSONSerialization.data(withJSONObject: resultObject)
        let result = try decoder.decode(AccountReadResponse.self, from: data)
        guard let account = result.account else {
            throw CodexRPCError.notLoggedIn
        }
        return account
    }

    private func parseRateLimits(
        from message: [String: Any],
        requestID: String
    ) throws -> RateLimitSnapshot {
        if let errorInfo = rpcErrorInfo(from: message) {
            if let fallback = fallbackRateLimitsSnapshot(
                requestID: requestID,
                errorCode: errorInfo.code,
                message: errorInfo.message
            ) {
                return fallback
            }
            throw mapRPCError(code: errorInfo.code, detail: errorInfo.message)
        }

        guard let resultObject = message["result"] else {
            throw CodexRPCError.invalidResponse("account/rateLimits/read is missing result.")
        }

        let data = try JSONSerialization.data(withJSONObject: resultObject)
        let result = try decoder.decode(RateLimitsReadResponse.self, from: data)
        return result.rateLimits
    }

    private func streamEndedError() throws -> CodexRPCError {
        let stderrText = try readPipeText(from: stderrHandle)
        if let failureError = codexProcessFailureError(
            terminationStatus: process.terminationStatus,
            stderrText: stderrText
        ) {
            return failureError
        }

        return CodexRPCError.invalidResponse("app-server exited early.")
    }

    private func makeRequestID() -> String {
        nextRequestNumber += 1
        return String(nextRequestNumber)
    }

    private func terminateProcessIfRunning() {
        if process.isRunning {
            process.terminate()
        }
    }

    private func closeInputHandleIfNeeded() {
        guard !didCloseInputHandle else {
            return
        }

        try? inputHandle.close()
        didCloseInputHandle = true
    }

    private func finalizeCleanup() {
        guard !didFinalizeCleanup else {
            return
        }

        didFinalizeCleanup = true
        closeInputHandleIfNeeded()
        try? outputHandle.close()
        try? stderrHandle.close()
        try? FileManager.default.removeItem(at: temporaryHomeURL)
    }
}

struct CodexRPCClient: Sendable, CodexRPCChannelInvalidating {
    private let channelPool: CodexRPCChannelPool

    init(channelPool: CodexRPCChannelPool = CodexRPCClient.makeDefaultChannelPool()) {
        self.channelPool = channelPool
    }

    func fetchSnapshot(codexHomeURL: URL) async throws -> CodexSnapshot {
        let homeURL = codexHomeURL.deletingLastPathComponent()
        return try await fetchSnapshot(
            homeOverride: homeURL,
            codexHomeOverride: codexHomeURL
        )
    }

    func fetchSnapshot(authData: Data, configData: Data? = nil) async throws -> CodexSnapshot {
        let fileManager = FileManager.default
        let runtime = try prepareTemporaryCodexRuntime(
            authData: authData,
            configData: configData,
            fileManager: fileManager
        )

        defer {
            try? fileManager.removeItem(at: runtime.tempHomeURL)
        }

        return try await fetchSnapshot(
            homeOverride: runtime.tempHomeURL,
            codexHomeOverride: runtime.tempCodexHomeURL
        )
    }

    func fetchSavedAccountSnapshot(
        authData: Data,
        configData: Data? = nil,
        timeout: TimeInterval
    ) async throws -> CodexSnapshot {
        let runtimeMaterial = canonicalRuntimeMaterialForStorage(
            ProfileRuntimeMaterial(authData: authData, configData: configData)
        )
        return try await channelPool.fetchSnapshot(
            runtimeMaterial: runtimeMaterial,
            timeout: timeout
        )
    }

    func invalidateAllReusableChannels() async {
        await channelPool.invalidateAll()
    }

    func invalidateReusableChannel(for runtimeMaterial: ProfileRuntimeMaterial) async {
        await channelPool.invalidate(runtimeMaterial: runtimeMaterial)
    }

    private func fetchSnapshot(
        homeOverride: URL?,
        codexHomeOverride: URL?
    ) async throws -> CodexSnapshot {
        let launch = try defaultLaunchConfiguration()

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
                try await sleepForTimeout(10)
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

            if let errorInfo = rpcErrorInfo(from: message) {
                if let fallback = fallbackRateLimitsSnapshot(
                    requestID: id,
                    errorCode: errorInfo.code,
                    message: errorInfo.message
                ) {
                    rateLimits = fallback
                    if let account {
                        return CodexSnapshot(account: account, rateLimits: fallback, fetchedAt: Date())
                    }
                    continue
                }
                throw mapRPCError(code: errorInfo.code, detail: errorInfo.message)
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

    private static func makeDefaultChannelPool() -> CodexRPCChannelPool {
        CodexRPCChannelPool { runtimeMaterial in
            try CodexRPCChannel.make(runtimeMaterial: runtimeMaterial)
        }
    }
}

private func prepareTemporaryCodexRuntime(
    authData: Data,
    configData: Data?,
    fileManager: FileManager
) throws -> TemporaryCodexRuntime {
    let tempHomeURL = fileManager.temporaryDirectory
        .appendingPathComponent("\(AppIdentity.temporaryDirectoryPrefix)-\(UUID().uuidString)", isDirectory: true)
    let tempCodexHomeURL = tempHomeURL.appendingPathComponent(".codex", isDirectory: true)

    try fileManager.createDirectory(
        at: tempCodexHomeURL,
        withIntermediateDirectories: true,
        attributes: nil
    )

    let authURL = tempCodexHomeURL.appendingPathComponent("auth.json", isDirectory: false)
    try authData.write(to: authURL, options: .atomic)

    if let configData {
        let configURL = tempCodexHomeURL.appendingPathComponent("config.toml", isDirectory: false)
        try configData.write(to: configURL, options: .atomic)
    }

    return TemporaryCodexRuntime(
        tempHomeURL: tempHomeURL,
        tempCodexHomeURL: tempCodexHomeURL
    )
}

private func defaultLaunchConfiguration() throws -> (executableURL: URL, arguments: [String]) {
    if let launchConfiguration = resolveCodexCLIConfiguration() {
        return (
            launchConfiguration.executableURL,
            launchConfiguration.arguments(
                appending: ["-s", "read-only", "-a", "untrusted", "app-server"]
            )
        )
    }

    throw CodexRPCError.missingExecutable
}

private func rpcErrorInfo(
    from message: [String: Any]
) -> (code: Int, message: String)? {
    guard let error = message["error"] as? [String: Any] else {
        return nil
    }

    return (
        code: error["code"] as? Int ?? 0,
        message: error["message"] as? String ?? "Unknown error"
    )
}

private func rpcError(from message: [String: Any]) -> CodexRPCError? {
    guard let errorInfo = rpcErrorInfo(from: message) else {
        return nil
    }

    return mapRPCError(code: errorInfo.code, detail: errorInfo.message)
}

private func mapRPCError(code: Int, detail: String) -> CodexRPCError {
    if code == -32600 {
        return .notLoggedIn
    }
    return .rpc(detail)
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

private func sleepForTimeout(_ timeout: TimeInterval) async throws {
    let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
    try await Task.sleep(nanoseconds: nanoseconds)
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
