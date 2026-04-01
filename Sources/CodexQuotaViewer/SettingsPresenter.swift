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

        controller?.update(settings: settings, accountPanelState: accountPanelState)
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        controller?.window?.orderFrontRegardless()
    }
}
