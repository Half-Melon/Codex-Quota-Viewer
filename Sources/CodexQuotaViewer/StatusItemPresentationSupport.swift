import AppKit
import Foundation

enum StatusItemVisualContent: Equatable {
    case brand
    case meter(primaryRemaining: Double, secondaryRemaining: Double, state: MeterIconState)
}

struct StatusItemPresentation: Equatable {
    let title: String
    let visualContent: StatusItemVisualContent
    let imagePosition: NSControl.ImagePosition
    let imageScaling: NSImageScaling
    let statusItemLength: CGFloat
    let accessibilityDescription: String
}

func buildStatusItemPresentation(
    snapshot: CodexSnapshot?,
    apiKeyDetails: APIKeyProfileDetails?,
    statusItemStyle: StatusItemStyle,
    refreshIntervalPreset: RefreshIntervalPreset,
    isRefreshing: Bool,
    currentError: String?,
    lastRefreshAt: Date?,
    now: Date = Date()
) -> StatusItemPresentation {
    let summary = statusItemSummaryText(
        snapshot: snapshot,
        apiKeyDetails: apiKeyDetails,
        isRefreshing: isRefreshing,
        currentError: currentError
    )
    let isStale = isSnapshotDataStale(
        lastRefreshAt: lastRefreshAt,
        refreshIntervalPreset: refreshIntervalPreset,
        now: now
    )
    let visualContent: StatusItemVisualContent

    switch statusItemStyle {
    case .text:
        visualContent = .brand
    case .meter:
        if snapshot?.account.type == "apiKey" {
            visualContent = .brand
        } else {
            let windows = quotaDisplayWindows(from: snapshot)
            let primaryRemaining = windows.first?.window.remainingPercent ?? 0
            let secondaryRemaining = windows.dropFirst().first?.window.remainingPercent ?? 0
            let state: MeterIconState
            if currentError != nil {
                state = .degraded
            } else if isStale {
                state = .stale
            } else {
                state = .normal
            }

            visualContent = .meter(
                primaryRemaining: primaryRemaining / 100,
                secondaryRemaining: secondaryRemaining / 100,
                state: state
            )
        }
    }

    let accessibilityDescription = statusItemAccessibilityDescription(
        summary: summary,
        style: statusItemStyle,
        isStale: isStale
    )

    return StatusItemPresentation(
        title: statusItemStyle == .text ? summary : "",
        visualContent: visualContent,
        imagePosition: statusItemStyle == .text ? .imageLeading : .imageOnly,
        imageScaling: statusItemStyle == .text ? .scaleNone : .scaleProportionallyUpOrDown,
        statusItemLength: statusItemStyle == .text ? NSStatusItem.variableLength : NSStatusItem.squareLength,
        accessibilityDescription: accessibilityDescription
    )
}

@MainActor
func applyStatusItemPresentation(
    _ presentation: StatusItemPresentation,
    to button: NSStatusBarButton,
    statusItem: NSStatusItem,
    renderer: StatusItemRenderer
) {
    switch presentation.visualContent {
    case .brand:
        button.image = renderer.makeBrandImage(for: button.effectiveAppearance)
    case .meter(let primaryRemaining, let secondaryRemaining, let state):
        button.image = renderer.makeMeterImage(
            primaryRemaining: primaryRemaining,
            secondaryRemaining: secondaryRemaining,
            state: state
        )
    }

    button.title = presentation.title
    button.imagePosition = presentation.imagePosition
    button.imageScaling = presentation.imageScaling
    statusItem.length = presentation.statusItemLength
    button.toolTip = presentation.accessibilityDescription
    button.setAccessibilityLabel(presentation.accessibilityDescription)
}

func statusItemSummaryText(
    snapshot: CodexSnapshot?,
    apiKeyDetails: APIKeyProfileDetails?,
    isRefreshing: Bool,
    currentError: String?
) -> String {
    if let snapshot {
        if snapshot.account.type == "apiKey" {
            return apiKeyStatusTexts(details: apiKeyDetails).0
        }

        let windows = quotaDisplayWindows(from: snapshot)
        guard !windows.isEmpty else {
            return AppLocalization.statusPlaceholderSummary()
        }
        return windows.map(compactWindowSummary).joined(separator: " ")
    }

    if isRefreshing {
        return AppLocalization.localized(en: "Refreshing", zh: "刷新中")
    }

    if currentError != nil {
        return AppLocalization.localized(en: "Read failed", zh: "读取失败")
    }

    return AppLocalization.statusPlaceholderSummary()
}

func compactWindowSummary(_ quotaWindow: QuotaDisplayWindow) -> String {
    "\(quotaWindow.label)\(quotaWindow.window.remainingPercentText)"
}
