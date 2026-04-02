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
            nextController.onSettingsChanged = callbacks.onSettingsChanged
            nextController.onAddChatGPTAccount = callbacks.onAddChatGPTAccount
            nextController.onAddAPIAccount = callbacks.onAddAPIAccount
            nextController.onActivateAccount = callbacks.onActivateAccount
            nextController.onRenameAccount = callbacks.onRenameAccount
            nextController.onForgetAccount = callbacks.onForgetAccount
            nextController.onOpenVaultFolder = callbacks.onOpenVaultFolder
            nextController.onWindowClosed = callbacks.onWindowClosed
            controller = nextController
        }

        if !needsInitialController {
            controller?.update(settings: settings, accountPanelState: accountPanelState)
        }
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        controller?.window?.orderFrontRegardless()
    }
}

extension SettingsPresenter: SettingsWindowPresenting {}
