import Foundation

struct MenuTrackingGate {
    private(set) var isTracking = false
    private(set) var hasPendingRebuild = false

    mutating func beginTracking() {
        isTracking = true
    }

    @discardableResult
    mutating func requestRebuild() -> Bool {
        guard isTracking else {
            return true
        }

        hasPendingRebuild = true
        return false
    }

    @discardableResult
    mutating func finishTracking() -> Bool {
        let shouldRebuild = hasPendingRebuild
        isTracking = false
        hasPendingRebuild = false
        return shouldRebuild
    }
}

enum DeferredMenuPresentation: Equatable {
    case settings
}

struct DeferredMenuPresentationQueue {
    private(set) var actions: [DeferredMenuPresentation] = []

    mutating func enqueue(_ action: DeferredMenuPresentation) {
        guard !actions.contains(action) else {
            return
        }
        actions.append(action)
    }

    mutating func drain() -> [DeferredMenuPresentation] {
        let drained = actions
        actions.removeAll()
        return drained
    }
}

enum SettingsAccountState: Int, Equatable {
    case healthy = 0
    case limited = 1
    case attention = 2
}

struct SettingsAccountPresentationInput: Equatable {
    let id: String
    let title: String
    let authMode: CodexAuthMode
    let state: SettingsAccountState
    let isCurrent: Bool
    let lastUsedAt: Date?
    let host: String?
    let model: String?
}

struct SettingsAccountItem: Equatable {
    let id: String
    let title: String
    let subtitle: String
    let isCurrent: Bool
    let canActivate: Bool
    let canRename: Bool
    let canForget: Bool
}

struct SettingsAccountSection: Equatable {
    let title: String
    let items: [SettingsAccountItem]
}

struct SettingsAccountPanelState: Equatable {
    let importStatusText: String
    let sections: [SettingsAccountSection]
    let actionsEnabled: Bool
}

struct AllAccountsMenuItemPresentation: Equatable {
    let title: String
    let showsCheckmark: Bool
    let isEnabled: Bool
    let triggersDirectSwitch: Bool
}

struct QuotaOverviewMenuItemPresentation: Equatable {
    let title: String
    let showsCheckmark: Bool
    let isEnabled: Bool
    let triggersDirectSwitch: Bool
    let accessibilityLabel: String
}

struct QuotaOverviewRowPresentation: Equatable {
    let name: String
    let primaryRemainingText: String
    let secondaryRemainingText: String
    let primaryResetText: String
    let secondaryResetText: String
    let state: QuotaTileState
    let isCurrent: Bool
    let isEnabled: Bool
    let triggersDirectSwitch: Bool
    let accessibilityLabel: String
}

func buildSettingsAccountSections(
    _ inputs: [SettingsAccountPresentationInput]
) -> [SettingsAccountSection] {
    let currentItems = inputs
        .filter(\.isCurrent)
        .sorted(by: settingsAccountSortComparator)
        .map(makeSettingsAccountItem)
    let chatGPTItems = inputs
        .filter { !$0.isCurrent && $0.authMode != .apiKey }
        .sorted(by: settingsAccountSortComparator)
        .map(makeSettingsAccountItem)
    let apiItems = inputs
        .filter { !$0.isCurrent && $0.authMode == .apiKey }
        .sorted {
            profileLastUsedComparator(
                lhsLastUsedAt: $0.lastUsedAt,
                lhsDisplayName: $0.title,
                rhsLastUsedAt: $1.lastUsedAt,
                rhsDisplayName: $1.title
            )
        }
        .map(makeSettingsAccountItem)

    var sections: [SettingsAccountSection] = []
    if !currentItems.isEmpty {
        sections.append(
            SettingsAccountSection(
                title: AppLocalization.sectionTitle(
                    en: "Current Account",
                    zh: "当前账号",
                    count: currentItems.count
                ),
                items: currentItems
            )
        )
    }
    if !chatGPTItems.isEmpty {
        sections.append(
            SettingsAccountSection(
                title: AppLocalization.sectionTitle(
                    en: "ChatGPT Accounts",
                    zh: "ChatGPT 账号",
                    count: chatGPTItems.count
                ),
                items: chatGPTItems
            )
        )
    }
    if !apiItems.isEmpty {
        sections.append(
            SettingsAccountSection(
                title: AppLocalization.sectionTitle(
                    en: "API Accounts",
                    zh: "API 账号",
                    count: apiItems.count
                ),
                items: apiItems
            )
        )
    }
    return sections
}

func buildAllAccountsMenuItemPresentation(
    for profile: ProviderProfile,
    refreshIntervalPreset: RefreshIntervalPreset,
    now: Date = Date(),
    isPerformingSafeSwitchOperation: Bool
) -> AllAccountsMenuItemPresentation {
    let isCurrent = profile.isCurrent
    return AllAccountsMenuItemPresentation(
        title: allAccountsMenuText(
            for: profile,
            refreshIntervalPreset: refreshIntervalPreset,
            now: now
        ),
        showsCheckmark: isCurrent,
        isEnabled: isCurrent || !isPerformingSafeSwitchOperation,
        triggersDirectSwitch: !isCurrent && !isPerformingSafeSwitchOperation
    )
}

