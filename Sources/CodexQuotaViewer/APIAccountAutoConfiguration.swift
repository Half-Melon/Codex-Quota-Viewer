import Foundation

struct APIAccountDraft: Equatable {
    let displayName: String
    let apiKey: String
    let normalizedBaseURL: String
    let model: String
    let usedFallback: Bool
    let warningMessage: String?
}

struct APIAccountProbeResponse: Equatable {
    let modelIDs: [String]
    let normalizedBaseURL: String
}

func makeAPIKeyAuthData(apiKey: String) -> Data {
    let payload = [
        "OPENAI_API_KEY": apiKey,
        "auth_mode": "apikey",
    ]
    let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    return data ?? Data(#"{"auth_mode":"apikey"}"#.utf8)
}

enum APIAccountAutoConfigurationError: LocalizedError {
    case missingAPIKey
    case missingBaseURL
    case invalidBaseURL

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return AppLocalization.localized(en: "API key is required.", zh: "必须填写 API Key。")
        case .missingBaseURL:
            return AppLocalization.localized(en: "Base URL is required.", zh: "必须填写 Base URL。")
        case .invalidBaseURL:
            return AppLocalization.localized(
                en: "Base URL is not a valid OpenAI-compatible endpoint.",
                zh: "Base URL 不是有效的 OpenAI-compatible 端点。"
            )
        }
    }
}

protocol APIModelsProbing: Sendable {
    func probeModels(apiKey: String, rawBaseURL: String) async throws -> APIAccountProbeResponse
}

struct URLSessionAPIModelsProbe: APIModelsProbing, Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 12
            self.session = URLSession(configuration: configuration)
        }
    }

    func probeModels(apiKey: String, rawBaseURL: String) async throws -> APIAccountProbeResponse {
        let candidates = try modelsProbeCandidates(for: rawBaseURL)
        var lastError: Error?

        for candidate in candidates {
            do {
                var request = URLRequest(url: candidate.modelsURL)
                request.httpMethod = "GET"
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")

                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200 ..< 300).contains(httpResponse.statusCode) else {
                    throw URLError(.badServerResponse)
                }

                let modelIDs = try decodeModelIDs(from: data)
                guard !modelIDs.isEmpty else {
                    throw URLError(.cannotParseResponse)
                }

                return APIAccountProbeResponse(
                    modelIDs: modelIDs,
                    normalizedBaseURL: candidate.normalizedBaseURL
                )
            } catch {
                lastError = error
            }
        }

        throw lastError ?? URLError(.badServerResponse)
    }
}

func buildFallbackAPIAccountDraft(
    apiKey: String,
    rawBaseURL: String,
    overrideDisplayName: String? = nil,
    overrideModel: String? = nil
) -> APIAccountDraft {
    let normalizedBaseURL = (try? normalizedOpenAICompatibleBaseURL(from: rawBaseURL, ensureV1: true))
        ?? normalizedLooseBaseURL(from: rawBaseURL)
        ?? "https://api.openai.com/v1"
    let resolvedDisplayName = normalizedAccountDisplayName(
        overrideDisplayName,
        normalizedBaseURL: normalizedBaseURL
    )
    let resolvedModel = normalizedPreferredModel(overrideModel) ?? "gpt-5.4"

    return APIAccountDraft(
        displayName: resolvedDisplayName,
        apiKey: apiKey,
        normalizedBaseURL: normalizedBaseURL,
        model: resolvedModel,
        usedFallback: true,
        warningMessage: AppLocalization.localized(
            en: "Auto-detect failed, fallback applied.",
            zh: "自动探测失败，已使用兜底配置。"
        )
    )
}

func preferredModelID(from modelIDs: [String]) -> String? {
    let normalized = modelIDs
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    guard !normalized.isEmpty else {
        return nil
    }

    let preferredPrefixes = [
        "gpt-5",
        "gpt-4.1",
        "gpt-4o",
        "o4",
        "o3",
        "gpt-4",
        "gpt-3.5",
    ]

    for prefix in preferredPrefixes {
        if let match = normalized.first(where: {
            let lowercased = $0.lowercased()
            return lowercased.hasPrefix(prefix)
                && !isNonChatModel(lowercased)
        }) {
            return match
        }
    }

    return normalized.first(where: { !isNonChatModel($0.lowercased()) }) ?? normalized.first
}

