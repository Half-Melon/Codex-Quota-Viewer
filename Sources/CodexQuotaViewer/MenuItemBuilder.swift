import AppKit
import Foundation

@MainActor
func buildQuotaOverviewMenuItems(
    quotaOverviewState: QuotaOverviewState?,
    refreshIntervalPreset: RefreshIntervalPreset,
    isPerformingSafeSwitchOperation: Bool,
    target: AnyObject?,
    activateSavedAccountAction: Selector
) -> [NSMenuItem] {
    var items: [NSMenuItem] = []

    if let quotaOverviewState,
       !quotaOverviewState.boardTiles.isEmpty {
        items.append(
            contentsOf: quotaOverviewState.boardTiles.map { tile in
                let presentation = buildQuotaOverviewRowPresentation(
                    for: tile,
                    isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation
                )
                return makeQuotaOverviewRowItem(
                    tileID: tile.profile.id,
                    presentation: presentation,
                    target: target,
                    activateSavedAccountAction: activateSavedAccountAction
                )
            }
        )
    } else {
        let item = NSMenuItem(
            title: quotaOverviewEmptyStateMessage(for: quotaOverviewState),
            action: nil,
            keyEquivalent: ""
        )
        item.isEnabled = false
        items.append(item)
    }

    let allAccountsItem = NSMenuItem(
        title: AppLocalization.localized(en: "All Accounts", zh: "全部账号"),
        action: nil,
        keyEquivalent: ""
    )
    allAccountsItem.submenu = buildAllAccountsMenu(
        quotaOverviewState: quotaOverviewState,
        refreshIntervalPreset: refreshIntervalPreset,
        isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation,
        target: target,
        activateSavedAccountAction: activateSavedAccountAction
    )
    items.append(allAccountsItem)

    return items
}

@MainActor
func reconcileQuotaOverviewMenuItemsInPlace(
    _ existingItems: [NSMenuItem],
    quotaOverviewState: QuotaOverviewState?,
    refreshIntervalPreset: RefreshIntervalPreset,
    isPerformingSafeSwitchOperation: Bool,
    target: AnyObject?,
    activateSavedAccountAction: Selector
) -> Bool {
    if let quotaOverviewState,
       !quotaOverviewState.boardTiles.isEmpty {
        guard existingItems.count == quotaOverviewState.boardTiles.count + 1 else {
            return false
        }

        for (index, tile) in quotaOverviewState.boardTiles.enumerated() {
            let presentation = buildQuotaOverviewRowPresentation(
                for: tile,
                isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation
            )
            let item = existingItems[index]
            guard let rowView = item.view as? AccountMenuRowView else {
                return false
            }

            item.title = presentation.name
            item.action = presentation.triggersDirectSwitch ? activateSavedAccountAction : nil
            item.target = target
            item.representedObject = tile.profile.id
            item.isEnabled = presentation.isEnabled
            item.toolTip = presentation.accessibilityLabel
            rowView.apply(model: quotaOverviewRowModel(from: presentation))
        }

        let allAccountsItem = existingItems[quotaOverviewState.boardTiles.count]
        configureAllAccountsItem(
            allAccountsItem,
            quotaOverviewState: quotaOverviewState,
            refreshIntervalPreset: refreshIntervalPreset,
            isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation,
            target: target,
            activateSavedAccountAction: activateSavedAccountAction
        )
        return true
    }

    guard existingItems.count == 2 else {
        return false
    }

    let emptyStateItem = existingItems[0]
    guard emptyStateItem.view == nil else {
        return false
    }
    emptyStateItem.title = quotaOverviewEmptyStateMessage(for: quotaOverviewState)
    emptyStateItem.action = nil
    emptyStateItem.target = nil
    emptyStateItem.representedObject = nil
    emptyStateItem.isEnabled = false
    emptyStateItem.toolTip = nil

    configureAllAccountsItem(
        existingItems[1],
        quotaOverviewState: quotaOverviewState,
        refreshIntervalPreset: refreshIntervalPreset,
        isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation,
        target: target,
        activateSavedAccountAction: activateSavedAccountAction
    )
    return true
}

@MainActor
private func makeQuotaOverviewRowItem(
    tileID: String,
    presentation: QuotaOverviewRowPresentation,
    target: AnyObject?,
    activateSavedAccountAction: Selector
) -> NSMenuItem {
    let item = NSMenuItem(
        title: presentation.name,
        action: presentation.triggersDirectSwitch ? activateSavedAccountAction : nil,
        keyEquivalent: ""
    )
    item.target = target
    item.representedObject = tileID
    item.isEnabled = presentation.isEnabled
    item.toolTip = presentation.accessibilityLabel
    item.view = AccountMenuRowView(model: quotaOverviewRowModel(from: presentation))
    return item
}

private func quotaOverviewRowModel(
    from presentation: QuotaOverviewRowPresentation
) -> AccountMenuRowModel {
    AccountMenuRowModel(
        name: presentation.name,
        primaryRemainingText: presentation.primaryRemainingText,
        secondaryRemainingText: presentation.secondaryRemainingText,
        primaryResetText: presentation.primaryResetText,
        secondaryResetText: presentation.secondaryResetText,
        indicatorColor: quotaOverviewIndicatorColor(for: presentation.state),
        isCurrent: presentation.isCurrent,
        isEnabled: presentation.isEnabled,
        accessibilityLabel: presentation.accessibilityLabel
    )
}

