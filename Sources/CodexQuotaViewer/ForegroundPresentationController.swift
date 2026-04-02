import AppKit
import Foundation

@MainActor
final class ForegroundPresentationController {
    private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Void
    private let activateApp: () -> Void
    private let isPrimaryWindowVisible: () -> Bool
    private var presentationDepth = 0

    init(
        setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { policy in
            _ = NSApp.setActivationPolicy(policy)
        },
        activateApp: @escaping () -> Void = {
            NSApp.activate(ignoringOtherApps: true)
        },
        isPrimaryWindowVisible: @escaping () -> Bool
    ) {
        self.setActivationPolicy = setActivationPolicy
        self.activateApp = activateApp
        self.isPrimaryWindowVisible = isPrimaryWindowVisible
    }

    func activate() {
        activateApp()
    }

    func begin() {
        presentationDepth += 1
        if presentationDepth == 1 {
            setActivationPolicy(.regular)
        }
        activateApp()
    }

    func endIfPossible() {
        presentationDepth = max(0, presentationDepth - 1)
        guard presentationDepth == 0,
              !isPrimaryWindowVisible() else {
            return
        }
        setActivationPolicy(.accessory)
    }

    func runModal<T>(_ body: () -> T) -> T {
        begin()
        defer { endIfPossible() }
        return body()
    }
}
