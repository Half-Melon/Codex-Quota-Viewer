import CryptoKit
import Foundation

struct ProfileRuntimeMaterial: Equatable, Sendable {
    let authData: Data
    let configData: Data?
}

enum CodexAuthMode: String, Codable, Equatable, Sendable {
    case chatgpt
    case apiKey
    case unknown

    var displayLabel: String {
        switch self {
        case .chatgpt:
            return "ChatGPT"
        case .apiKey:
            return AppLocalization.localized(en: "API Key", zh: "API 密钥")
        case .unknown:
            return AppLocalization.localized(en: "Unknown", zh: "未知")
        }
    }
}

struct RuntimeConfigSummary: Equatable {
    var providerID: String?
    var threadProviderID: String?
    var providerName: String?
    var baseURL: String?
    var model: String?
    var usesOpenAICompatibilityProvider = false
}

struct APIKeyProfileDetails: Equatable {
    let providerName: String?
    let baseURL: String?
    let model: String?
    let keyHint: String
}

struct AuthEnvelope: Decodable {
    let authMode: String?
    let openAIAPIKey: String?
    let lastRefresh: String?
    let tokens: AuthTokensEnvelope?

    private enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case openAIAPIKey = "OPENAI_API_KEY"
        case lastRefresh = "last_refresh"
        case tokens
    }
}

struct AuthTokensEnvelope: Decodable {
    let accessToken: String?
    let idToken: String?
    let accountID: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case idToken = "id_token"
        case accountID = "account_id"
    }
}

func canonicalRuntimeMaterialForStorage(_ runtimeMaterial: ProfileRuntimeMaterial) -> ProfileRuntimeMaterial {
    let authMode = resolveAuthMode(authData: runtimeMaterial.authData)
    let summary = parseRuntimeConfig(runtimeMaterial.configData)

    if authMode == .chatgpt {
        return ProfileRuntimeMaterial(
            authData: runtimeMaterial.authData,
            configData: synthesizedStoredChatGPTConfig(from: summary)
        )
    }

    if shouldCanonicalizeOpenAICompatibleAPIConfig(authMode: authMode, summary: summary) {
        return ProfileRuntimeMaterial(
            authData: runtimeMaterial.authData,
            configData: synthesizedOpenAICompatibleConfig(from: summary)
        )
    }

    return runtimeMaterial
}

func stableAccountIdentityKey(for runtimeMaterial: ProfileRuntimeMaterial) -> String {
    let canonicalRuntime = canonicalRuntimeMaterialForStorage(runtimeMaterial)
    let authMode = resolveAuthMode(authData: canonicalRuntime.authData)

    switch authMode {
    case .chatgpt:
        if let identity = chatGPTAccountIdentity(from: canonicalRuntime.authData) {
            return "chatgpt:\(identity)"
        }
    case .apiKey:
        let keyDigest = apiKeyIdentityDigest(from: canonicalRuntime.authData) ?? runtimeIdentityKey(authData: canonicalRuntime.authData)
        let baseURL = normalizedStableBaseURL(from: parseRuntimeConfig(canonicalRuntime.configData).baseURL) ?? ""
        return "apikey:\(keyDigest)|\(baseURL)"
    case .unknown:
        break
    }

    return runtimeIdentityKey(for: canonicalRuntime)
}

func stableAccountRecordID(for runtimeMaterial: ProfileRuntimeMaterial) -> String {
    let digest = SHA256.hash(data: Data(stableAccountIdentityKey(for: runtimeMaterial).utf8))
    let hex = hexString(for: digest)
    return "acct-\(hex.prefix(16))"
}

func stableRuntimeIdentityMatches(
    _ lhs: ProfileRuntimeMaterial,
    _ rhs: ProfileRuntimeMaterial?
) -> Bool {
    guard let rhs else {
        return false
    }

    return stableAccountIdentityKey(for: lhs) == stableAccountIdentityKey(for: rhs)
}

func resolveAuthMode(authData: Data) -> CodexAuthMode {
    guard let envelope = try? JSONDecoder().decode(AuthEnvelope.self, from: authData) else {
        return .unknown
    }

    let normalizedAuthMode = envelope.authMode?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let apiKey = envelope.openAIAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    if normalizedAuthMode == CodexAuthMode.chatgpt.rawValue {
        return .chatgpt
    }

    if isAPIKeyAuthMode(normalizedAuthMode) || !apiKey.isEmpty {
        return .apiKey
    }

    return .unknown
}

func summarizeRuntimeConfig(_ configData: Data?) -> RuntimeConfigSummary {
    parseRuntimeConfig(configData)
}

func apiKeyProfileDetails(authData: Data, configData: Data?) -> APIKeyProfileDetails? {
    guard let envelope = try? JSONDecoder().decode(AuthEnvelope.self, from: authData),
          let apiKey = envelope.openAIAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines),
          !apiKey.isEmpty,
          resolveAuthMode(authData: authData) == .apiKey || apiKey.hasPrefix("sk-") else {
        return nil
    }

    let summary = parseRuntimeConfig(configData)
    return APIKeyProfileDetails(
        providerName: summary.providerName,
        baseURL: summary.baseURL,
        model: summary.model,
        keyHint: "...\(apiKey.suffix(4))"
    )
}

