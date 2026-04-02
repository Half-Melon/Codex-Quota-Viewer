import AppKit

struct AccountMenuRowModel {
    let name: String
    let primaryRemainingText: String
    let secondaryRemainingText: String
    let primaryResetText: String
    let secondaryResetText: String
    let indicatorColor: NSColor
    let isCurrent: Bool
    let isEnabled: Bool
    let accessibilityLabel: String
}

@MainActor
final class AccountMenuRowView: NSView {
    static let minimumWidth: CGFloat = 372
    static let height: CGFloat = 52
    private static let cardInset: CGFloat = 3
    private static let horizontalPadding: CGFloat = 12
    private static let quotaColumnWidth: CGFloat = 74
    private static let quotaColumnSpacing: CGFloat = 8

    private let cardView = NSView()
    private let indicatorView = AccountStatusDotView()
    private let nameField = NSTextField(labelWithString: "")
    private let primaryRemainingField = NSTextField(labelWithString: "")
    private let secondaryRemainingField = NSTextField(labelWithString: "")
    private let primaryResetField = NSTextField(labelWithString: "")
    private let secondaryResetField = NSTextField(labelWithString: "")

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

    override func resetCursorRects() {
        super.resetCursorRects()

        if model.isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
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
        primaryRemainingField.stringValue = model.primaryRemainingText
        secondaryRemainingField.stringValue = model.secondaryRemainingText
        primaryResetField.stringValue = model.primaryResetText
        secondaryResetField.stringValue = model.secondaryResetText
        indicatorView.fillColor = model.indicatorColor
        nameField.font = .systemFont(ofSize: 13, weight: .regular)
        alphaValue = 1
        updateAppearance()
        window?.invalidateCursorRects(for: self)
        setAccessibilityLabel(model.accessibilityLabel)
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

        [primaryRemainingField, secondaryRemainingField, primaryResetField, secondaryResetField].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            $0.textColor = .secondaryLabelColor
            $0.alignment = .right
            $0.maximumNumberOfLines = 1
            addSubview($0)
        }

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

            secondaryRemainingField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            secondaryRemainingField.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 8),
            secondaryRemainingField.widthAnchor.constraint(equalToConstant: Self.quotaColumnWidth),

            primaryRemainingField.trailingAnchor.constraint(
                equalTo: secondaryRemainingField.leadingAnchor,
                constant: -Self.quotaColumnSpacing
            ),
            primaryRemainingField.topAnchor.constraint(equalTo: secondaryRemainingField.topAnchor),
            primaryRemainingField.widthAnchor.constraint(equalToConstant: Self.quotaColumnWidth),

            secondaryResetField.trailingAnchor.constraint(equalTo: secondaryRemainingField.trailingAnchor),
            secondaryResetField.topAnchor.constraint(equalTo: secondaryRemainingField.bottomAnchor, constant: 4),
            secondaryResetField.widthAnchor.constraint(equalTo: secondaryRemainingField.widthAnchor),

            primaryResetField.trailingAnchor.constraint(equalTo: primaryRemainingField.trailingAnchor),
            primaryResetField.topAnchor.constraint(equalTo: secondaryResetField.topAnchor),
            primaryResetField.widthAnchor.constraint(equalTo: primaryRemainingField.widthAnchor),

            nameField.leadingAnchor.constraint(equalTo: indicatorView.trailingAnchor, constant: 10),
            nameField.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 7),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: primaryRemainingField.leadingAnchor, constant: -12),
        ])
    }

    private func updateAppearance() {
        let backgroundColor: NSColor
        let borderColor: NSColor?
        let borderWidth: CGFloat

        if model.isCurrent {
            backgroundColor = isHovered && model.isEnabled
                ? NSColor.separatorColor.withAlphaComponent(0.24)
                : NSColor.separatorColor.withAlphaComponent(0.16)
            borderColor = isHovered && model.isEnabled
                ? NSColor.separatorColor.withAlphaComponent(0.35)
                : nil
            borderWidth = borderColor == nil ? 0 : 1
        } else if model.isEnabled && isHovered {
            backgroundColor = NSColor.separatorColor.withAlphaComponent(0.08)
            borderColor = NSColor.separatorColor.withAlphaComponent(0.18)
            borderWidth = 1
        } else {
            backgroundColor = .clear
            borderColor = nil
            borderWidth = 0
        }

        cardView.layer?.backgroundColor = backgroundColor.cgColor
        cardView.layer?.borderColor = borderColor?.cgColor
        cardView.layer?.borderWidth = borderWidth
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
