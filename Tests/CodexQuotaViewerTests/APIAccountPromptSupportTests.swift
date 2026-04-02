import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func validatedAPIAccountPromptInputRejectsMissingRequiredFields() {
    #expect(throws: APIAccountPromptValidationError.missingAPIKey) {
        try validatedAPIAccountPromptInput(
            displayName: nil,
            apiKey: "   ",
            baseURL: "https://api.example.com/v1",
            model: nil
        )
    }

    #expect(throws: APIAccountPromptValidationError.missingBaseURL) {
        try validatedAPIAccountPromptInput(
            displayName: nil,
            apiKey: "sk-test",
            baseURL: "   ",
            model: nil
        )
    }
}