@MainActor
private func configureAllAccountsItem(
    _ item: NSMenuItem,
    quotaOverviewState: QuotaOverviewState?,
    refreshIntervalPreset: RefreshIntervalPreset,
    isPerformingSafeSwitchOperation: Bool,
    target: AnyObject?,
    activateSavedAccountAction: Selector
) {
    item.title = AppLocalization.localized(en: "All Accounts", zh: "全部账号")
    item.action = nil
    item.target = nil
    item.representedObject = nil
    item.isEnabled = true
    item.toolTip = nil
    item.view = nil
    item.submenu = buildAllAccountsMenu(
        quotaOverviewState: quotaOverviewState,
        refreshIntervalPreset: refreshIntervalPreset,
        isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation,
        target: target,
        activateSavedAccountAction: activateSavedAccountAction
    )
}

private func quotaOverviewIndicatorColor(for state: QuotaTileState) -> NSColor {
    switch state {
    case .healthy:
        return .systemGreen
    case .lowQuota:
        return .systemYellow
    case .stale:
        return .systemOrange
    case .signInRequired, .expired, .readFailure:
        return .systemRed
    }
}

@MainActor
func buildAllAccountsMenu(
    quotaOverviewState: QuotaOverviewState?,
    refreshIntervalPreset: RefreshIntervalPreset,
    isPerformingSafeSwitchOperation: Bool,
    target: AnyObject?,
    activateSavedAccountAction: Selector
) -> NSMenu {
    let submenu = NSMenu()

    guard let quotaOverviewState,
          !quotaOverviewState.sections.isEmpty else {
        let emptyItem = NSMenuItem(
            title: AppLocalization.localized(en: "No saved accounts", zh: "暂无已保存账号"),
            action: nil,
            keyEquivalent: ""
        )
        emptyItem.isEnabled = false
        submenu.addItem(emptyItem)
        return submenu
    }

    for (sectionIndex, section) in quotaOverviewState.sections.enumerated() {
        let header = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        submenu.addItem(header)

        for profile in section.profiles {
            let presentation = buildAllAccountsMenuItemPresentation(
                for: profile,
                refreshIntervalPreset: refreshIntervalPreset,
                isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation
            )
            let item = NSMenuItem(
                title: presentation.title,
                action: presentation.triggersDirectSwitch ? activateSavedAccountAction : nil,
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = profile.id
            item.state = presentation.showsCheckmark ? .on : .off
            item.isEnabled = presentation.isEnabled
            submenu.addItem(item)
        }

        if sectionIndex < quotaOverviewState.sections.count - 1 {
            submenu.addItem(.separator())
        }
    }

    return submenu
}

@MainActor
func buildMaintenanceMenu(
    isRefreshing: Bool,
    refreshProgress: RefreshProgress? = nil,
    isLaunchingSessionManager: Bool,
    isPerformingSafeSwitchOperation: Bool,
    hasRollbackRestorePoint: Bool,
    target: AnyObject?,
    refreshAction: Selector,
    manageSessionsAction: Selector,
    repairAction: Selector,
    rollbackAction: Selector
) -> NSMenu {
    let submenu = NSMenu()

    let refreshItem = NSMenuItem(
        title: isRefreshing
            ? refreshItemTitle(refreshProgress: refreshProgress)
            : AppLocalization.localized(en: "Refresh All", zh: "全部刷新"),
        action: refreshAction,
        keyEquivalent: ""
    )
    refreshItem.target = target
    refreshItem.isEnabled = !isRefreshing && !isPerformingSafeSwitchOperation
    submenu.addItem(refreshItem)

    let sessionManagerItem = NSMenuItem(
        title: isLaunchingSessionManager
            ? AppLocalization.localized(en: "Opening Session Manager…", zh: "正在打开 Session Manager…")
            : AppLocalization.localized(en: "Open Session Manager", zh: "打开 Session Manager"),
        action: manageSessionsAction,
        keyEquivalent: ""
    )
    sessionManagerItem.target = target
    sessionManagerItem.isEnabled = !isLaunchingSessionManager && !isPerformingSafeSwitchOperation
    submenu.addItem(sessionManagerItem)

    submenu.addItem(.separator())

    let repairItem = NSMenuItem(
        title: AppLocalization.localized(en: "Repair Now", zh: "立即修复"),
        action: repairAction,
        keyEquivalent: ""
    )
    repairItem.target = target
    repairItem.isEnabled = !isPerformingSafeSwitchOperation
    submenu.addItem(repairItem)

    let rollbackItem = NSMenuItem(
        title: AppLocalization.localized(en: "Rollback Last Change", zh: "回滚上次变更"),
        action: rollbackAction,
        keyEquivalent: ""
    )
    rollbackItem.target = target
    rollbackItem.isEnabled = !isPerformingSafeSwitchOperation && hasRollbackRestorePoint
    submenu.addItem(rollbackItem)

    return submenu
}

private func refreshItemTitle(refreshProgress: RefreshProgress?) -> String {
    guard let refreshProgress else {
        return AppLocalization.localized(en: "Refreshing…", zh: "刷新中…")
    }

    return AppLocalization.localized(
        en: "Refreshing \(refreshProgress.fractionText)…",
        zh: "刷新中 \(refreshProgress.fractionText)…"
    )
}
