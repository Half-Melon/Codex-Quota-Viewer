import Foundation

enum BrowserLoginError: LocalizedError {
    case missingExecutable
    case authorizationURLMissing
    case authDataMissing
    case timedOut
    case cancelled
    case loginFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "找不到 codex 可执行文件，无法发起浏览器登录。"
        case .authorizationURLMissing:
            return "没有拿到浏览器登录地址。"
        case .authDataMissing:
            return "登录完成后没有生成 auth.json。"
        case .timedOut:
            return "浏览器登录超时，请重试。"
        case .cancelled:
            return "已取消添加账号。"
        case .loginFailed(let message):
            return "添加账号失败：\(message)"
        }
    }
}

actor BrowserLoginState {
    private var authorizationURL: URL?
    private var authorizationWaiters: [CheckedContinuation<URL, Error>] = []
    private var completionResult: Result<Data, Error>?
    private var completionWaiters: [CheckedContinuation<Data, Error>] = []
    private var outputLines: [String] = []
    private var cancelled = false

    func appendOutput(_ line: String) {
        guard !line.isEmpty else { return }
        outputLines.append(line)
    }

    func publishAuthorizationURL(_ url: URL) {
        guard authorizationURL == nil else { return }
        authorizationURL = url

        let waiters = authorizationWaiters
        authorizationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: url)
        }
    }

    func waitForAuthorizationURL() async throws -> URL {
        if let authorizationURL {
            return authorizationURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            authorizationWaiters.append(continuation)
        }
    }

    func markCancelled() {
        cancelled = true
    }

    func isCancelled() -> Bool {
        cancelled
    }

    func finish(_ result: Result<Data, Error>) {
        guard completionResult == nil else { return }
        completionResult = result

        let completionWaiters = self.completionWaiters
        self.completionWaiters.removeAll()
        for waiter in completionWaiters {
            waiter.resume(with: result)
        }

        if case .failure(let error) = result {
            let authorizationWaiters = self.authorizationWaiters
            self.authorizationWaiters.removeAll()
            for waiter in authorizationWaiters {
                waiter.resume(throwing: error)
            }
        }
    }

    func waitForCompletion() async throws -> Data {
        if let completionResult {
            return try completionResult.get()
        }

        return try await withCheckedThrowingContinuation { continuation in
            completionWaiters.append(continuation)
        }
    }

    func outputSummary() -> String {
        outputLines
            .suffix(8)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class BrowserLoginSession {
    let authorizationURL: URL

    private let state: BrowserLoginState
    private let process: Process
    private let sessionHomeURL: URL
    private let outputReaderTask: Task<Void, Never>
    private let timeoutTask: Task<Void, Never>
    private let cleanupTask: Task<Void, Never>

    init(
        authorizationURL: URL,
        state: BrowserLoginState,
        process: Process,
        sessionHomeURL: URL,
        outputReaderTask: Task<Void, Never>,
        timeoutTask: Task<Void, Never>,
        cleanupTask: Task<Void, Never>
    ) {
        self.authorizationURL = authorizationURL
        self.state = state
        self.process = process
        self.sessionHomeURL = sessionHomeURL
        self.outputReaderTask = outputReaderTask
        self.timeoutTask = timeoutTask
        self.cleanupTask = cleanupTask
    }

    func waitForCompletion() async throws -> Data {
        defer {
            timeoutTask.cancel()
        }
        return try await state.waitForCompletion()
    }

    func cancel() {
        let state = self.state
        Task {
            await state.markCancelled()
        }
        if process.isRunning {
            process.terminate()
        }
    }

    deinit {
        outputReaderTask.cancel()
        timeoutTask.cancel()
        cleanupTask.cancel()
        if process.isRunning {
            process.terminate()
        }
        try? FileManager.default.removeItem(at: sessionHomeURL)
    }
}

struct BrowserLoginService: Sendable {
    private let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func start() async throws -> BrowserLoginSession {
        let fileManager = FileManager.default
        let launch = try launchConfiguration()
        let sessionHomeURL = try makeSessionHomeURL()
        let authURL = sessionHomeURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)

        try fileManager.createDirectory(
            at: authURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let state = BrowserLoginState()
        let process = Process()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = sessionHomeURL.path
        environment["NO_COLOR"] = "1"
        environment["CLICOLOR"] = "0"
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let outputReaderTask = Task {
            do {
                for try await rawLine in outputPipe.fileHandleForReading.bytes.lines {
                    let line = Self.sanitizedLine(from: rawLine)
                    await state.appendOutput(line)

                    if let authorizationURL = Self.parseAuthorizationURL(from: line) {
                        await state.publishAuthorizationURL(authorizationURL)
                    }
                }
            } catch {
                await state.finish(.failure(error))
            }
        }

        let cleanupTask = Task {
            _ = try? await state.waitForCompletion()
            try? FileManager.default.removeItem(at: sessionHomeURL)
        }

        process.terminationHandler = { process in
            Task {
                let wasCancelled = await state.isCancelled()

                if wasCancelled {
                    await state.finish(.failure(BrowserLoginError.cancelled))
                    return
                }

                guard process.terminationStatus == 0 else {
                    let summary = await state.outputSummary()
                    let message = summary.isEmpty ? "codex login 退出码 \(process.terminationStatus)" : summary
                    await state.finish(.failure(BrowserLoginError.loginFailed(message)))
                    return
                }

                do {
                    let authData = try Data(contentsOf: authURL)
                    await state.finish(.success(authData))
                } catch {
                    await state.finish(.failure(BrowserLoginError.authDataMissing))
                }
            }
        }

        try process.run()

        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(960))
            if process.isRunning {
                process.terminate()
            }
            await state.finish(.failure(BrowserLoginError.timedOut))
        }

        let authorizationURL = try await state.waitForAuthorizationURL()
        return BrowserLoginSession(
            authorizationURL: authorizationURL,
            state: state,
            process: process,
            sessionHomeURL: sessionHomeURL,
            outputReaderTask: outputReaderTask,
            timeoutTask: timeoutTask,
            cleanupTask: cleanupTask
        )
    }

    private func makeSessionHomeURL() throws -> URL {
        let fileManager = FileManager.default
        let sessionsURL = baseURL.appendingPathComponent("browser-login-sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let sessionURL = sessionsURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: sessionURL, withIntermediateDirectories: true)
        return sessionURL
    }

    private func launchConfiguration() throws -> (executableURL: URL, arguments: [String]) {
        let fileManager = FileManager.default
        let bundled = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
        if fileManager.isExecutableFile(atPath: bundled.path) {
            return (bundled, ["login"])
        }

        let env = URL(fileURLWithPath: "/usr/bin/env")
        if fileManager.isExecutableFile(atPath: env.path) {
            return (env, ["codex", "login"])
        }

        throw BrowserLoginError.missingExecutable
    }

    private static func sanitizedLine(from rawLine: String) -> String {
        rawLine.replacingOccurrences(
            of: #"\u001B\[[0-9;]*[A-Za-z]"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseAuthorizationURL(from line: String) -> URL? {
        let pattern = #"https://auth\.openai\.com/oauth/authorize[^\s]+"#

        guard
            let range = line.range(of: pattern, options: .regularExpression),
            let url = URL(string: String(line[range]))
        else {
            return nil
        }

        return url
    }
}
