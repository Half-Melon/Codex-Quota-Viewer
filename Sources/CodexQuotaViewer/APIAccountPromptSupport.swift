import Foundation

struct APIAccountPromptInput: Equatable {
    let displayName: String?
    let apiKey: String
    let baseURL: String
    let model: String?
}

enum APIAccountPromptValidationError: LocalizedError, Equatable {
    case missingAPIKey
    case missingBaseURL

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return AppLocalization.localized(
                en: "API Key is required before adding the account.",
                zh: "添加账号前必须填写 API Key。"
            )
        case .missingBaseURL:
            return AppLocalization.localized(
                en: "Base URL is required before adding the account.",
                zh: "添加账号前必须填写 Base URL。"
            )
        }
    }
}

func validatedAPIAccountPromptInput(
    displayName: String?,
    apiKey: String,
    baseURL: String,
    model: String?
) throws -> APIAccountPromptInput {
    let trimmedDisplayName = displayName?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedModel = model?
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmedAPIKey.isEmpty else {
        throw APIAccountPromptValidationError.missingAPIKey
    }

    guard !trimmedBaseURL.isEmpty else {
        throw APIAccountPromptValidationError.missingBaseURL
    }

    return APIAccountPromptInput(
        displayName: trimmedDisplayName?.isEmpty == true ? nil : trimmedDisplayName,
        apiKey: trimmedAPIKey,
        baseURL: trimmedBaseURL,
        model: trimmedModel?.isEmpty == true ? nil : trimmedModel
    )
}