func buildQuotaOverviewMenuItemPresentation(
    for tile: QuotaTileViewModel,
    isPerformingSafeSwitchOperation: Bool
) -> QuotaOverviewMenuItemPresentation {
    let usageSummary = joinedNonEmptyParts([tile.primaryText, tile.secondaryText])
    let title = usageSummary.isEmpty
        ? tile.profile.displayName
        : "\(tile.profile.displayName) · \(usageSummary)"
    let accessibilityLabel = tile.profile.isCurrent
        ? AppLocalization.localized(
            en: "Current account, \(title)",
            zh: "当前账号，\(title)"
        )
        : title

    return QuotaOverviewMenuItemPresentation(
        title: title,
        showsCheckmark: tile.profile.isCurrent,
        isEnabled: tile.profile.isCurrent || !isPerformingSafeSwitchOperation,
        triggersDirectSwitch: !tile.profile.isCurrent && !isPerformingSafeSwitchOperation,
        accessibilityLabel: accessibilityLabel
    )
}

func buildQuotaOverviewRowPresentation(
    for tile: QuotaTileViewModel,
    isPerformingSafeSwitchOperation: Bool
) -> QuotaOverviewRowPresentation {
    let quotaTexts = quotaOverviewRowQuotaTexts(for: tile.profile)
    let summary = joinedNonEmptyParts([
        quotaTexts.primaryRemainingText,
        quotaTexts.secondaryRemainingText,
        quotaTexts.primaryResetText,
        quotaTexts.secondaryResetText,
    ])
    let accessibilityLabel = tile.profile.isCurrent
        ? AppLocalization.localized(
            en: "Current account, \(tile.profile.displayName), \(summary)",
            zh: "当前账号，\(tile.profile.displayName)，\(summary)"
        )
        : joinedNonEmptyParts([tile.profile.displayName, summary], separator: ", ")

    return QuotaOverviewRowPresentation(
        name: tile.profile.displayName,
        primaryRemainingText: quotaTexts.primaryRemainingText,
        secondaryRemainingText: quotaTexts.secondaryRemainingText,
        primaryResetText: quotaTexts.primaryResetText,
        secondaryResetText: quotaTexts.secondaryResetText,
        state: tile.state,
        isCurrent: tile.profile.isCurrent,
        isEnabled: !tile.profile.isCurrent && !isPerformingSafeSwitchOperation,
        triggersDirectSwitch: !tile.profile.isCurrent && !isPerformingSafeSwitchOperation,
        accessibilityLabel: accessibilityLabel
    )
}

func quotaOverviewEmptyStateMessage(for state: QuotaOverviewState?) -> String {
    guard let state else {
        return AppLocalization.localized(en: "No saved accounts", zh: "暂无已保存账号")
    }

    if state.hasProfiles {
        if state.isAPIOnly {
            return AppLocalization.localized(
                en: "API accounts do not expose official quota. Open All Accounts below.",
                zh: "API 账号不提供官方额度信息，请在下方“全部账号”中查看。"
            )
        }

        return AppLocalization.localized(
            en: "Quota cards are unavailable for the saved accounts. Open All Accounts below.",
            zh: "当前无法显示额度卡片，请在下方“全部账号”中查看。"
        )
    }

    return AppLocalization.localized(en: "No saved accounts", zh: "暂无已保存账号")
}

func statusItemAccessibilityDescription(
    summary: String,
    style: StatusItemStyle,
    isStale: Bool
) -> String {
    let prefix = switch style {
    case .meter:
        AppLocalization.localized(en: "Quota meter", zh: "额度仪表")
    case .text:
        AppLocalization.localized(en: "Quota status", zh: "额度状态")
    }

    let staleSuffix = isStale
        ? AppLocalization.localized(en: "Data may be stale", zh: "数据可能已过期")
        : nil

    return joinedNonEmptyParts([prefix, summary, staleSuffix])
}

private func settingsAccountSortComparator(
    lhs: SettingsAccountPresentationInput,
    rhs: SettingsAccountPresentationInput
) -> Bool {
    if lhs.state != rhs.state {
        return lhs.state.rawValue < rhs.state.rawValue
    }

    let lhsLastUsed = lhs.lastUsedAt ?? .distantPast
    let rhsLastUsed = rhs.lastUsedAt ?? .distantPast
    return profileLastUsedComparator(
        lhsLastUsedAt: lhsLastUsed,
        lhsDisplayName: lhs.title,
        rhsLastUsedAt: rhsLastUsed,
        rhsDisplayName: rhs.title
    )
}

private func makeSettingsAccountItem(
    from input: SettingsAccountPresentationInput
) -> SettingsAccountItem {
    let stateLabel = localizedSettingsAccountStateLabel(input.state)
    let subtitle: String
    if input.authMode == .apiKey {
        subtitle = joinedNonEmptyParts([
            stateLabel,
            AppLocalization.localized(en: "API Key", zh: "API 密钥"),
            AppLocalization.localized(en: "Local vault", zh: "本地账号仓"),
            input.host,
            input.model,
        ])
    } else {
        subtitle = joinedNonEmptyParts([
            stateLabel,
            AppLocalization.localized(en: "ChatGPT", zh: "ChatGPT"),
            AppLocalization.localized(en: "Local vault", zh: "本地账号仓"),
        ])
    }

    return SettingsAccountItem(
        id: input.id,
        title: input.title,
        subtitle: subtitle,
        isCurrent: input.isCurrent,
        canActivate: !input.isCurrent,
        canRename: true,
        canForget: !input.isCurrent
    )
}

private func localizedSettingsAccountStateLabel(_ state: SettingsAccountState) -> String {
    switch state {
    case .healthy:
        return AppLocalization.localized(en: "Healthy", zh: "正常")
    case .limited:
        return AppLocalization.localized(en: "Limited", zh: "受限")
    case .attention:
        return AppLocalization.localized(en: "Needs attention", zh: "需要关注")
    }
}
