import Foundation

struct CodexCLIConfiguration: Equatable {
    let executableURL: URL
    let argumentsPrefix: [String]

    func arguments(appending arguments: [String]) -> [String] {
        argumentsPrefix + arguments
    }
}

func resolveCodexCLIConfiguration(
    preferredExecutableURL: URL? = nil,
    bundledExecutableURL: URL = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> CodexCLIConfiguration? {
    let candidateURLs = [preferredExecutableURL, bundledExecutableURL]
        .compactMap { $0 }

    for candidateURL in candidateURLs {
        if fileManager.isExecutableFile(atPath: candidateURL.path) {
            return CodexCLIConfiguration(executableURL: candidateURL, argumentsPrefix: [])
        }
    }

    if let pathExecutableURL = codexExecutableURLInPATH(
        environment: environment,
        fileManager: fileManager
    ) {
        return CodexCLIConfiguration(
            executableURL: pathExecutableURL,
            argumentsPrefix: []
        )
    }

    return nil
}

private func codexExecutableURLInPATH(
    environment: [String: String],
    fileManager: FileManager
) -> URL? {
    guard let rawPATH = environment["PATH"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !rawPATH.isEmpty else {
        return nil
    }

    for directory in rawPATH.split(separator: ":").map(String.init) {
        guard !directory.isEmpty else {
            continue
        }

        let candidateURL = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false)
        if fileManager.isExecutableFile(atPath: candidateURL.path) {
            return candidateURL
        }
    }

    return nil
}
