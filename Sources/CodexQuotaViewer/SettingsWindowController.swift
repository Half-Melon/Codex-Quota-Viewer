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

    private let refreshPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let iconStylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tabView = NSTabView()
    private let generalSectionTitleLabel = NSTextField(labelWithString: "")
    private let refreshRowLabel = NSTextField(labelWithString: "")
    private let languageRowLabel = NSTextField(labelWithString: "")
    private let iconStyleRowLabel = NSTextField(labelWithString: "")

    private let importStatusLabel = NSTextField(labelWithString: "")
    private let accountsHeaderView = NSView()
    private let accountsScrollView = NSScrollView()
    private let accountsTableView = NSTableView()
    private lazy var accountsTableController = makeAccountsTableController()
    private let addChatGPTButton = NSButton(title: "", target: nil, action: nil)
    private let addAPIButton = NSButton(title: "", target: nil, action: nil)
    private let openVaultButton = NSButton(title: "", target: nil, action: nil)

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
        generalItem.view = makeGeneralTabView()
        tabView.addTabViewItem(generalItem)

        let accountsItem = NSTabViewItem(identifier: "accounts")
        accountsItem.label = AppLocalization.localized(en: "Accounts", zh: "账号")
        accountsItem.view = makeAccountsTabView()
        tabView.addTabViewItem(accountsItem)

        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    private func makeGeneralTabView() -> NSView {
        let container = NSView()
        container.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        configurePopup(refreshPopup, values: RefreshIntervalPreset.allCases.map(\.rawValue))
        configurePopup(languagePopup, values: AppLanguage.allCases.map(\.rawValue))
        configurePopup(iconStylePopup, values: StatusItemStyle.allCases.map(\.rawValue))
        generalSectionTitleLabel.identifier = NSUserInterfaceItemIdentifier("settings.general.section")
        refreshRowLabel.identifier = NSUserInterfaceItemIdentifier("settings.general.refresh")
        languageRowLabel.identifier = NSUserInterfaceItemIdentifier("settings.general.language")
        iconStyleRowLabel.identifier = NSUserInterfaceItemIdentifier("settings.general.icon-style")

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(controlChanged)

        stack.addArrangedSubview(
            makeSectionTitleLabel(generalSectionTitleLabel)
        )
        stack.addArrangedSubview(
            makeRow(
                label: refreshRowLabel,
                control: refreshPopup
            )
        )
        stack.addArrangedSubview(
            makeRow(
                label: languageRowLabel,
                control: languagePopup
            )
        )
        stack.addArrangedSubview(
            makeRow(
                label: iconStyleRowLabel,
                control: iconStylePopup
            )
        )
        stack.addArrangedSubview(launchAtLoginCheckbox)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
        ])

        return container
    }

    private func makeAccountsTabView() -> NSView {
        let container = NSView()
        container.autoresizingMask = [.width, .height]

        accountsHeaderView.identifier = NSUserInterfaceItemIdentifier("settings.accounts.header")
        accountsHeaderView.translatesAutoresizingMaskIntoConstraints = false
        accountsHeaderView.wantsLayer = true
        accountsHeaderView.layer?.cornerRadius = 12
        accountsHeaderView.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.06).cgColor
        container.addSubview(accountsHeaderView)

        accountsScrollView.identifier = NSUserInterfaceItemIdentifier("settings.accounts.scroll")
        accountsScrollView.translatesAutoresizingMaskIntoConstraints = false
        accountsScrollView.drawsBackground = false
        accountsScrollView.hasVerticalScroller = true
        accountsScrollView.autohidesScrollers = true
        accountsScrollView.borderType = .noBorder
        accountsScrollView.documentView = accountsTableView
        container.addSubview(accountsScrollView)

        addChatGPTButton.target = self
        addChatGPTButton.action = #selector(addChatGPTClicked)
        addAPIButton.target = self
        addAPIButton.action = #selector(addAPIClicked)
        openVaultButton.target = self
        openVaultButton.action = #selector(openVaultClicked)

        [addChatGPTButton, addAPIButton, openVaultButton].forEach {
            $0.controlSize = .small
        }

        let primaryActions = NSStackView(views: [addChatGPTButton, addAPIButton])
        primaryActions.orientation = .horizontal
        primaryActions.alignment = .centerY
        primaryActions.spacing = 10
        primaryActions.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttonRow = NSStackView(views: [primaryActions, spacer, openVaultButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        importStatusLabel.font = .systemFont(ofSize: 12)
        importStatusLabel.textColor = .secondaryLabelColor
        importStatusLabel.maximumNumberOfLines = 1
        importStatusLabel.lineBreakMode = .byTruncatingTail
        importStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView(views: [buttonRow, importStatusLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 10
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        accountsHeaderView.addSubview(headerStack)

        NSLayoutConstraint.activate([
            accountsHeaderView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            accountsHeaderView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            accountsHeaderView.topAnchor.constraint(equalTo: container.topAnchor),

            accountsScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            accountsScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            accountsScrollView.topAnchor.constraint(equalTo: accountsHeaderView.bottomAnchor, constant: 12),
            accountsScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            headerStack.leadingAnchor.constraint(equalTo: accountsHeaderView.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: accountsHeaderView.trailingAnchor, constant: -16),
            headerStack.topAnchor.constraint(equalTo: accountsHeaderView.topAnchor, constant: 16),
            headerStack.bottomAnchor.constraint(equalTo: accountsHeaderView.bottomAnchor, constant: -16),
            buttonRow.widthAnchor.constraint(equalTo: headerStack.widthAnchor),
            importStatusLabel.widthAnchor.constraint(equalTo: headerStack.widthAnchor),
        ])

        return container
    }

    private func makeAccountsTableController() -> SettingsAccountsTableController {
        let controller = SettingsAccountsTableController(tableView: accountsTableView)
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

    private func makeSectionTitleLabel(_ label: NSTextField) -> NSTextField {
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    private func makeRow(label: NSTextField, control: NSView) -> NSView {
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 112).isActive = true

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func applySettingsToControls() {
        applyLocalizedText()
        updatePopupTitles(refreshPopup, values: RefreshIntervalPreset.allCases.map(\.displayName))
        updatePopupTitles(languagePopup, values: AppLanguage.allCases.map(\.displayName))
        updatePopupTitles(iconStylePopup, values: StatusItemStyle.allCases.map(\.displayName))

        selectItem(in: refreshPopup, matching: settings.refreshIntervalPreset.rawValue)
        selectItem(in: languagePopup, matching: settings.appLanguage.rawValue)
        selectItem(in: iconStylePopup, matching: settings.statusItemStyle.rawValue)
        launchAtLoginCheckbox.state = settings.launchAtLoginEnabled ? .on : .off
    }

    private func applyAccountPanelState() {
        importStatusLabel.stringValue = accountPanelState.importStatusText
        importStatusLabel.isHidden = accountPanelState.importStatusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        addChatGPTButton.isEnabled = accountPanelState.actionsEnabled
        addAPIButton.isEnabled = accountPanelState.actionsEnabled
        openVaultButton.isEnabled = true
        accountsTableController.update(state: accountPanelState)
        accountsTableView.reloadData()
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func applyLocalizedText() {
        window?.title = AppLocalization.localized(en: "Settings", zh: "设置")
        generalSectionTitleLabel.stringValue = AppLocalization.localized(en: "General", zh: "通用")
        refreshRowLabel.stringValue = AppLocalization.localized(en: "Refresh interval", zh: "刷新频率")
        languageRowLabel.stringValue = AppLocalization.localized(en: "Language", zh: "语言")
        iconStyleRowLabel.stringValue = AppLocalization.localized(en: "Menu bar style", zh: "状态栏样式")
        launchAtLoginCheckbox.title = AppLocalization.localized(en: "Launch at login", zh: "登录时启动")
        addChatGPTButton.title = AppLocalization.localized(en: "Sign in with ChatGPT", zh: "使用 ChatGPT 登录")
        addAPIButton.title = AppLocalization.localized(en: "Add API Account", zh: "添加 API 账号")
        openVaultButton.title = AppLocalization.localized(en: "Open Vault Folder", zh: "打开账号仓文件夹")

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
        if let rawValue = refreshPopup.selectedItem?.representedObject as? String,
           let preset = RefreshIntervalPreset(rawValue: rawValue) {
            settings.refreshIntervalPreset = preset
        }

        if let rawValue = languagePopup.selectedItem?.representedObject as? String,
           let language = AppLanguage(rawValue: rawValue) {
            settings.appLanguage = language
        }

        if let rawValue = iconStylePopup.selectedItem?.representedObject as? String,
           let style = StatusItemStyle(rawValue: rawValue) {
            settings.statusItemStyle = style
        }

        settings.launchAtLoginEnabled = launchAtLoginCheckbox.state == .on
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
