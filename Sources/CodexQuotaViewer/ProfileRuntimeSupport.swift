import Foundation

struct ProfileRuntimeMaterial: Equatable {
    let authData: Data
    let configData: Data?
}

struct APIKeyProfileDetails: Equatable {
    let providerName: String?
    let baseURL: String?
    let model: String?
    let keyHint: String
}

private struct AuthEnvelope: Decodable {
    let authMode: String?
    let openAIAPIKey: String?

    private enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case openAIAPIKey = "OPENAI_API_KEY"
    }
}

private struct APIKeyConfigSummary {
    var providerID: String?
    var providerName: String?
    var baseURL: String?
    var model: String?
}

func apiKeyProfileDetails(authData: Data, configData: Data?) -> APIKeyProfileDetails? {
    guard let envelope = try? JSONDecoder().decode(AuthEnvelope.self, from: authData),
          let apiKey = envelope.openAIAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines),
          !apiKey.isEmpty,
          isAPIKeyAuthMode(envelope.authMode) || apiKey.hasPrefix("sk-") else {
        return nil
    }

    let summary = parseAPIKeyConfig(configData)
    return APIKeyProfileDetails(
        providerName: summary.providerName,
        baseURL: summary.baseURL,
        model: summary.model,
        keyHint: "...\(apiKey.suffix(4))"
    )
}

func apiKeyStatusTexts(details: APIKeyProfileDetails?) -> (String, String) {
    guard let details else {
        return ("API Key 登录", "官方额度不可用")
    }

    let primary = details.providerName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        ? details.providerName!
        : "API Key 登录"

    let secondary = [
        details.model,
        displayHost(from: details.baseURL),
        details.keyHint,
    ]
    .compactMap { value -> String? in
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
    .joined(separator: " · ")

    return (primary, secondary.isEmpty ? "官方额度不可用" : secondary)
}

private func isAPIKeyAuthMode(_ rawValue: String?) -> Bool {
    rawValue?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() == "apikey"
}

private func parseAPIKeyConfig(_ configData: Data?) -> APIKeyConfigSummary {
    guard let configData,
          let raw = String(data: configData, encoding: .utf8) else {
        return APIKeyConfigSummary()
    }

    var summary = APIKeyConfigSummary()
    var currentSection: String?

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
                summary.providerID = value
            default:
                break
            }
            continue
        }

        if let providerID = summary.providerID,
           currentSection == "model_providers.\(providerID)" {
            switch key {
            case "name":
                summary.providerName = value
            case "base_url":
                summary.baseURL = value
            default:
                break
            }
        }
    }

    return summary
}

private func normalizedConfigValue<S: StringProtocol>(_ rawValue: S) -> String {
    var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if let commentStart = value.firstIndex(of: "#") {
        value = String(value[..<commentStart]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value.removeFirst()
        value.removeLast()
    }
    return value
}

private func displayHost(from rawURL: String?) -> String? {
    guard let rawURL,
          let host = URL(string: rawURL)?.host,
          !host.isEmpty else {
        return nil
    }
    return host
}
