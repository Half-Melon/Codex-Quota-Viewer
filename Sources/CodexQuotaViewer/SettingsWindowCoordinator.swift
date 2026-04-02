import Foundation

@MainActor
final class SettingsWindowCoordinator {
    private let presenter: SettingsWindowPresenting

    init(presenter: SettingsWindowPresenting = SettingsPresenter()) {
        self.presenter = presenter
    }

    var isVisible: Bool {
        presenter.isVisible
    }

    func update(
        settings: AppSettings,
        accountPanelState: SettingsAccountPanelState
    ) {
        presenter.update(
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
        let wasVisible = presenter.isVisible
        presenter.show(
            settings: settings,
            accountPanelState: accountPanelState,
            callbacks: callbacks
        )
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
}
