import AppKit
import Foundation

@MainActor
final class SettingsGeneralView: NSView {
    let refreshPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let iconStylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let sectionTitleLabel = NSTextField(labelWithString: "")
    let refreshRowLabel = NSTextField(labelWithString: "")
    let languageRowLabel = NSTextField(labelWithString: "")
    let iconStyleRowLabel = NSTextField(labelWithString: "")

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
        sectionTitleLabel.stringValue = AppLocalization.localized(en: "General", zh: "通用")
        refreshRowLabel.stringValue = AppLocalization.localized(en: "Refresh interval", zh: "刷新频率")
        languageRowLabel.stringValue = AppLocalization.localized(en: "Language", zh: "语言")
        iconStyleRowLabel.stringValue = AppLocalization.localized(en: "Menu bar style", zh: "状态栏样式")
        launchAtLoginCheckbox.title = AppLocalization.localized(en: "Launch at login", zh: "登录时启动")
    }

    private func setupUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        sectionTitleLabel.identifier = NSUserInterfaceItemIdentifier("settings.general.section")
        refreshRowLabel.identifier = NSUserInterfaceItemIdentifier("settings.general.refresh")
        languageRowLabel.identifier = NSUserInterfaceItemIdentifier("settings.general.language")
        iconStyleRowLabel.identifier = NSUserInterfaceItemIdentifier("settings.general.icon-style")

        stack.addArrangedSubview(makeSectionTitleLabel(sectionTitleLabel))
        stack.addArrangedSubview(makeRow(label: refreshRowLabel, control: refreshPopup))
        stack.addArrangedSubview(makeRow(label: languageRowLabel, control: languagePopup))
        stack.addArrangedSubview(makeRow(label: iconStyleRowLabel, control: iconStylePopup))
        stack.addArrangedSubview(launchAtLoginCheckbox)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
        ])
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
}
