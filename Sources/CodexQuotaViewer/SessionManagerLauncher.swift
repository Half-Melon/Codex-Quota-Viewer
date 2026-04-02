import AppKit
import Darwin
import Foundation

private struct SessionManagerConfiguration {
    let port: Int
    let startupTimeout: TimeInterval
    let pollIntervalNanoseconds: UInt64

    static let `default` = SessionManagerConfiguration(
        port: 4318,
        startupTimeout: 10,
        pollIntervalNanoseconds: 250_000_000
    )

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    var healthURL: URL {
        baseURL.appendingPathComponent("api/health")
    }
}

private struct SessionManagerBundleLayout {
    let rootDirectoryURL: URL
    let appDirectoryURL: URL
    let runtimeNodeURL: URL
    let serverEntryURL: URL

    static func resolve(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> SessionManagerBundleLayout {
        guard let resourceURL = bundle.resourceURL else {
            throw SessionManagerLaunchError.bundleResourcesMissing
        }

        let rootDirectoryURL = resourceURL
            .appendingPathComponent("SessionManager", isDirectory: true)
        let appDirectoryURL = rootDirectoryURL.appendingPathComponent("App", isDirectory: true)
        let runtimeNodeURL = rootDirectoryURL
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("node", isDirectory: false)
        let serverEntryURL = appDirectoryURL
            .appendingPathComponent("dist", isDirectory: true)
            .appendingPathComponent("server", isDirectory: true)
            .appendingPathComponent("index.js", isDirectory: false)

        guard fileManager.fileExists(atPath: rootDirectoryURL.path) else {
            throw SessionManagerLaunchError.bundleResourcesMissing
        }

        guard fileManager.fileExists(atPath: appDirectoryURL.path),
              fileManager.fileExists(atPath: serverEntryURL.path) else {
            throw SessionManagerLaunchError.appFilesMissing
        }

        guard fileManager.isExecutableFile(atPath: runtimeNodeURL.path) else {
            throw SessionManagerLaunchError.runtimeMissing
        }

        return SessionManagerBundleLayout(
            rootDirectoryURL: rootDirectoryURL,
            appDirectoryURL: appDirectoryURL,
            runtimeNodeURL: runtimeNodeURL,
            serverEntryURL: serverEntryURL
        )
    }
}

enum SessionManagerLaunchResult {
    case reusedExistingService
    case startedBundledService
}

enum SessionManagerLaunchError: LocalizedError {
    case bundleResourcesMissing
    case appFilesMissing
    case runtimeMissing
    case browserOpenFailed
    case startFailed(String?)
    case startupTimedOut(String?)

    var errorDescription: String? {
        switch self {
        case .bundleResourcesMissing:
            return AppLocalization.localized(
                en: "Bundled session manager is missing. Rebuild CodexQuotaViewer.app.",
                zh: "内置 Session Manager 缺失，请重新构建 CodexQuotaViewer.app。"
            )
        case .appFilesMissing:
            return AppLocalization.localized(
                en: "Bundled session manager files are incomplete. Rebuild CodexQuotaViewer.app.",
                zh: "内置 Session Manager 文件不完整，请重新构建 CodexQuotaViewer.app。"
            )
        case .runtimeMissing:
            return AppLocalization.localized(
                en: "Bundled Node runtime is missing. Rebuild CodexQuotaViewer.app.",
                zh: "内置 Node 运行时缺失，请重新构建 CodexQuotaViewer.app。"
            )
        case .browserOpenFailed:
            return AppLocalization.localized(
                en: "Session manager is ready, but the default browser could not be opened.",
                zh: "Session Manager 已就绪，但无法打开默认浏览器。"
            )
        case .startFailed(let diagnostics):
            return startFailureMessage(diagnostics: diagnostics)
        case .startupTimedOut(let diagnostics):
            return startupTimeoutMessage(diagnostics: diagnostics)
        }
    }

    private func startFailureMessage(diagnostics: String?) -> String {
        if let diagnostics = diagnostics?.lowercased() {
            if diagnostics.contains("eaddrinuse") || diagnostics.contains("address already in use") {
                return AppLocalization.localized(
                    en: "Session manager could not start because port 4318 is already in use.",
                    zh: "Session Manager 无法启动，因为 4318 端口已被占用。"
                )
            }

            if diagnostics.contains("cannot find module") || diagnostics.contains("module not found") {
                return AppLocalization.localized(
                    en: "Bundled session manager files are incomplete. Rebuild CodexQuotaViewer.app.",
                    zh: "内置 Session Manager 文件不完整，请重新构建 CodexQuotaViewer.app。"
                )
            }
        }

        return AppLocalization.localized(en: "Session manager could not start.", zh: "Session Manager 无法启动。")
    }