func apiKeyStatusTexts(details: APIKeyProfileDetails?) -> (String, String) {
    let primary = "API"

    guard let details else {
        return (
            primary,
            AppLocalization.localized(en: "Official quota unavailable", zh: "官方额度不可用")
        )
    }

    let secondary = joinedNonEmptyParts([
        details.model,
        displayHost(from: details.baseURL),
        details.keyHint,
    ])

    return (
        primary,
        secondary.isEmpty
            ? AppLocalization.localized(en: "Official quota unavailable", zh: "官方额度不可用")
            : secondary
    )
}

func runtimeIdentityKey(for runtimeMaterial: ProfileRuntimeMaterial) -> String {
    let authKey = runtimeIdentityKey(authData: runtimeMaterial.authData)
    let configKey = canonicalConfigIdentityKey(from: runtimeMaterial.configData)
    return "\(authKey)|\(configKey)"
}

func runtimeIdentityKey(authData: Data) -> String {
    guard let canonicalJSON = canonicalJSONData(from: authData) else {
        return authData.base64EncodedString()
    }

    return canonicalJSON.base64EncodedString()
}

func isAPIKeyAuthMode(_ rawValue: String?) -> Bool {
    rawValue?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() == "apikey"
}

func parseRuntimeConfig(_ configData: Data?) -> RuntimeConfigSummary {
    guard let configData,
          let raw = String(data: configData, encoding: .utf8) else {
        return RuntimeConfigSummary()
    }

    var summary = RuntimeConfigSummary()
    var currentSection: String?
    var rawProviderID: String?
    var rootBaseURL: String?
    var sectionProviderName: String?
    var sectionBaseURL: String?
    var sectionRequiresOpenAIAuth = false

    for rawLine in raw.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#") else { continue }

        if line.hasPrefix("[") && line.hasSuffix("]") {
            currentSection = String(line.dropFirst().dropLast())
            continue
        }

        guard let split = line.firstIndex(of: "=") else { continue }
        let key = line[..<split].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalizedConfigValue(line[line.index(after: split)...])

        if currentSection == nil {
            switch key {
            case "model":
                summary.model = value
            case "model_provider":
                rawProviderID = value
            case "base_url":
                rootBaseURL = value
            default:
                break
            }
            continue
        }

        if let providerID = rawProviderID,
           currentSection == "model_providers.\(providerID)" {
            switch key {
            case "name":
                sectionProviderName = value
            case "base_url":
                sectionBaseURL = value
            case "requires_openai_auth":
                if let parsed = normalizedConfigBoolean(value) {
                    sectionRequiresOpenAIAuth = parsed
                }
            default:
                break
            }
        }
    }

    summary.providerID = rawProviderID
    summary.threadProviderID = rawProviderID
    summary.providerName = sectionProviderName
    summary.baseURL = sectionBaseURL ?? rootBaseURL

    if rawProviderID == "custom", sectionRequiresOpenAIAuth {
        summary.providerID = "openai"
        summary.providerName = "openai"
        summary.baseURL = sectionBaseURL ?? rootBaseURL
        summary.usesOpenAICompatibilityProvider = true
    }

    return summary
}

func synthesizedOpenAICompatibleConfig(from summary: RuntimeConfigSummary) -> Data {
    synthesizedOpenAICompatibleConfig(
        baseURL: summary.baseURL,
        model: summary.model
    )
}

func synthesizedOpenAICompatibleConfig(
    baseURL: String?,
    model: String?
) -> Data {
    let normalizedBaseURL = normalizedOpenAICompatibleStorageBaseURL(from: baseURL)
    let normalizedModel = model?
        .trimmingCharacters(in: .whitespacesAndNewlines)

    var lines = ["model_provider = \"custom\""]
    if let normalizedModel,
       !normalizedModel.isEmpty {
        lines.append("model = \"\(escapedTOMLString(normalizedModel))\"")
    }

    lines.append("")
    lines.append("[model_providers.custom]")
    lines.append("name = \"custom\"")
    lines.append("wire_api = \"responses\"")
    lines.append("requires_openai_auth = true")
    if let normalizedBaseURL,
       !normalizedBaseURL.isEmpty {
        lines.append("base_url = \"\(escapedTOMLString(normalizedBaseURL))\"")
    }

    return Data((lines.joined(separator: "\n") + "\n").utf8)
}

func synthesizedStoredChatGPTConfig(from summary: RuntimeConfigSummary) -> Data {
    var lines = ["model_provider = \"openai\""]

    if let model = summary.model?.trimmingCharacters(in: .whitespacesAndNewlines),
       !model.isEmpty {
        lines.append("model = \"\(escapedTOMLString(model))\"")
    }

    return Data((lines.joined(separator: "\n") + "\n").utf8)
}

