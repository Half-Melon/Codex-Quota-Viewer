import Foundation

@testable import CodexQuotaViewer

private let localizationTestLock = NSLock()

struct TestHarness {
    let homeURL: URL
    let codexHomeURL: URL
    let appSupportURL: URL
}

func makeHarness() throws -> TestHarness {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexQuotaViewerTests-\(UUID().uuidString)", isDirectory: true)
    let homeURL = root.appendingPathComponent("home", isDirectory: true)
    let codexHomeURL = homeURL.appendingPathComponent(".codex", isDirectory: true)
    let appSupportURL = homeURL
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent(AppIdentity.supportDirectoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
    return TestHarness(homeURL: homeURL, codexHomeURL: codexHomeURL, appSupportURL: appSupportURL)
}

extension Data {
    func utf8String() throws -> String {
        guard let string = String(data: self, encoding: .utf8) else {
            throw NSError(domain: "CodexQuotaViewerTests", code: 1)
        }
        return string
    }
}

@discardableResult
func withExclusiveAppLocalization<T>(_ body: () -> T) -> T {
    localizationTestLock.lock()
    defer {
        AppLocalization.setPreferredLanguage(.system, preferredLanguages: Locale.preferredLanguages)
        localizationTestLock.unlock()
    }
    return body()
}

@discardableResult
func withExclusiveAppLocalization<T>(_ body: () throws -> T) rethrows -> T {
    localizationTestLock.lock()
    defer {
        AppLocalization.setPreferredLanguage(.system, preferredLanguages: Locale.preferredLanguages)
        localizationTestLock.unlock()
    }
    return try body()
}
