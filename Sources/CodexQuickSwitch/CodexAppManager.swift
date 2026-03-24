import AppKit
import Foundation

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

        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty {
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        let remainingApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        for app in remainingApps {
            _ = app.forceTerminate()
        }

        try await Task.sleep(for: .milliseconds(500))
    }
}
