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
