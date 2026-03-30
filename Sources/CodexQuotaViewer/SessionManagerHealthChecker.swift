import Foundation

struct SessionManagerHealthChecker {
    let healthURL: URL
    let urlSession: URLSession

    init(healthURL: URL, urlSession: URLSession = .shared) {
        self.healthURL = healthURL
        self.urlSession = urlSession
    }

    func isHealthy() async -> Bool {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 1
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }

            if let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = payload["ok"] as? Bool {
                return ok
            }

            return true
        } catch {
            return false
        }
    }
}
