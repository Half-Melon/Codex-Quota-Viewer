import AppKit

struct AccountMenuRowModel {
    let profileID: UUID
    let name: String
    let primaryUsageText: String
    let secondaryUsageText: String
    let indicatorColor: NSColor
    let isCurrent: Bool
    let isEnabled: Bool
}

@MainActor
final class AccountMenuRowView: NSView {
    static let minimumWidth: CGFloat = 308
    static let height: CGFloat = 50
    private static let cardInset: CGFloat = 3
    private static let horizontalPadding: CGFloat = 12
    private static let trailingColumnWidth: CGFloat = 118

    private let cardView = NSView()
    private let indicatorView = AccountStatusDotView()
    private let nameField = NSTextField(labelWithString: "")
    private let primaryUsageField = NSTextField(labelWithString: "")
    private let secondaryUsageField = NSTextField(labelWithString: "")

    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false {
        didSet {
            updateAppearance()
        }
    }

    private(set) var model: AccountMenuRowModel

    init(model: AccountMenuRowModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: Self.height))
        setupView()
        apply(model: model)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.minimumWidth, height: Self.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        guard model.isEnabled else { return }
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseUp(with event: NSEvent) {
        guard model.isEnabled else { return }

        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location),
              let menuItem = enclosingMenuItem,
              let action = menuItem.action else {
            return
        }

        menuItem.menu?.cancelTracking()
        NSApp.sendAction(action, to: menuItem.target, from: menuItem)
    }

    func apply(model: AccountMenuRowModel) {
        self.model = model
        nameField.stringValue = model.name
        primaryUsageField.stringValue = model.primaryUsageText
        secondaryUsageField.stringValue = model.secondaryUsageText
        indicatorView.fillColor = model.indicatorColor
        nameField.font = .systemFont(ofSize: 13, weight: .regular)
        alphaValue = model.isEnabled ? 1 : 0.48
        updateAppearance()
        setAccessibilityLabel("\(model.name) \(model.primaryUsageText) \(model.secondaryUsageText)")
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 10
        addSubview(cardView)

        indicatorView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indicatorView)

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.textColor = .labelColor
        addSubview(nameField)

        primaryUsageField.translatesAutoresizingMaskIntoConstraints = false
        primaryUsageField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        primaryUsageField.textColor = .secondaryLabelColor
        primaryUsageField.alignment = .right
        primaryUsageField.maximumNumberOfLines = 1
        addSubview(primaryUsageField)

        secondaryUsageField.translatesAutoresizingMaskIntoConstraints = false
        secondaryUsageField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        secondaryUsageField.textColor = .secondaryLabelColor
        secondaryUsageField.alignment = .right
        secondaryUsageField.maximumNumberOfLines = 1
        addSubview(secondaryUsageField)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth),
            heightAnchor.constraint(equalToConstant: Self.height),

            cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardView.topAnchor.constraint(equalTo: topAnchor, constant: Self.cardInset),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.cardInset),

            indicatorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            indicatorView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),
            indicatorView.widthAnchor.constraint(equalToConstant: 8),
            indicatorView.heightAnchor.constraint(equalToConstant: 8),

            primaryUsageField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            primaryUsageField.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 9),
            primaryUsageField.widthAnchor.constraint(equalToConstant: Self.trailingColumnWidth),

            secondaryUsageField.trailingAnchor.constraint(equalTo: primaryUsageField.trailingAnchor),
            secondaryUsageField.topAnchor.constraint(equalTo: primaryUsageField.bottomAnchor, constant: 3),
            secondaryUsageField.widthAnchor.constraint(equalTo: primaryUsageField.widthAnchor),

            nameField.leadingAnchor.constraint(equalTo: indicatorView.trailingAnchor, constant: 10),
            nameField.centerYAnchor.constraint(equalTo: indicatorView.centerYAnchor),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: primaryUsageField.leadingAnchor, constant: -12),
        ])
    }

    private func updateAppearance() {
        let backgroundColor: NSColor

        if model.isCurrent {
            backgroundColor = isHovered && model.isEnabled
                ? NSColor.separatorColor.withAlphaComponent(0.24)
                : NSColor.separatorColor.withAlphaComponent(0.16)
        } else {
            backgroundColor = .clear
        }

        cardView.layer?.backgroundColor = backgroundColor.cgColor
        cardView.layer?.borderColor = nil
        cardView.layer?.borderWidth = 0
    }
}

private final class AccountStatusDotView: NSView {
    var fillColor: NSColor = .systemGreen {
        didSet {
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 8, height: 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        fillColor.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
