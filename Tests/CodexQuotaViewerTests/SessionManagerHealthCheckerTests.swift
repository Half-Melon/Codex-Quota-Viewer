import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func sessionManagerHealthCheckerRequiresExplicitOkTrue() async throws {
    let session = makeHealthCheckSession { request in
        if request.url?.path == "/health-ok" {
            return (
                Data(#"{"ok":true}"#.utf8),
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
            )
        }

        return (
            Data(#"{"status":"up"}"#.utf8),
            HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }

    let healthyChecker = SessionManagerHealthChecker(
        healthURL: URL(string: "http://localhost/health-ok")!,
        urlSession: session
    )
    let falsePositiveChecker = SessionManagerHealthChecker(
        healthURL: URL(string: "http://localhost/health-missing-ok")!,
        urlSession: session
    )

    #expect(await healthyChecker.isHealthy())
    #expect(await falsePositiveChecker.isHealthy() == false)
}

private func makeHealthCheckSession(
    handler: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
) -> URLSession {
    HealthCheckURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HealthCheckURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class HealthCheckURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
