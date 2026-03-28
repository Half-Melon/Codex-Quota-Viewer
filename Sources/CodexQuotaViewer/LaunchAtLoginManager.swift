import Foundation

enum LaunchAtLoginError: LocalizedError {
    case unsupportedBundle

    var errorDescription: String? {
        switch self {
        case .unsupportedBundle:
            return "当前运行环境不支持配置开机启动。请从 .app 包中启动后再试。"
        }
    }
}

struct LaunchAtLoginManager {
    private let fileManager = FileManager.default
    private let label = AppIdentity.launchAgentLabel
    private let legacyLabels = AppIdentity.legacyLaunchAgentLabels

    private var plistURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist", isDirectory: false)
    }

    private var legacyPlistURLs: [URL] {
        legacyLabels.map {
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("LaunchAgents", isDirectory: true)
                .appendingPathComponent("\($0).plist", isDirectory: false)
        }
    }

    func sync(enabled: Bool) throws {
        if enabled {
            try enable()
        } else {
            try disable()
        }
    }

    private func enable() throws {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let executablePath = Bundle.main.executableURL?.path else {
            throw LaunchAtLoginError.unsupportedBundle
        }

        try fileManager.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "LimitLoadToSessionType": ["Aqua"],
            "WorkingDirectory": Bundle.main.bundleURL.deletingLastPathComponent().path,
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL, options: .atomic)

        let domain = "gui/\(getuid())"
        for legacyPlistURL in legacyPlistURLs {
            _ = try? runLaunchctl(arguments: ["bootout", domain, legacyPlistURL.path], ignoreFailure: true)
            if fileManager.fileExists(atPath: legacyPlistURL.path) {
                try? fileManager.removeItem(at: legacyPlistURL)
            }
        }
        _ = try? runLaunchctl(arguments: ["bootout", domain, plistURL.path], ignoreFailure: true)
        try runLaunchctl(arguments: ["bootstrap", domain, plistURL.path], ignoreFailure: false)
    }

    private func disable() throws {
        let domain = "gui/\(getuid())"
        for legacyPlistURL in legacyPlistURLs {
            _ = try? runLaunchctl(arguments: ["bootout", domain, legacyPlistURL.path], ignoreFailure: true)
            if fileManager.fileExists(atPath: legacyPlistURL.path) {
                try fileManager.removeItem(at: legacyPlistURL)
            }
        }
        _ = try? runLaunchctl(arguments: ["bootout", domain, plistURL.path], ignoreFailure: true)
        if fileManager.fileExists(atPath: plistURL.path) {
            try fileManager.removeItem(at: plistURL)
        }
    }

    @discardableResult
    private func runLaunchctl(arguments: [String], ignoreFailure: Bool) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if process.terminationStatus != 0 && !ignoreFailure {
            throw NSError(
                domain: "\(AppIdentity.packageName).LaunchAtLogin",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? output : error]
            )
        }

        return output + error
    }
}
