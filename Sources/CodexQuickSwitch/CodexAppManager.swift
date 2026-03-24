import AppKit
import Foundation

enum CodexAppManagerError: LocalizedError {
    case failedToTerminate

    var errorDescription: String? {
        switch self {
        case .failedToTerminate:
            return "Codex.app 未能完全退出，已取消切换。"
        }
    }
}

struct CodexAppManager: Sendable, CodexAppManaging {
    private let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
    private let bundleIdentifier = "com.openai.codex"

    func isCodexRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    func terminateCodex() async throws {
        try await terminateRunningCodex()
    }

    func launchCodex(activate: Bool) throws {
        _ = activate
        guard NSWorkspace.shared.open(appURL) else {
            throw NSError(
                domain: "CodexQuickSwitch",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法打开 /Applications/Codex.app"]
            )
        }
    }

    private func terminateRunningCodex() async throws {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)

        for app in runningApps {
            _ = app.terminate()
        }

        if try await waitUntilCodexStops(deadline: Date().addingTimeInterval(2.5)) {
            return
        }

        let remainingApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        for app in remainingApps {
            _ = app.forceTerminate()
        }

        if try await waitUntilCodexStops(deadline: Date().addingTimeInterval(2.0)) {
            return
        }

        throw CodexAppManagerError.failedToTerminate
    }

    private func waitUntilCodexStops(deadline: Date) async throws -> Bool {
        while Date() < deadline {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty {
                return true
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}
