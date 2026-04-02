import Foundation

enum RuntimeConfigMergeError: LocalizedError {
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return AppLocalization.localized(en: "Runtime config is not valid UTF-8.", zh: "运行时配置不是有效的 UTF-8。")
        }
    }
}

func mergeRuntimeConfig(
    currentConfigData: Data?,
    targetConfigData: Data?
) throws -> Data {
    let current = try TOMLDocument(data: currentConfigData)
    let target = try TOMLDocument(data: targetConfigData)

    let targetRootKeys = Set(target.rootLines.compactMap(rootAssignmentKey(from:)))
    let targetSectionNames = Set(target.sections.map(\.name))

    let filteredCurrentRoot = current.rootLines.filter { line in
        guard let key = rootAssignmentKey(from: line) else {
            return true
        }
        return key != "model_provider" && !targetRootKeys.contains(key)
    }

    let filteredCurrentSections = current.sections.filter { section in
        !targetSectionNames.contains(section.name)
    }

    var outputLines: [String] = []
    append(lines: filteredCurrentRoot, to: &outputLines)
    append(lines: target.rootLines, to: &outputLines)

    for section in target.sections {
        append(section: section, to: &outputLines)
    }

    for section in filteredCurrentSections {
        append(section: section, to: &outputLines)
    }

    let joined = trimBlankLines(outputLines).joined(separator: "\n")
    return Data((joined.isEmpty ? "" : joined + "\n").utf8)
}

private struct TOMLDocument {
    struct Section {
        let name: String
        let headerLine: String
        let bodyLines: [String]
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
            throw RuntimeConfigMergeError.invalidUTF8
        }

        var root: [String] = []
        var parsedSections: [Section] = []
        var currentSectionName: String?
        var currentHeaderLine: String?
        var currentBody: [String] = []

        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if let sectionName = sectionName(from: line) {
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
}

private func rootAssignmentKey(from line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          !trimmed.hasPrefix("#"),
          !trimmed.hasPrefix("["),
          let equalsIndex = trimmed.firstIndex(of: "=") else {
        return nil
    }

    return trimmed[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
}

private func sectionName(from line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("["),
          trimmed.hasSuffix("]") else {
        return nil
    }

    return String(trimmed.dropFirst().dropLast())
}

private func append(lines: [String], to output: inout [String]) {
    let trimmedLines = trimBlankLines(lines)
    guard !trimmedLines.isEmpty else {
        return
    }

    if !output.isEmpty,
       output.last?.isEmpty == false {
        output.append("")
    }
    output.append(contentsOf: trimmedLines)
}

private func append(section: TOMLDocument.Section, to output: inout [String]) {
    if !output.isEmpty,
       output.last?.isEmpty == false {
        output.append("")
    }

    output.append(section.headerLine)
    output.append(contentsOf: trimTrailingBlankLines(section.bodyLines))
}

private func trimBlankLines(_ lines: [String]) -> [String] {
    trimTrailingBlankLines(trimLeadingBlankLines(lines))
}

private func trimLeadingBlankLines(_ lines: [String]) -> [String] {
    Array(lines.drop { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
}

private func trimTrailingBlankLines(_ lines: [String]) -> [String] {
    Array(lines.reversed().drop { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.reversed())
}
