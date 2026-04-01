import AppKit

@MainActor
func installApplicationMainMenu(
    app: NSApplication,
    appName: String = AppIdentity.displayName
) {
    let servicesMenu = NSMenu(title: AppLocalization.localized(en: "Services", zh: "服务"))
    app.mainMenu = makeApplicationMainMenu(
        appName: appName,
        servicesMenu: servicesMenu
    )
    app.servicesMenu = servicesMenu
}

@MainActor
func makeApplicationMainMenu(appName: String = AppIdentity.displayName) -> NSMenu {
    makeApplicationMainMenu(
        appName: appName,
        servicesMenu: NSMenu(title: AppLocalization.localized(en: "Services", zh: "服务"))
    )
}

@MainActor
private func makeApplicationMainMenu(
    appName: String,
    servicesMenu: NSMenu
) -> NSMenu {
    let mainMenu = NSMenu(title: appName)

    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    appMenuItem.submenu = makeAppMenu(appName: appName, servicesMenu: servicesMenu)

    let editMenuItem = NSMenuItem()
    mainMenu.addItem(editMenuItem)
    editMenuItem.submenu = makeEditMenu()

    return mainMenu
}

@MainActor
private func makeAppMenu(appName: String, servicesMenu: NSMenu) -> NSMenu {
    let menu = NSMenu(title: appName)
    menu.addItem(
        makeMenuItem(
            title: AppLocalization.localized(en: "About \(appName)", zh: "关于 \(appName)"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
    )
    menu.addItem(.separator())

    let servicesItem = NSMenuItem(
        title: AppLocalization.localized(en: "Services", zh: "服务"),
        action: nil,
        keyEquivalent: ""
    )
    menu.addItem(servicesItem)
    menu.setSubmenu(servicesMenu, for: servicesItem)
    menu.addItem(.separator())

    menu.addItem(
        makeMenuItem(
            title: AppLocalization.localized(en: "Hide \(appName)", zh: "隐藏 \(appName)"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
    )
    menu.addItem(
        makeMenuItem(
            title: AppLocalization.localized(en: "Hide Others", zh: "隐藏其他"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h",
            modifierMask: [.command, .option]
        )
    )
    menu.addItem(
        makeMenuItem(
            title: AppLocalization.localized(en: "Show All", zh: "全部显示"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
    )
    menu.addItem(.separator())
    menu.addItem(
        makeMenuItem(
            title: AppLocalization.localized(en: "Quit \(appName)", zh: "退出 \(appName)"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
    )
    return menu
}

@MainActor
private func makeEditMenu() -> NSMenu {
    let menu = NSMenu(title: AppLocalization.localized(en: "Edit", zh: "编辑"))
    menu.addItem(
        makeMenuItem(
            title: AppLocalization.localized(en: "Undo", zh: "撤销"),
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
    )
    menu.addItem(
        makeMenuItem(
            title: AppLocalization.localized(en: "Redo", zh: "重做"),
            action: Selector(("redo:")),
            keyEquivalent: "Z"
        )
    )
    menu.addItem(.separator())
    menu.addItem(
        makeMenuItem(
            title: AppLocalization.localized(en: "Cut", zh: "剪切"),
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
    )
    menu.addItem(
        makeMenuItem(
            title: AppLocalization.localized(en: "Copy", zh: "复制"),
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
    )
    menu.addItem(
        makeMenuItem(
            title: AppLocalization.localized(en: "Paste", zh: "粘贴"),
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
    )
    menu.addItem(
        makeMenuItem(
            title: AppLocalization.localized(en: "Select All", zh: "全选"),
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
    )
    return menu
}

@MainActor
private func makeMenuItem(
    title: String,
    action: Selector?,
    keyEquivalent: String,
    modifierMask: NSEvent.ModifierFlags = [.command]
) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.keyEquivalentModifierMask = modifierMask
    return item
}
