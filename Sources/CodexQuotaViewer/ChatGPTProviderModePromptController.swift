import AppKit
import Foundation

@MainActor
final class ChatGPTProviderModePromptController {
    func promptForProvider(
        records: [VaultAccountRecord],
        runModalPresentation: (_ body: () -> VaultAccountRecord?) -> VaultAccountRecord?
    ) -> VaultAccountRecord? {
        runModalPresentation {
            let apiRecords = records
                .filter { $0.metadata.authMode == .apiKey }
                .sorted {
                    profileLastUsedComparator(
                        lhsLastUsedAt: $0.metadata.lastUsedAt,
                        lhsDisplayName: $0.metadata.displayName,
                        rhsLastUsedAt: $1.metadata.lastUsedAt,
                        rhsDisplayName: $1.metadata.displayName
                    )
                }

            guard !apiRecords.isEmpty else {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = AppLocalization.localized(
                    en: "No saved API accounts",
                    zh: "暂无已保存 API 账号"
                )
                alert.informativeText = AppLocalization.localized(
                    en: "Add an API account first, then switch to third-party Provider mode.",
                    zh: "请先添加 API 账号，然后再切换到第三方 Provider 模式。"
                )
                alert.addButton(withTitle: AppLocalization.localized(en: "OK", zh: "知道了"))
                _ = alert.runModal()
                return nil
            }

            let alert = NSAlert()
            alert.messageText = AppLocalization.localized(
                en: "Choose Third-party Provider",
                zh: "选择第三方 Provider"
            )
            alert.informativeText = AppLocalization.localized(
                en: "Codex stays signed in with ChatGPT. Requests will use the selected saved API account.",
                zh: "Codex 会保持 ChatGPT 登录状态，实际请求使用所选已保存 API 账号。"
            )
            alert.addButton(withTitle: AppLocalization.localized(en: "Switch", zh: "切换"))
            alert.addButton(withTitle: AppLocalization.localized(en: "Cancel", zh: "取消"))

            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28), pullsDown: false)
            for record in apiRecords {
                let item = NSMenuItem(title: menuTitle(for: record), action: nil, keyEquivalent: "")
                item.representedObject = record.id
                popup.menu?.addItem(item)
            }
            popup.selectItem(at: 0)
            alert.accessoryView = popup

            guard alert.runModal() == .alertFirstButtonReturn,
                  let selectedID = popup.selectedItem?.representedObject as? String else {
                return nil
            }

            return apiRecords.first { $0.id == selectedID }
        }
    }

    private func menuTitle(for record: VaultAccountRecord) -> String {
        let host = displayHost(from: record.metadata.baseURL)
            ?? displayHost(from: parseRuntimeConfig(record.runtimeMaterial.configData).baseURL)
        return joinedNonEmptyParts([
            record.metadata.displayName,
            host,
            record.metadata.model,
        ])
    }
}
