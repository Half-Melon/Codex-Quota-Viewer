import AppKit
import Foundation

private enum SettingsAccountsTableRow: Equatable {
    case section(SettingsAccountSection)
    case account(SettingsAccountItem)
}

@MainActor
final class SettingsAccountsTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onActivateAccount: ((String) -> Void)?
    var onRenameAccount: ((String) -> Void)?
    var onForgetAccount: ((String) -> Void)?

    private let tableView: NSTableView
    private var rows: [SettingsAccountsTableRow] = []
    private var actionsEnabled = true

    init(tableView: NSTableView) {
        self.tableView = tableView
        super.init()
        configureTableView()
    }

    func update(state: SettingsAccountPanelState) {
        actionsEnabled = state.actionsEnabled
        rows = state.sections.flatMap { section in
            [SettingsAccountsTableRow.section(section)] + section.items.map(SettingsAccountsTableRow.account)
        }

        tableView.reloadData()
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< rows.count))
        tableView.layoutSubtreeIfNeeded()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .section:
            return 26
        case .account:
            return 58
        }
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        switch rows[row] {
        case .section(let section):
            return configuredSectionView(section.title)
        case .account(let item):
            return configuredAccountView(item)
        }
    }

    private func configureTableView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("settings.accounts.column"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.focusRingType = .none
        tableView.selectionHighlightStyle = .none
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.rowSizeStyle = .small
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.target = self
        tableView.delegate = self
        tableView.dataSource = self
        tableView.identifier = NSUserInterfaceItemIdentifier("settings.accounts.table")
        tableView.backgroundColor = .clear
    }

    private func configuredSectionView(_ title: String) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("settings.accounts.section.row")
        let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? SettingsAccountsSectionRowView)
            ?? SettingsAccountsSectionRowView()
        view.identifier = identifier
        view.apply(title: title)
        return view
    }

    private func configuredAccountView(_ item: SettingsAccountItem) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("settings.accounts.account.row")
        let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? SettingsAccountsTableCellView)
            ?? SettingsAccountsTableCellView()
        view.identifier = identifier
        view.apply(
            item: item,
            actionsEnabled: actionsEnabled,
            onActivate: { [weak self] id in self?.onActivateAccount?(id) },
            onRename: { [weak self] id in self?.onRenameAccount?(id) },
            onForget: { [weak self] id in self?.onForgetAccount?(id) }
        )
        return view
    }
}

private final class SettingsAccountsSectionRowView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(title: String) {
        titleLabel.stringValue = title
    }

    private func setupUI() {
        wantsLayer = true
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

private final class SettingsAccountsTableCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let activateButton = NSButton(
        title: AppLocalization.localized(en: "Activate", zh: "切换"),
        target: nil,
        action: nil
    )
    private let renameButton = NSButton(
        title: AppLocalization.localized(en: "Rename…", zh: "重命名…"),
        target: nil,
        action: nil
    )
    private let forgetButton = NSButton(
        title: AppLocalization.localized(en: "Forget…", zh: "移除…"),
        target: nil,
        action: nil
    )
    private let contentRow = NSStackView()
    private let textStack = NSStackView()
    private let buttonStack = NSStackView()

    private var accountID: String?
    private var onActivate: ((String) -> Void)?
    private var onRename: ((String) -> Void)?
    private var onForget: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(
        item: SettingsAccountItem,
        actionsEnabled: Bool,
        onActivate: @escaping (String) -> Void,
        onRename: @escaping (String) -> Void,
        onForget: @escaping (String) -> Void
    ) {
        accountID = item.id
        self.onActivate = onActivate
        self.onRename = onRename
        self.onForget = onForget

        titleLabel.stringValue = item.title
        subtitleLabel.stringValue = item.subtitle
        activateButton.title = AppLocalization.localized(en: "Activate", zh: "切换")
        renameButton.title = AppLocalization.localized(en: "Rename…", zh: "重命名…")
        forgetButton.title = AppLocalization.localized(en: "Forget…", zh: "移除…")

        activateButton.isHidden = !item.canActivate
        renameButton.isHidden = !item.canRename
        forgetButton.isHidden = !item.canForget

        activateButton.isEnabled = actionsEnabled && item.canActivate
        renameButton.isEnabled = actionsEnabled && item.canRename
        forgetButton.isEnabled = actionsEnabled && item.canForget
        updateAppearance(isCurrent: item.isCurrent)
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 9

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        activateButton.target = self
        activateButton.action = #selector(handleActivate)
        renameButton.target = self
        renameButton.action = #selector(handleRename)
        forgetButton.target = self
        forgetButton.action = #selector(handleForget)
        [activateButton, renameButton, forgetButton].forEach {
            $0.bezelStyle = .rounded
            $0.controlSize = .small
            $0.font = .systemFont(ofSize: 11)
            $0.setButtonType(.momentaryPushIn)
        }

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)

        buttonStack.setViews([activateButton, renameButton, forgetButton], in: .leading)
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 6
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        buttonStack.setContentHuggingPriority(.required, for: .horizontal)

        contentRow.orientation = .horizontal
        contentRow.alignment = .centerY
        contentRow.spacing = 12
        contentRow.translatesAutoresizingMaskIntoConstraints = false
        contentRow.addArrangedSubview(textStack)
        contentRow.addArrangedSubview(makeFlexibleSpacer())
        contentRow.addArrangedSubview(buttonStack)
        addSubview(contentRow)

        NSLayoutConstraint.activate([
            contentRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contentRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            contentRow.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            contentRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            textStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }

    private func updateAppearance(isCurrent: Bool) {
        let backgroundColor = isCurrent
            ? NSColor.separatorColor.withAlphaComponent(0.14)
            : NSColor.clear
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderWidth = 0
        layer?.borderColor = nil
    }

    private func makeFlexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    @objc
    private func handleActivate() {
        guard let accountID else { return }
        onActivate?(accountID)
    }

    @objc
    private func handleRename() {
        guard let accountID else { return }
        onRename?(accountID)
    }

    @objc
    private func handleForget() {
        guard let accountID else { return }
        onForget?(accountID)
    }
}
