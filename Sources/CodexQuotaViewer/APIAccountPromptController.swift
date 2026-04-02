import AppKit
import Foundation

@MainActor
final class APIAccountPromptController {
    func prompt(
        runModalPresentation: (_ body: () -> APIAccountPromptInput?) -> APIAccountPromptInput?,
        userFacingMessage: @escaping (Error) -> String
    ) -> APIAccountPromptInput? {
        runModalPresentation {
            while true {
                let alert = NSAlert()
                alert.messageText = AppLocalization.localized(en: "Add API Account", zh: "添加 API 账号")
                alert.informativeText = AppLocalization.localized(
                    en: "Enter API Key and Base URL. CodexQuotaViewer will auto-detect the model and generate a working OpenAI-compatible runtime config.",
                    zh: "输入 API Key 和 Base URL。CodexQuotaViewer 会自动探测模型，并生成可用的 OpenAI-compatible 运行时配置。"
                )
                alert.addButton(withTitle: AppLocalization.localized(en: "Add Account", zh: "添加账号"))
                alert.addButton(withTitle: AppLocalization.localized(en: "Cancel", zh: "取消"))

                let apiKeyField = NSTextField(string: "")
                apiKeyField.placeholderString = "sk-..."
                let baseURLField = NSTextField(string: "")
                baseURLField.placeholderString = "https://api.openai.com/v1"

                let stack = NSStackView()
                stack.orientation = .vertical
                stack.spacing = 8
                stack.alignment = .leading
                stack.addArrangedSubview(
                    labeledField(AppLocalization.localized(en: "API Key", zh: "API Key"), field: apiKeyField)
                )
                stack.addArrangedSubview(
                    labeledField(AppLocalization.localized(en: "Base URL", zh: "Base URL"), field: baseURLField)
                )
                stack.frame = NSRect(x: 0, y: 0, width: 420, height: 96)
                alert.accessoryView = stack

                guard alert.runModal() == .alertFirstButtonReturn else {
                    return nil
                }

                do {
                    return try validatedAPIAccountPromptInput(
                        displayName: nil,
                        apiKey: apiKeyField.stringValue,
                        baseURL: baseURLField.stringValue,
                        model: nil
                    )
                } catch let error as APIAccountPromptValidationError {
                    presentValidationError(error, userFacingMessage: userFacingMessage)
                } catch {
                    return nil
                }
            }
        }
    }

    private func presentValidationError(
        _ error: APIAccountPromptValidationError,
        userFacingMessage: (Error) -> String
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppLocalization.localized(
            en: "Required fields are missing",
            zh: "缺少必填字段"
        )
        alert.informativeText = error.errorDescription ?? userFacingMessage(error)
        alert.addButton(withTitle: AppLocalization.localized(en: "OK", zh: "知道了"))
        alert.runModal()
    }

    private func labeledField(_ title: String, field: NSTextField) -> NSView {
        field.frame.size.width = 250
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 84).isActive = true
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }
}
