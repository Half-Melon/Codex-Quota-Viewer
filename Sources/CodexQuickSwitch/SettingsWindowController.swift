import AppKit
import Foundation

@MainActor
final class SettingsWindowController: NSWindowController {
    var onSettingsChanged: ((AppSettings) -> Void)?

    private var settings: AppSettings

    private let refreshPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "开机自动启动", target: nil, action: nil)
    private let iconStylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let autoOpenCheckbox = NSButton(checkboxWithTitle: "切换后自动打开 Codex 主窗口", target: nil, action: nil)

    init(settings: AppSettings) {
        self.settings = settings

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.center()

        super.init(window: window)
        setupUI()
        applySettingsToControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(settings: AppSettings) {
        self.settings = settings
        applySettingsToControls()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        refreshPopup.target = self
        refreshPopup.action = #selector(controlChanged)
        RefreshIntervalPreset.allCases.forEach { preset in
            refreshPopup.addItem(withTitle: preset.displayName)
            refreshPopup.lastItem?.representedObject = preset.rawValue
        }

        iconStylePopup.target = self
        iconStylePopup.action = #selector(controlChanged)
        StatusItemStyle.allCases.forEach { style in
            iconStylePopup.addItem(withTitle: style.displayName)
            iconStylePopup.lastItem?.representedObject = style.rawValue
        }

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(controlChanged)
        autoOpenCheckbox.target = self
        autoOpenCheckbox.action = #selector(controlChanged)

        let hint = NSTextField(labelWithString: "修改立即生效。")
        hint.textColor = .secondaryLabelColor

        stack.addArrangedSubview(makeRow(title: "刷新频率", control: refreshPopup))
        stack.addArrangedSubview(makeRow(title: "图标样式", control: iconStylePopup))
        stack.addArrangedSubview(launchAtLoginCheckbox)
        stack.addArrangedSubview(autoOpenCheckbox)
        stack.addArrangedSubview(hint)

        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
        ])
    }

    private func makeRow(title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 84).isActive = true

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func applySettingsToControls() {
        selectItem(in: refreshPopup, matching: settings.refreshIntervalPreset.rawValue)
        selectItem(in: iconStylePopup, matching: settings.statusItemStyle.rawValue)
        launchAtLoginCheckbox.state = settings.launchAtLoginEnabled ? .on : .off
        autoOpenCheckbox.state = settings.autoOpenCodexAfterSwitch ? .on : .off
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

        if let rawValue = iconStylePopup.selectedItem?.representedObject as? String,
           let style = StatusItemStyle(rawValue: rawValue) {
            settings.statusItemStyle = style
        }

        settings.launchAtLoginEnabled = launchAtLoginCheckbox.state == .on
        settings.autoOpenCodexAfterSwitch = autoOpenCheckbox.state == .on
        onSettingsChanged?(settings)
    }
}
