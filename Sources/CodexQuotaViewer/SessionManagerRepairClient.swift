import Foundation

@MainActor
protocol OfficialThreadRepairing: AnyObject {
    func rescanAndRepair() async throws -> OfficialRepairSummary
}

enum OfficialThreadRepairError: LocalizedError {
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return AppLocalization.localized(
                en: "Session manager returned an invalid repair response.",
                zh: "Session Manager 返回了无效的修复响应。"
            )
        case .requestFailed(let message):
            return AppLocalization.localized(
                en: "Session manager repair failed: \(message)",
                zh: "Session Manager 修复失败：\(message)"
            )
        }
    }
}

private struct OfficialRepairEnvelope: Decodable {
    let stats: OfficialRepairSummary
}

private struct EmptyResponse: Decodable {}

@MainActor
final class SessionManagerRepairClient: OfficialThreadRepairing {
    private let launcher: SessionManagerLauncher
    private let urlSession: URLSession

    init(
        launcher: SessionManagerLauncher,
        urlSession: URLSession = .shared
    ) {
        self.launcher = launcher
        self.urlSession = urlSession
    }

    func rescanAndRepair() async throws -> OfficialRepairSummary {
        _ = try await launcher.ensureServiceRunning()
        let _: EmptyResponse = try await post(path: "/api/sessions/rescan")
        let envelope: OfficialRepairEnvelope = try await post(path: "/api/codex/repair")
        return envelope.stats
    }

    private func post<T: Decodable>(path: String) async throws -> T {
        let endpoint = launcher.serviceBaseURL.appendingPathComponent(
            path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            isDirectory: false
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OfficialThreadRepairError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw OfficialThreadRepairError.requestFailed(
                message ?? AppLocalization.localized(
                    en: "HTTP \(httpResponse.statusCode)",
                    zh: "HTTP \(httpResponse.statusCode)"
                )
            )
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw OfficialThreadRepairError.invalidResponse
        }
    }
}
