import AppKit
import Foundation

@MainActor
protocol SettingsWindowControlling: AnyObject {
    var isVisible: Bool { get }
    var window: NSWindow? { get }

    var onSettingsChanged: ((AppSettings) -> Void)? { get set }
    var onAddChatGPTAccount: (() -> Void)? { get set }
    var onAddAPIAccount: (() -> Void)? { get set }
    var onActivateAccount: ((String) -> Void)? { get set }
    var onRenameAccount: ((String) -> Void)? { get set }
    var onForgetAccount: ((String) -> Void)? { get set }
    var onOpenVaultFolder: (() -> Void)? { get set }
    var onWindowClosed: (() -> Void)? { get set }

    func update(
        settings: AppSettings,
        accountPanelState: SettingsAccountPanelState
    )

    func showWindow(_ sender: Any?)
}

extension SettingsWindowController: SettingsWindowControlling {
    var isVisible: Bool {
        window?.isVisible == true
    }
}

@MainActor
final class SettingsWindowCoordinator {
    private let controllerFactory: (AppSettings, SettingsAccountPanelState) -> SettingsWindowControlling
    private var controller: SettingsWindowControlling?

    init(
        controllerFactory: @escaping (AppSettings, SettingsAccountPanelState) -> SettingsWindowControlling = {
            SettingsWindowController(settings: $0, accountPanelState: $1)
        }
    ) {
        self.controllerFactory = controllerFactory
    }

    var isVisible: Bool {
        controller?.isVisible ?? false
    }

    func update(
        settings: AppSettings,
        accountPanelState: SettingsAccountPanelState
    ) {
        controller?.update(
            settings: settings,
            accountPanelState: accountPanelState
        )
    }

    func update(state: SettingsWindowPresentationState) {
        update(
            settings: state.settings,
            accountPanelState: state.accountPanelState
        )
    }

    @discardableResult
    func show(
        settings: AppSettings,
        accountPanelState: SettingsAccountPanelState,
        callbacks: SettingsPresenterCallbacks
    ) -> Bool {
        let wasVisible = isVisible
        let needsInitialController = controller == nil

        if controller == nil {
            controller = controllerFactory(settings, accountPanelState)
        }

        if let controller {
            apply(callbacks: callbacks, to: controller)
            if !needsInitialController {
                controller.update(
                    settings: settings,
                    accountPanelState: accountPanelState
                )
            }
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.window?.orderFrontRegardless()
        }

        return !wasVisible
    }

    @discardableResult
    func show(
        state: SettingsWindowPresentationState,
        callbacks: SettingsPresenterCallbacks
    ) -> Bool {
        show(
            settings: state.settings,
            accountPanelState: state.accountPanelState,
            callbacks: callbacks
        )
    }

    private func apply(
        callbacks: SettingsPresenterCallbacks,
        to controller: SettingsWindowControlling
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
