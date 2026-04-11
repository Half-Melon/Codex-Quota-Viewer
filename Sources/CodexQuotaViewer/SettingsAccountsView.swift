import AppKit
import Foundation

@MainActor
final class SettingsAccountsView: NSView {
    let headerView = NSView()
    let scrollView = NSScrollView()
    let tableView = NSTableView()
    let importStatusLabel = NSTextField(labelWithString: "")
    let addChatGPTButton = NSButton(title: "", target: nil, action: nil)
    let addAPIButton = NSButton(title: "", target: nil, action: nil)
    let openVaultButton = NSButton(title: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyLocalizedText() {
        addChatGPTButton.title = AppLocalization.localized(en: "Sign in with ChatGPT", zh: "使用 ChatGPT 登录")
        addAPIButton.title = AppLocalization.localized(en: "Add API Account", zh: "添加 API 账号")
        openVaultButton.title = AppLocalization.localized(en: "Open Vault Folder", zh: "打开账号仓文件夹")
    }

    private func setupUI() {
        headerView.identifier = NSUserInterfaceItemIdentifier("settings.accounts.header")
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.wantsLayer = true
        headerView.layer?.cornerRadius = 12
        headerView.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.06).cgColor
        addSubview(headerView)

        scrollView.identifier = NSUserInterfaceItemIdentifier("settings.accounts.scroll")
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = tableView
        addSubview(scrollView)

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
        importStatusLabel.maximumNumberOfLines = 0
        importStatusLabel.lineBreakMode = .byWordWrapping
        importStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView(views: [buttonRow, importStatusLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 10
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(headerStack)

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.topAnchor.constraint(equalTo: topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            headerStack.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            headerStack.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 16),
            headerStack.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -16),
            buttonRow.widthAnchor.constraint(equalTo: headerStack.widthAnchor),
            importStatusLabel.widthAnchor.constraint(equalTo: headerStack.widthAnchor),
        ])
    }
}
