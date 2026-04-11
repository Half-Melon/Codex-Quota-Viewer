import Foundation

func hexString<S: Sequence>(for bytes: S) -> String
where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func joinedNonEmptyParts(
    _ parts: [String?],
    separator: String = " · "
) -> String {
    parts
        .compactMap { value -> String? in
            guard let value else {
                return nil
            }

            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        .joined(separator: separator)
}

/// Standardize, de-duplicate (by standardized path), and sort file URLs by path.
func deduplicatedStandardizedFileURLs(_ files: [URL]) -> [URL] {
    var seen = Set<String>()
    var result: [URL] = []

    for url in files {
        let standardizedURL = url.standardizedFileURL
        guard seen.insert(standardizedURL.path).inserted else {
            continue
        }
        result.append(standardizedURL)
    }

    return result.sorted { $0.path < $1.path }
}
