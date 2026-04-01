import Foundation

struct AccountOnboardingProcessCommand {
    let codexExecutableURL: URL
    let homeURL: URL
    let codexHomeURL: URL
    let useDeviceAuth: Bool
}

struct AccountOnboardingProcessResult: Equatable {
    let exitStatus: Int32
    let standardOutput: String
    let standardError: String
}

struct AccountOnboardingResult: Equatable {
    let record: VaultAccountRecord
    let restorePoint: RestorePointManifest
    let warningMessage: String?
}

struct DeviceAuthInstructions: Equatable {
    let verificationURL: String
    let userCode: String
}

enum AccountOnboardingError: LocalizedError {
    case codexExecutableMissing
    case loginFailed(String)
    case missingAuthMaterial

    var errorDescription: String? {
        switch self {
        case .codexExecutableMissing:
            return AppLocalization.localized(
                en: "Bundled codex executable was not found.",
                zh: "找不到内置的 codex 可执行文件。"
            )
        case .loginFailed(let message):
            return message
        case .missingAuthMaterial:
            return AppLocalization.localized(
                en: "Codex login did not produce auth.json.",
                zh: "Codex 登录后没有生成 auth.json。"
            )
        }
    }
}

@MainActor
final class AccountOnboardingCoordinator {
    typealias ProcessRunner = @Sendable (AccountOnboardingProcessCommand) async throws -> AccountOnboardingProcessResult
    typealias ProtectedFilesProvider = ([String]) throws -> [URL]

    private let vaultStore: VaultAccountStore
    private let backupManager: BackupManager?
    private let protectedFilesProvider: ProtectedFilesProvider?
    private let processRunner: ProcessRunner
    private let apiModelsProbe: APIModelsProbing
    private let fileManager: FileManager
    private let codexExecutableURL: URL

    init(
        vaultStore: VaultAccountStore,
        backupManager: BackupManager? = nil,
        protectedFilesProvider: ProtectedFilesProvider? = nil,
        codexExecutableURL: URL = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex", isDirectory: false),
        fileManager: FileManager = .default,
        apiModelsProbe: APIModelsProbing = URLSessionAPIModelsProbe(),
        processRunner: ProcessRunner? = nil
    ) {
        self.vaultStore = vaultStore
        self.backupManager = backupManager
        self.protectedFilesProvider = protectedFilesProvider
        self.codexExecutableURL = codexExecutableURL
        self.fileManager = fileManager
        self.apiModelsProbe = apiModelsProbe
        self.processRunner = processRunner ?? Self.defaultProcessRunner
    }

    func addChatGPTAccount(useDeviceAuth: Bool = false) async throws -> AccountOnboardingResult {
        try await addChatGPTAccount(
            useDeviceAuth: useDeviceAuth,
            deviceAuthHandler: nil
        )
    }

    func addChatGPTAccount(
        useDeviceAuth: Bool,
        deviceAuthHandler: ((DeviceAuthInstructions) -> Void)?
    ) async throws -> AccountOnboardingResult {
        guard fileManager.isExecutableFile(atPath: codexExecutableURL.path) else {
            throw AccountOnboardingError.codexExecutableMissing
        }

        let tempHome = fileManager.temporaryDirectory
            .appendingPathComponent("\(AppIdentity.temporaryDirectoryPrefix)-login-\(UUID().uuidString)", isDirectory: true)
        let tempCodexHome = tempHome.appendingPathComponent(".codex", isDirectory: true)

        try fileManager.createDirectory(at: tempCodexHome, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempHome)
        }

        let command = AccountOnboardingProcessCommand(
            codexExecutableURL: codexExecutableURL,
            homeURL: tempHome,
            codexHomeURL: tempCodexHome,
            useDeviceAuth: useDeviceAuth
        )
        let result = try await (
            useDeviceAuth
                ? runDeviceAuthProcess(command: command, deviceAuthHandler: deviceAuthHandler)
                : processRunner(command)
        )
        guard result.exitStatus == 0 else {
            let diagnostic = [result.standardError, result.standardOutput]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? AppLocalization.localized(
                    en: "Codex login failed.",
                    zh: "Codex 登录失败。"
                )
            throw AccountOnboardingError.loginFailed(diagnostic)
        }

        let authURL = tempCodexHome.appendingPathComponent("auth.json", isDirectory: false)
        guard fileManager.fileExists(atPath: authURL.path) else {
            throw AccountOnboardingError.missingAuthMaterial
        }

        let authData = try Data(contentsOf: authURL)
        let configURL = tempCodexHome.appendingPathComponent("config.toml", isDirectory: false)
        let configData = fileManager.fileExists(atPath: configURL.path)
            ? try Data(contentsOf: configURL)
            : nil
        let runtime = ProfileRuntimeMaterial(authData: authData, configData: configData)
        let accountID = vaultStore.accountID(for: canonicalRuntimeMaterialForStorage(runtime))
        let restorePoint = try makeRestorePoint(
            summary: "Add ChatGPT account",
            accountIDs: [accountID]
        )
        let writer = ProtectedFileMutationContext(restorePoint: restorePoint)
        let stored = try vaultStore.upsertAccount(
            fallbackDisplayName: AppLocalization.localized(en: "ChatGPT Account", zh: "ChatGPT 账号"),
            source: .manualChatGPT,
            runtimeMaterial: runtime,
            writer: writer
        )

