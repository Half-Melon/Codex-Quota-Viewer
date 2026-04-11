import AppKit
import Foundation

@MainActor
struct SettingsPresenterCallbacks {
    let onSettingsChanged: (AppSettings) -> Void
    let onAddChatGPTAccount: () -> Void
    let onAddAPIAccount: () -> Void
    let onActivateAccount: (String) -> Void
    let onRenameAccount: (String) -> Void
    let onForgetAccount: (String) -> Void
    let onOpenVaultFolder: () -> Void
    let onWindowClosed: () -> Void
}

@MainActor
protocol SettingsWindowPresenting: AnyObject {
    var isVisible: Bool { get }

    func update(
        settings: AppSettings,
        accountPanelState: SettingsAccountPanelState
    )

    func show(
        settings: AppSettings,
        accountPanelState: SettingsAccountPanelState,
        callbacks: SettingsPresenterCallbacks
    )
}

@MainActor
final class SettingsPresenter {
    private var controller: SettingsWindowController?

    var isVisible: Bool {
        controller?.window?.isVisible == true
    }

    func update(
        settings: AppSettings,
        accountPanelState: SettingsAccountPanelState
    ) {
        controller?.update(settings: settings, accountPanelState: accountPanelState)
    }

    func show(
        settings: AppSettings,
        accountPanelState: SettingsAccountPanelState,
        callbacks: SettingsPresenterCallbacks
    ) {
        let needsInitialController = controller == nil

        if controller == nil {
            let nextController = SettingsWindowController(
                settings: settings,
                accountPanelState: accountPanelState
            )
            controller = nextController
        }

        if let controller {
            apply(callbacks: callbacks, to: controller)
        }

        if !needsInitialController {
            controller?.update(settings: settings, accountPanelState: accountPanelState)
        }
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        controller?.window?.orderFrontRegardless()
    }

    private func apply(
        callbacks: SettingsPresenterCallbacks,
        to controller: SettingsWindowController
    ) {
        controller.onSettingsChanged = callbacks.onSettingsChanged
        controller.onAddChatGPTAccount = callbacks.onAddChatGPTAccount
        controller.onAddAPIAccount = callbacks.onAddAPIAccount
        controller.onActivateAccount = callbacks.onActivateAccount
        controller.onRenameAccount = callbacks.onRenameAccount
        controller.onForgetAccount = callbacks.onForgetAccount
        controller.onOpenVaultFolder = callbacks.onOpenVaultFolder
        controller.onWindowClosed = callbacks.onWindowClosed
    }
}

extension SettingsPresenter: SettingsWindowPresenting {}
