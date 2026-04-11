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
    let current: LightweightTOMLDocument
    let target: LightweightTOMLDocument
    do {
        current = try LightweightTOMLDocument(data: currentConfigData)
        target = try LightweightTOMLDocument(data: targetConfigData)
    } catch LightweightTOMLDocumentError.invalidUTF8 {
        throw RuntimeConfigMergeError.invalidUTF8
    }

    let targetRootKeys = Set(target.rootLines.compactMap(tomlAssignmentKey(from:)))
    let targetSectionNames = Set(target.sections.map(\.name))

    let filteredCurrentRoot = current.rootLines.filter { line in
        guard let key = tomlAssignmentKey(from: line) else {
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

private func append(section: LightweightTOMLDocument.Section, to output: inout [String]) {
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