        return AccountOnboardingResult(
            record: stored.record,
            restorePoint: restorePoint,
            warningMessage: nil
        )
    }

    func addAPIAccount(
        apiKey: String,
        rawBaseURL: String,
        overrideDisplayName: String? = nil,
        overrideModel: String? = nil
    ) async throws -> AccountOnboardingResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw APIAccountAutoConfigurationError.missingAPIKey
        }

        let trimmedBaseURL = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBaseURL.isEmpty else {
            throw APIAccountAutoConfigurationError.missingBaseURL
        }

        let draft: APIAccountDraft
        do {
            let probeResult = try await apiModelsProbe.probeModels(
                apiKey: trimmedKey,
                rawBaseURL: trimmedBaseURL
            )
            draft = APIAccountDraft(
                displayName: normalizedAccountDisplayName(
                    overrideDisplayName,
                    normalizedBaseURL: probeResult.normalizedBaseURL
                ),
                apiKey: trimmedKey,
                normalizedBaseURL: probeResult.normalizedBaseURL,
                model: normalizedPreferredModel(overrideModel)
                    ?? preferredModelID(from: probeResult.modelIDs)
                    ?? "gpt-5.4",
                usedFallback: false,
                warningMessage: nil
            )
        } catch {
            draft = buildFallbackAPIAccountDraft(
                apiKey: trimmedKey,
                rawBaseURL: trimmedBaseURL,
                overrideDisplayName: overrideDisplayName,
                overrideModel: overrideModel
            )
        }

        let runtime = ProfileRuntimeMaterial(
            authData: makeAPIKeyAuthData(apiKey: draft.apiKey),
            configData: synthesizedOpenAICompatibleConfig(
                baseURL: draft.normalizedBaseURL,
                model: draft.model
            )
        )
        let accountID = vaultStore.accountID(for: canonicalRuntimeMaterialForStorage(runtime))
        let restorePoint = try makeRestorePoint(
            summary: "Add API account \(draft.displayName)",
            accountIDs: [accountID]
        )
        let writer = ProtectedFileMutationContext(restorePoint: restorePoint)
        let record = try vaultStore.createAPIAccount(
            displayName: draft.displayName,
            apiKey: draft.apiKey,
            baseURL: draft.normalizedBaseURL,
            model: draft.model,
            writer: writer
        )

        return AccountOnboardingResult(
            record: record,
            restorePoint: restorePoint,
            warningMessage: draft.warningMessage
        )
    }

    private func makeRestorePoint(
        summary: String,
        accountIDs: [String]
    ) throws -> RestorePointManifest {
        guard let backupManager,
              let protectedFilesProvider else {
            throw BackupManagerError.noRestorePoint
        }

        let files = try protectedFilesProvider(accountIDs)
        return try backupManager.createRestorePoint(
            reason: "account-onboarding",
            summary: summary,
            files: files,
            codexWasRunning: false
        )
    }

    private static func defaultProcessRunner(
        _ command: AccountOnboardingProcessCommand
    ) async throws -> AccountOnboardingProcessResult {
        let process = Process()
        process.executableURL = command.codexExecutableURL
        process.arguments = command.useDeviceAuth ? ["login", "--device-auth"] : ["login"]

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = command.homeURL.path
        environment["CODEX_HOME"] = command.codexHomeURL.path
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(
                    returning: AccountOnboardingProcessResult(
                        exitStatus: process.terminationStatus,
                        standardOutput: String(data: outputData, encoding: .utf8) ?? "",
                        standardError: String(data: errorData, encoding: .utf8) ?? ""
                    )
                )
            }
        }
    }

    private func runDeviceAuthProcess(
        command: AccountOnboardingProcessCommand,
        deviceAuthHandler: ((DeviceAuthInstructions) -> Void)?
    ) async throws -> AccountOnboardingProcessResult {
        let process = Process()
        process.executableURL = command.codexExecutableURL
        process.arguments = ["login", "--device-auth"]

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = command.homeURL.path
        environment["CODEX_HOME"] = command.codexHomeURL.path
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        let stdoutTask = Task<String, Never> {
            var collected = ""
            var didReportInstructions = false
            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    collected.append(line)
                    collected.append("\n")

                    if !didReportInstructions,
                       let instructions = parseDeviceAuthInstructions(from: collected) {
                        didReportInstructions = true
                        await MainActor.run {
                            deviceAuthHandler?(instructions)
                        }
                    }
                }
            } catch {
                // Ignore stream-read failures and return the output captured so far.
            }
            return collected
        }

        let stderrTask = Task<String, Never> {
            let data = try? stderr.fileHandleForReading.readToEnd()
            return String(data: data ?? Data(), encoding: .utf8) ?? ""
        }

        let exitStatus = await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
        }

        return AccountOnboardingProcessResult(
            exitStatus: exitStatus,
            standardOutput: await stdoutTask.value,
            standardError: await stderrTask.value
        )
    }

    private func parseDeviceAuthInstructions(from output: String) -> DeviceAuthInstructions? {
        let urlRange = output.range(of: #"https://\S+"#, options: .regularExpression)
        let codeRange = output.range(of: #"[A-Z0-9]{4,}-[A-Z0-9]{4,}"#, options: .regularExpression)

        guard let urlRange,
              let codeRange else {
            return nil
        }

        return DeviceAuthInstructions(
            verificationURL: String(output[urlRange]),
            userCode: String(output[codeRange])
        )
    }
}
