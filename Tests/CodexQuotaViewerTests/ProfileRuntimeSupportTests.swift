import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func currentRuntimeCaptureActionSilentlyUpdatesChatGPTTokenRefreshes() {
    let stored = ProfileRuntimeMaterial(
        authData: Data(
            """
            {"auth_mode":"chatgpt","last_refresh":"2026-03-30T02:33:21Z","tokens":{"access_token":"token-1","refresh_token":"refresh-1","account_id":"acct-1"}}
            """.utf8
        ),
        configData: Data("model_provider = \"openai\"\nmodel = \"gpt-5.4\"\n".utf8)
    )
    let current = ProfileRuntimeMaterial(
        authData: Data(
            """
            {"auth_mode":"chatgpt","last_refresh":"2026-03-31T05:55:55Z","tokens":{"access_token":"token-2","refresh_token":"refresh-2","account_id":"acct-1"}}
            """.utf8
        ),
        configData: Data("model_provider = \"openai\"\nmodel = \"gpt-5.4\"\n".utf8)
    )

    #expect(
        currentRuntimeCaptureAction(
            currentRuntimeMaterial: current,
            existingRuntimeMaterial: stored
        ) == .updateWithoutRestorePoint
    )
}

@Test
func currentRuntimeCaptureActionRequiresRestorePointWhenSwitchMaterialChanges() {
    let stored = ProfileRuntimeMaterial(
        authData: Data(
            """
            {"auth_mode":"chatgpt","tokens":{"access_token":"token-1","account_id":"acct-1"}}
            """.utf8
        ),
        configData: Data("model_provider = \"openai\"\nmodel = \"gpt-4.1\"\n".utf8)
    )
    let current = ProfileRuntimeMaterial(
        authData: Data(
            """
            {"auth_mode":"chatgpt","tokens":{"access_token":"token-2","account_id":"acct-1"}}
            """.utf8
        ),
        configData: Data("model_provider = \"openai\"\nmodel = \"gpt-5.4\"\n".utf8)
    )

    #expect(
        currentRuntimeCaptureAction(
            currentRuntimeMaterial: current,
            existingRuntimeMaterial: stored
        ) == .captureWithRestorePoint
    )
}

@Test
func parseRuntimeConfigPreservesHashesInsideQuotedValues() {
    let summary = parseRuntimeConfig(
        Data(
            """
            model_provider = "custom"
            model = "gpt-4#mini"

            [model_providers.custom]
            name = "hash#proxy"
            requires_openai_auth = true
            base_url = "https://example.com/v1#fragment"
            """.utf8
        )
    )

    #expect(summary.model == "gpt-4#mini")
    #expect(summary.providerName == "openai")
    #expect(summary.baseURL == "https://example.com/v1#fragment")
    #expect(summary.usesOpenAICompatibilityProvider)
}
