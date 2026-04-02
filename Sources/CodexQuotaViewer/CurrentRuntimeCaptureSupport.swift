import Foundation

enum CurrentRuntimeCaptureAction: Equatable {
    case skip
    case updateWithoutRestorePoint
    case captureWithRestorePoint
}

func currentRuntimeCaptureAction(
    currentRuntimeMaterial: ProfileRuntimeMaterial,
    existingRuntimeMaterial: ProfileRuntimeMaterial?
) -> CurrentRuntimeCaptureAction {
    let canonicalCurrent = canonicalRuntimeMaterialForStorage(currentRuntimeMaterial)

    guard let existingRuntimeMaterial else {
        return .captureWithRestorePoint
    }

    let canonicalExisting = canonicalRuntimeMaterialForStorage(existingRuntimeMaterial)
    if runtimeIdentityKey(for: canonicalExisting) == runtimeIdentityKey(for: canonicalCurrent) {
        return .skip
    }

    if currentRuntimeSwitchFingerprint(for: canonicalExisting) == currentRuntimeSwitchFingerprint(for: canonicalCurrent) {
        return .updateWithoutRestorePoint
    }

    return .captureWithRestorePoint
}

private func currentRuntimeSwitchFingerprint(
    for runtimeMaterial: ProfileRuntimeMaterial
) -> String {
    let canonicalRuntime = canonicalRuntimeMaterialForStorage(runtimeMaterial)
    let authMode = resolveAuthMode(authData: canonicalRuntime.authData)
    let authFingerprint: String

    switch authMode {
    case .chatgpt, .apiKey:
        authFingerprint = stableAccountIdentityKey(for: canonicalRuntime)
    case .unknown:
        authFingerprint = runtimeIdentityKey(authData: canonicalRuntime.authData)
    }

    return [
        authMode.rawValue,
        authFingerprint,
        canonicalConfigFingerprint(canonicalRuntime.configData),
    ]
    .joined(separator: "|")
}

private func canonicalConfigFingerprint(_ configData: Data?) -> String {
    guard let configData,
          var raw = String(data: configData, encoding: .utf8) else {
        return ""
    }

    raw = raw
        .replacingOccurrences(of: "\r\n", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return raw
}
