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
            return "Bundled session manager is missing. Rebuild CodexQuotaViewer.app."
        case .appFilesMissing:
            return "Bundled session manager files are incomplete. Rebuild CodexQuotaViewer.app."
        case .runtimeMissing:
            return "Bundled Node runtime is missing. Rebuild CodexQuotaViewer.app."
        case .browserOpenFailed:
            return "Session manager is ready, but the default browser could not be opened."
        case .startFailed(let diagnostics):
            return startFailureMessage(diagnostics: diagnostics)
        case .startupTimedOut(let diagnostics):
            return startupTimeoutMessage(diagnostics: diagnostics)
        }
    }

    private func startFailureMessage(diagnostics: String?) -> String {
        if let diagnostics = diagnostics?.lowercased() {
            if diagnostics.contains("eaddrinuse") || diagnostics.contains("address already in use") {
                return "Session manager could not start because port 4318 is already in use."
            }

            if diagnostics.contains("cannot find module") || diagnostics.contains("module not found") {
                return "Bundled session manager files are incomplete. Rebuild CodexQuotaViewer.app."
            }
        }

        return "Session manager could not start."
    }

    private func startupTimeoutMessage(diagnostics: String?) -> String {
        if let diagnostics = diagnostics?.lowercased(),
           diagnostics.contains("eaddrinuse") || diagnostics.contains("address already in use") {
            return "Session manager could not start because port 4318 is already in use."
        }

        return "Timed out while waiting for the session manager to start."
    }
}

@MainActor
final class SessionManagerLauncher {
    private let configuration: SessionManagerConfiguration
    private let healthChecker: SessionManagerHealthChecker
    private let fileManager: FileManager

    private var launchedProcess: Process?
    private var processLogFileURL: URL?
    private var processLogHandle: FileHandle?

    init(
        urlSession: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        let configuration = SessionManagerConfiguration.default
        self.configuration = configuration
        self.healthChecker = SessionManagerHealthChecker(
            healthURL: configuration.healthURL,
            urlSession: urlSession
        )
        self.fileManager = fileManager
    }

    func openSessionManagerInBrowser() async throws -> SessionManagerLaunchResult {
        if await healthChecker.isHealthy() {
            guard NSWorkspace.shared.open(configuration.baseURL) else {
                throw SessionManagerLaunchError.browserOpenFailed
            }
            return .reusedExistingService
        }

        if launchedProcess?.isRunning != true {
            try startManagedProcess()
        }

        try await waitUntilHealthy()

        guard NSWorkspace.shared.open(configuration.baseURL) else {
            throw SessionManagerLaunchError.browserOpenFailed
        }
        return .startedBundledService
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
              let contents = try? String(contentsOf: processLogFileURL),
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
