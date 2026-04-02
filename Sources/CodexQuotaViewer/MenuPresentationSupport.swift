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
        .sorted { lhs, rhs in
            let lhsLastUsed = lhs.lastUsedAt ?? .distantPast
            let rhsLastUsed = rhs.lastUsedAt ?? .distantPast
            if lhsLastUsed != rhsLastUsed {
                return lhsLastUsed > rhsLastUsed
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
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

private func settingsAccountSortComparator(
    lhs: SettingsAccountPresentationInput,
    rhs: SettingsAccountPresentationInput
) -> Bool {
    if lhs.state != rhs.state {
        return lhs.state.rawValue < rhs.state.rawValue
    }

    let lhsLastUsed = lhs.lastUsedAt ?? .distantPast
    let rhsLastUsed = rhs.lastUsedAt ?? .distantPast
    if lhsLastUsed != rhsLastUsed {
        return lhsLastUsed > rhsLastUsed
    }

    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
}

private func makeSettingsAccountItem(
    from input: SettingsAccountPresentationInput
) -> SettingsAccountItem {
    let stateLabel = localizedSettingsAccountStateLabel(input.state)
    let subtitle: String
    if input.authMode == .apiKey {
        subtitle = [
            stateLabel,
            AppLocalization.localized(en: "API Key", zh: "API 密钥"),
            AppLocalization.localized(en: "Local vault", zh: "本地账号仓"),
            input.host,
            input.model,
        ]
        .compactMap { value -> String? in
            guard let value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return value
        }
        .joined(separator: " · ")
    } else {
        subtitle = [
            stateLabel,
            AppLocalization.localized(en: "ChatGPT", zh: "ChatGPT"),
            AppLocalization.localized(en: "Local vault", zh: "本地账号仓"),
        ]
        .joined(separator: " · ")
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
