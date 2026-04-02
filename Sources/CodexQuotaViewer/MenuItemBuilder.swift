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
                let presentation = buildQuotaOverviewMenuItemPresentation(
                    for: tile,
                    isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation
                )
                let item = NSMenuItem(
                    title: presentation.title,
                    action: presentation.triggersDirectSwitch ? activateSavedAccountAction : nil,
                    keyEquivalent: ""
                )
                item.target = target
                item.representedObject = tile.profile.id
                item.state = presentation.showsCheckmark ? .on : .off
                item.isEnabled = presentation.isEnabled
                item.toolTip = presentation.accessibilityLabel
                return item
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
            ? AppLocalization.localized(en: "Refreshing…", zh: "刷新中…")
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
