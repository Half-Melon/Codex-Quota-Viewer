import AppKit
import Foundation

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
    var onSettingsChanged: ((AppSettings) -> Void)?
    var onAddChatGPTAccount: (() -> Void)?
    var onAddAPIAccount: (() -> Void)?
    var onActivateAccount: ((String) -> Void)?
    var onRenameAccount: ((String) -> Void)?
    var onForgetAccount: ((String) -> Void)?
    var onOpenVaultFolder: (() -> Void)?
    var onWindowClosed: (() -> Void)?

    private var settings: AppSettings
    private var accountPanelState: SettingsAccountPanelState

    private let tabView = NSTabView()
    private let generalView = SettingsGeneralView()
    private let accountsView = SettingsAccountsView()
    private lazy var accountsTableController = makeAccountsTableController()

    init(settings: AppSettings, accountPanelState: SettingsAccountPanelState) {
        self.settings = settings
        self.accountPanelState = accountPanelState

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppLocalization.localized(en: "Settings", zh: "设置")
        window.center()
        window.minSize = NSSize(width: 700, height: 520)
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        setupUI()
        applySettingsToControls()
        applyAccountPanelState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(settings: AppSettings, accountPanelState: SettingsAccountPanelState) {
        self.settings = settings
        self.accountPanelState = accountPanelState
        applySettingsToControls()
        applyAccountPanelState()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.delegate = self
        contentView.addSubview(tabView)

        let generalItem = NSTabViewItem(identifier: "general")
        generalItem.label = AppLocalization.localized(en: "General", zh: "通用")
        generalItem.view = generalView
        tabView.addTabViewItem(generalItem)

        let accountsItem = NSTabViewItem(identifier: "accounts")
        accountsItem.label = AppLocalization.localized(en: "Accounts", zh: "账号")
        accountsItem.view = accountsView
        tabView.addTabViewItem(accountsItem)

        configurePopup(generalView.refreshPopup, values: RefreshIntervalPreset.allCases.map(\.rawValue))
        configurePopup(generalView.languagePopup, values: AppLanguage.allCases.map(\.rawValue))
        configurePopup(generalView.iconStylePopup, values: StatusItemStyle.allCases.map(\.rawValue))

        generalView.launchAtLoginCheckbox.target = self
        generalView.launchAtLoginCheckbox.action = #selector(controlChanged)
        accountsView.addChatGPTButton.target = self
        accountsView.addChatGPTButton.action = #selector(addChatGPTClicked)
        accountsView.addAPIButton.target = self
        accountsView.addAPIButton.action = #selector(addAPIClicked)
        accountsView.openVaultButton.target = self
        accountsView.openVaultButton.action = #selector(openVaultClicked)

        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    private func makeAccountsTableController() -> SettingsAccountsTableController {
        let controller = SettingsAccountsTableController(tableView: accountsView.tableView)
        controller.onActivateAccount = { [weak self] identifier in
            self?.onActivateAccount?(identifier)
        }
        controller.onRenameAccount = { [weak self] identifier in
            self?.onRenameAccount?(identifier)
        }
        controller.onForgetAccount = { [weak self] identifier in
            self?.onForgetAccount?(identifier)
        }
        return controller
    }

    private func applySettingsToControls() {
        applyLocalizedText()
        updatePopupTitles(generalView.refreshPopup, values: RefreshIntervalPreset.allCases.map(\.displayName))
        updatePopupTitles(generalView.languagePopup, values: AppLanguage.allCases.map(\.displayName))
        updatePopupTitles(generalView.iconStylePopup, values: StatusItemStyle.allCases.map(\.displayName))

        selectItem(in: generalView.refreshPopup, matching: settings.refreshIntervalPreset.rawValue)
        selectItem(in: generalView.languagePopup, matching: settings.appLanguage.rawValue)
        selectItem(in: generalView.iconStylePopup, matching: settings.statusItemStyle.rawValue)
        generalView.launchAtLoginCheckbox.state = settings.launchAtLoginEnabled ? .on : .off
    }

    private func applyAccountPanelState() {
        let actionsUnavailableExplanation = accountPanelState.actionsEnabled
            ? nil
            : AppLocalization.localized(
                en: "Finish the current account operation before changing saved accounts.",
                zh: "请先完成当前账号操作，再修改已保存账号。"
            )
        accountsView.importStatusLabel.stringValue = joinedNonEmptyParts(
            [accountPanelState.importStatusText, actionsUnavailableExplanation],
            separator: "\n"
        )
        accountsView.importStatusLabel.isHidden = accountsView.importStatusLabel.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        accountsView.addChatGPTButton.isEnabled = accountPanelState.actionsEnabled
        accountsView.addAPIButton.isEnabled = accountPanelState.actionsEnabled
        accountsView.addChatGPTButton.toolTip = actionsUnavailableExplanation
        accountsView.addAPIButton.toolTip = actionsUnavailableExplanation
        accountsView.openVaultButton.isEnabled = true
        accountsTableController.update(state: accountPanelState)
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func applyLocalizedText() {
        window?.title = AppLocalization.localized(en: "Settings", zh: "设置")
        generalView.applyLocalizedText()
        accountsView.applyLocalizedText()

        tabView.tabViewItems.first(where: { ($0.identifier as? String) == "general" })?.label =
            AppLocalization.localized(en: "General", zh: "通用")
        tabView.tabViewItems.first(where: { ($0.identifier as? String) == "accounts" })?.label =
            AppLocalization.localized(en: "Accounts", zh: "账号")
    }

    private func configurePopup(_ popup: NSPopUpButton, values: [String]) {
        popup.removeAllItems()
        popup.target = self
        popup.action = #selector(controlChanged)
        for value in values {
            popup.addItem(withTitle: value)
            popup.lastItem?.representedObject = value
        }
    }

    private func updatePopupTitles(_ popup: NSPopUpButton, values: [String]) {
        for (index, value) in values.enumerated() where index < popup.numberOfItems {
            popup.item(at: index)?.title = value
        }
    }

    private func selectItem(in popup: NSPopUpButton, matching rawValue: String) {
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == rawValue }) {
            popup.select(item)
        }
    }

    @objc
    private func controlChanged() {
        if let rawValue = generalView.refreshPopup.selectedItem?.representedObject as? String,
           let preset = RefreshIntervalPreset(rawValue: rawValue) {
            settings.refreshIntervalPreset = preset
        }

        if let rawValue = generalView.languagePopup.selectedItem?.representedObject as? String,
           let language = AppLanguage(rawValue: rawValue) {
            settings.appLanguage = language
        }

        if let rawValue = generalView.iconStylePopup.selectedItem?.representedObject as? String,
           let style = StatusItemStyle(rawValue: rawValue) {
            settings.statusItemStyle = style
        }

        settings.launchAtLoginEnabled = generalView.launchAtLoginCheckbox.state == .on
        onSettingsChanged?(settings)
    }

    @objc
    private func addChatGPTClicked() {
        onAddChatGPTAccount?()
    }

    @objc
    private func addAPIClicked() {
        onAddAPIAccount?()
    }

    @objc
    private func openVaultClicked() {
        onOpenVaultFolder?()
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClosed?()
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        window?.contentView?.layoutSubtreeIfNeeded()
    }
}