    private func startupTimeoutMessage(diagnostics: String?) -> String {
        if let diagnostics = diagnostics?.lowercased(),
           diagnostics.contains("eaddrinuse") || diagnostics.contains("address already in use") {
            return AppLocalization.localized(
                en: "Session manager could not start because port 4318 is already in use.",
                zh: "Session Manager 无法启动，因为 4318 端口已被占用。"
            )
        }

        return AppLocalization.localized(
            en: "Timed out while waiting for the session manager to start.",
            zh: "等待 Session Manager 启动超时。"
        )
    }
}

@MainActor
final class SessionManagerLauncher {
    private let configuration: SessionManagerConfiguration
    private let healthChecker: SessionManagerHealthChecker
    private let fileManager: FileManager
    private let uiConfigURL: URL?
    private let defaultLanguageProvider: () -> ResolvedAppLanguage?

    private var launchedProcess: Process?
    private var processLogFileURL: URL?
    private var processLogHandle: FileHandle?

    init(
        urlSession: URLSession = .shared,
        fileManager: FileManager = .default,
        uiConfigURL: URL? = nil,
        defaultLanguageProvider: @escaping () -> ResolvedAppLanguage? = { nil }
    ) {
        let configuration = SessionManagerConfiguration.default
        self.configuration = configuration
        self.healthChecker = SessionManagerHealthChecker(
            healthURL: configuration.healthURL,
            urlSession: urlSession
        )
        self.fileManager = fileManager
        self.uiConfigURL = uiConfigURL
        self.defaultLanguageProvider = defaultLanguageProvider
    }

    var serviceBaseURL: URL {
        configuration.baseURL
    }

    func ensureServiceRunning() async throws -> SessionManagerLaunchResult {
        if await healthChecker.isHealthy() {
            return .reusedExistingService
        }

        if launchedProcess?.isRunning != true {
            try startManagedProcess()
        }

        try await waitUntilHealthy()
        return .startedBundledService
    }

    func openSessionManagerInBrowser() async throws -> SessionManagerLaunchResult {
        let result = try await ensureServiceRunning()

        guard NSWorkspace.shared.open(configuration.baseURL) else {
            throw SessionManagerLaunchError.browserOpenFailed
        }
        return result
    }

    func stopManagedProcess() {
        defer {
            launchedProcess = nil
            processLogHandle?.closeFile()
            processLogHandle = nil
            processLogFileURL = nil
        }

        guard let launchedProcess else {
            return
        }

        guard launchedProcess.isRunning else {
            return
        }

        launchedProcess.terminate()
        waitForProcessToExit(launchedProcess, timeout: 1)

        if launchedProcess.isRunning {
            kill(launchedProcess.processIdentifier, SIGKILL)
            waitForProcessToExit(launchedProcess, timeout: 1)
        }
    }

    private func startManagedProcess() throws {
        stopManagedProcess()

        let layout = try SessionManagerBundleLayout.resolve(bundle: .main, fileManager: fileManager)
        let logFileURL = try prepareProcessLogFile()
        let logHandle = try FileHandle(forWritingTo: logFileURL)

        var environment = ProcessInfo.processInfo.environment
        environment["NODE_ENV"] = "production"
        environment["PORT"] = "\(configuration.port)"
        if let uiConfigURL {
            environment["CODEX_VIEWER_UI_CONFIG_PATH"] = uiConfigURL.path
        }
        if let defaultLanguage = defaultLanguageProvider()?.rawValue {
            environment["CODEX_VIEWER_DEFAULT_LANGUAGE"] = defaultLanguage
        }

        let process = Process()
        process.executableURL = layout.runtimeNodeURL
        process.arguments = [layout.serverEntryURL.path]
        process.currentDirectoryURL = layout.appDirectoryURL
        process.environment = environment
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            logHandle.closeFile()
            throw error
        }

        launchedProcess = process
        processLogFileURL = logFileURL
        processLogHandle = logHandle
    }

    private func waitUntilHealthy() async throws {
        let deadline = Date().addingTimeInterval(configuration.startupTimeout)

        while Date() < deadline {
            if await healthChecker.isHealthy() {
                return
            }

            if let launchedProcess,
               !launchedProcess.isRunning {
                throw SessionManagerLaunchError.startFailed(readStartupDiagnostics())
            }

            try await Task.sleep(nanoseconds: configuration.pollIntervalNanoseconds)
        }

        if let launchedProcess,
           !launchedProcess.isRunning {
            throw SessionManagerLaunchError.startFailed(readStartupDiagnostics())
        }

        throw SessionManagerLaunchError.startupTimedOut(readStartupDiagnostics())
    }

    private func prepareProcessLogFile() throws -> URL {
        let logsDirectoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("CodexQuotaViewer", isDirectory: true)
        try fileManager.createDirectory(
            at: logsDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let logFileURL = logsDirectoryURL.appendingPathComponent("session-manager.log", isDirectory: false)
        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: Data())
        }

        let blankData = Data()
        try blankData.write(to: logFileURL, options: .atomic)
        return logFileURL
    }

    private func readStartupDiagnostics() -> String? {
        guard let processLogFileURL,
              let contents = try? String(contentsOf: processLogFileURL, encoding: .utf8),
              !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let tail = contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(6)
            .joined(separator: " ")

        return tail.isEmpty ? nil : tail
    }

    private func waitForProcessToExit(_ process: Process, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}