func normalizedOpenAICompatibleBaseURL(
    from rawBaseURL: String,
    ensureV1: Bool
) throws -> String {
    guard var sanitized = normalizedLooseBaseURL(from: rawBaseURL) else {
        throw APIAccountAutoConfigurationError.invalidBaseURL
    }

    guard var components = URLComponents(string: sanitized),
          components.scheme != nil,
          components.host != nil else {
        throw APIAccountAutoConfigurationError.invalidBaseURL
    }

    var path = components.path
    path = path.replacingOccurrences(of: "//", with: "/")
    path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

    let segments = path.split(separator: "/").map(String.init)
    if ensureV1 {
        if segments.last?.lowercased() != "v1" {
            path = segments.isEmpty ? "v1" : segments.joined(separator: "/") + "/v1"
        } else {
            path = segments.joined(separator: "/")
        }
    } else {
        path = segments.joined(separator: "/")
    }

    components.path = path.isEmpty ? "" : "/" + path
    components.query = nil
    components.fragment = nil

    sanitized = components.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? sanitized
    return sanitized
}

func normalizedLooseBaseURL(from rawBaseURL: String) -> String? {
    let trimmed = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return nil
    }

    let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard var components = URLComponents(string: withScheme),
          components.host != nil else {
        return nil
    }

    components.query = nil
    components.fragment = nil
    if components.path.hasSuffix("/") && components.path.count > 1 {
        components.path.removeLast()
    }
    return components.string
}

func normalizedAccountDisplayName(
    _ overrideDisplayName: String?,
    normalizedBaseURL: String
) -> String {
    if let overrideDisplayName {
        let trimmed = overrideDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
    }

    return displayHost(from: normalizedBaseURL) ?? normalizedBaseURL
}

func normalizedPreferredModel(_ overrideModel: String?) -> String? {
    guard let overrideModel else {
        return nil
    }

    let trimmed = overrideModel.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private struct ModelsProbeCandidate {
    let normalizedBaseURL: String
    let modelsURL: URL
}

private struct ModelsListEnvelope: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}

private func modelsProbeCandidates(for rawBaseURL: String) throws -> [ModelsProbeCandidate] {
    let withoutV1 = try normalizedOpenAICompatibleBaseURL(from: rawBaseURL, ensureV1: false)
    let withV1 = try normalizedOpenAICompatibleBaseURL(from: rawBaseURL, ensureV1: true)
    let baseURLs = Array(NSOrderedSet(array: [withV1, withoutV1]).compactMap { $0 as? String })

    var candidates: [ModelsProbeCandidate] = []
    for baseURL in baseURLs {
        guard let modelsURL = URL(string: baseURL + "/models") else {
            continue
        }
        candidates.append(ModelsProbeCandidate(normalizedBaseURL: baseURL, modelsURL: modelsURL))
    }

    guard !candidates.isEmpty else {
        throw APIAccountAutoConfigurationError.invalidBaseURL
    }
    return candidates
}

private func decodeModelIDs(from data: Data) throws -> [String] {
    if let envelope = try? JSONDecoder().decode(ModelsListEnvelope.self, from: data) {
        return envelope.data.map(\.id)
    }

    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = object["data"] as? [[String: Any]] else {
        throw URLError(.cannotParseResponse)
    }

    return items.compactMap { $0["id"] as? String }
}

private func isNonChatModel(_ modelID: String) -> Bool {
    let blockedTokens = [
        "embedding",
        "moderation",
        "rerank",
        "transcribe",
        "speech",
        "audio",
        "image",
        "whisper",
        "tts",
    ]

    return blockedTokens.contains(where: { modelID.contains($0) })
}
