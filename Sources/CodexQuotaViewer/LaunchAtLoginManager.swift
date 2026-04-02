import Foundation

enum LaunchAtLoginError: LocalizedError {
    case unsupportedBundle

    var errorDescription: String? {
        switch self {
        case .unsupportedBundle:
            return AppLocalization.localized(
                en: "Launch at login can only be configured when running from the app bundle.",
                zh: "只有从 app bundle 运行时才能配置登录时启动。"
            )
        }
    }
}

struct LaunchAtLoginManager {
    private let fileManager = FileManager.default
    private let label = AppIdentity.launchAgentLabel

    private var plistURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist", isDirectory: false)
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
        _ = try? runLaunchctl(arguments: ["bootout", domain, plistURL.path], ignoreFailure: true)
        do {
            try runLaunchctl(arguments: ["bootstrap", domain, plistURL.path], ignoreFailure: false)
        } catch {
            _ = try? runLaunchctl(arguments: ["bootout", domain, plistURL.path], ignoreFailure: true)
            if fileManager.fileExists(atPath: plistURL.path) {
                try? fileManager.removeItem(at: plistURL)
            }
            throw error
        }
    }

    private func disable() throws {
        let domain = "gui/\(getuid())"
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
