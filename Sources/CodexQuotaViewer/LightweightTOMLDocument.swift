import Foundation

enum LightweightTOMLDocumentError: Error {
    case invalidUTF8
}

// Supports the limited TOML subset used by Codex runtime config files:
// root assignments, single-bracket sections, inline comments, quoted strings, and booleans.
// It intentionally does not implement full TOML parsing.
struct LightweightTOMLDocument {
    struct Section {
        let name: String
        let headerLine: String
        let bodyLines: [String]

        func assignmentValue(forKey key: String) -> String? {
            firstAssignmentValue(in: bodyLines, forKey: key)
        }

        func boolAssignmentValue(forKey key: String) -> Bool? {
            assignmentValue(forKey: key).flatMap(normalizedTOMLBoolean)
        }
    }

    let rootLines: [String]
    let sections: [Section]

    init(data: Data?) throws {
        guard let data else {
            rootLines = []
            sections = []
            return
        }

        guard let raw = String(data: data, encoding: .utf8) else {
            throw LightweightTOMLDocumentError.invalidUTF8
        }

        var root: [String] = []
        var parsedSections: [Section] = []
        var currentSectionName: String?
        var currentHeaderLine: String?
        var currentBody: [String] = []

        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if let sectionName = tomlSectionName(from: line) {
                if let currentSectionName,
                   let currentHeaderLine {
                    parsedSections.append(
                        Section(
                            name: currentSectionName,
                            headerLine: currentHeaderLine,
                            bodyLines: currentBody
                        )
                    )
                }

                currentSectionName = sectionName
                currentHeaderLine = line
                currentBody = []
                continue
            }

            if currentSectionName == nil {
                root.append(line)
            } else {
                currentBody.append(line)
            }
        }

        if let currentSectionName,
           let currentHeaderLine {
            parsedSections.append(
                Section(
                    name: currentSectionName,
                    headerLine: currentHeaderLine,
                    bodyLines: currentBody
                )
            )
        }

        rootLines = root
        sections = parsedSections
    }

    func rootAssignmentValue(forKey key: String) -> String? {
        firstAssignmentValue(in: rootLines, forKey: key)
    }

    func section(named name: String) -> Section? {
        sections.first { $0.name == name }
    }
}

func tomlAssignmentKey(from line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          !trimmed.hasPrefix("#"),
          !trimmed.hasPrefix("["),
          let equalsIndex = trimmed.firstIndex(of: "=") else {
        return nil
    }

    return trimmed[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
}

func tomlSectionName(from line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("["),
          trimmed.hasSuffix("]") else {
        return nil
    }

    return String(trimmed.dropFirst().dropLast())
}

func normalizedTOMLValue<S: StringProtocol>(_ rawValue: S) -> String {
    var value = String(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
    value = strippingInlineTOMLComment(from: value)
    if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value.removeFirst()
        value.removeLast()
    }
    return value
}

func normalizedTOMLBoolean(_ rawValue: String) -> Bool? {
    switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "true":
        return true
    case "false":
        return false
    default:
        return nil
    }
}

func strippingInlineTOMLComment(from rawValue: String) -> String {
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

private func firstAssignmentValue(
    in lines: [String],
    forKey key: String
) -> String? {
    for line in lines {
        guard tomlAssignmentKey(from: line) == key,
              let equalsIndex = line.firstIndex(of: "=") else {
            continue
        }

        return normalizedTOMLValue(line[line.index(after: equalsIndex)...])
    }

    return nil
}