func escapedTOMLString(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private func normalizedConfigValue<S: StringProtocol>(_ rawValue: S) -> String {
    var value = String(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
    value = strippingInlineTOMLComment(from: value)
    if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value.removeFirst()
        value.removeLast()
    }
    return value
}

private func strippingInlineTOMLComment(from rawValue: String) -> String {
    var result = ""
    var isInsideQuotes = false
    var isEscaping = false

    for character in rawValue {
        if character == "#" && !isInsideQuotes {
            break
        }

        result.append(character)

        if isEscaping {
            isEscaping = false
            continue
        }

        if character == "\\" {
            isEscaping = true
            continue
        }

        if character == "\"" {
            isInsideQuotes.toggle()
        }
    }

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func normalizedConfigBoolean(_ rawValue: String) -> Bool? {
    switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "true":
        return true
    case "false":
        return false
    default:
        return nil
    }
}

private func normalizedOpenAICompatibleStorageBaseURL(from rawValue: String?) -> String? {
    guard let rawValue else {
        return nil
    }

    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return nil
    }

    return (try? normalizedOpenAICompatibleBaseURL(from: trimmed, ensureV1: true))
        ?? normalizedLooseBaseURL(from: trimmed)
        ?? trimmed
}

private func shouldCanonicalizeOpenAICompatibleAPIConfig(
    authMode: CodexAuthMode,
    summary: RuntimeConfigSummary
) -> Bool {
    guard authMode == .apiKey else {
        return summary.usesOpenAICompatibilityProvider
    }

    if summary.usesOpenAICompatibilityProvider {
        return true
    }

    let providerID = summary.providerID?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let baseURL = summary.baseURL?
        .trimmingCharacters(in: .whitespacesAndNewlines)

    return providerID == "openai" && baseURL?.isEmpty == false
}

func displayHost(from rawURL: String?) -> String? {
    guard let rawURL,
          let host = URL(string: rawURL)?.host,
          !host.isEmpty else {
        return nil
    }
    return host
}

private func canonicalJSONData(from data: Data) -> Data? {
    guard let object = try? JSONSerialization.jsonObject(with: data),
          JSONSerialization.isValidJSONObject(object) else {
        return nil
    }

    return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func canonicalConfigIdentityKey(from configData: Data?) -> String {
    guard let configData,
          var raw = String(data: configData, encoding: .utf8) else {
        return ""
    }

    raw = raw.replacingOccurrences(of: "\r\n", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return raw
}

private func chatGPTAccountIdentity(from authData: Data) -> String? {
    guard let envelope = try? JSONDecoder().decode(AuthEnvelope.self, from: authData) else {
        return nil
    }

    if let accountID = normalizedStableIdentityComponent(envelope.tokens?.accountID) {
        return "account:\(accountID)"
    }

    if let claims = jwtClaims(from: envelope.tokens?.idToken) ?? jwtClaims(from: envelope.tokens?.accessToken) {
        if let accountID = normalizedStableIdentityComponent(claims.accountID) {
            return "account:\(accountID)"
        }
        if let email = normalizedEmailIdentityComponent(claims.email) {
            return "email:\(email)"
        }
        if let subject = normalizedStableIdentityComponent(claims.subject) {
            return "sub:\(subject)"
        }
    }

    return nil
}

private func apiKeyIdentityDigest(from authData: Data) -> String? {
    guard let envelope = try? JSONDecoder().decode(AuthEnvelope.self, from: authData),
          let apiKey = envelope.openAIAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines),
          !apiKey.isEmpty else {
        return nil
    }

    let digest = SHA256.hash(data: Data(apiKey.utf8))
    return hexString(for: digest)
}

private struct JWTClaims: Decodable {
    let accountID: String?
    let email: String?
    let subject: String?

    private enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case email
        case subject = "sub"
    }
}

private func jwtClaims(from token: String?) -> JWTClaims? {
    guard let token,
          !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }

    let segments = token.split(separator: ".")
    guard segments.count >= 2,
          let payloadData = base64URLDecodedData(String(segments[1])) else {
        return nil
    }

    return try? JSONDecoder().decode(JWTClaims.self, from: payloadData)
}

private func base64URLDecodedData(_ rawValue: String) -> Data? {
    var value = rawValue
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")

    let remainder = value.count % 4
    if remainder != 0 {
        value += String(repeating: "=", count: 4 - remainder)
    }

    return Data(base64Encoded: value)
}

private func normalizedStableIdentityComponent(_ rawValue: String?) -> String? {
    guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawValue.isEmpty else {
        return nil
    }

    return rawValue.lowercased()
}

private func normalizedEmailIdentityComponent(_ rawValue: String?) -> String? {
    normalizedStableIdentityComponent(rawValue)
}

private func normalizedStableBaseURL(from rawBaseURL: String?) -> String? {
    guard let rawBaseURL,
          !rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }

    guard var components = URLComponents(string: rawBaseURL.contains("://") ? rawBaseURL : "https://\(rawBaseURL)"),
          components.host != nil else {
        return nil
    }

    components.query = nil
    components.fragment = nil
    components.host = components.host?.lowercased()

    var segments = components.path
        .split(separator: "/")
        .map(String.init)

    if segments.last?.lowercased() == "v1" {
        segments.removeLast()
    }

    components.path = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
    return components.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}
