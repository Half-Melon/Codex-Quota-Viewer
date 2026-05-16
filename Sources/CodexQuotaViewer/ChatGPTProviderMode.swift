import Foundation

let chatGPTProviderModeStateFileName = "chatgpt-provider-mode.json"

func chatGPTProviderModeStateURL(baseURL: URL) -> URL {
    baseURL.appendingPathComponent(chatGPTProviderModeStateFileName, isDirectory: false)
}

func currentThreadSyncExpectedProviderID(
    currentProfile: ProviderProfile?,
    chatGPTProviderModeState: ChatGPTProviderModeState?,
    currentConfigData: Data?
) -> String? {
    if chatGPTProviderModeState != nil,
       let providerID = trimmedNonEmptyProviderID(parseRuntimeConfig(currentConfigData).threadProviderID) {
        return providerID
    }

    if let providerID = trimmedNonEmptyProviderID(currentProfile?.threadProviderID) {
        return providerID
    }

    if currentProfile?.authMode == .chatgpt {
        return "openai"
    }

    return nil
}

func activeChatGPTProviderModeRestorePointIDs(baseURL: URL) -> Set<String> {
    let url = chatGPTProviderModeStateURL(baseURL: baseURL)
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let restorePointID = object["restorePointID"] as? String,
          !restorePointID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return []
    }
    return [restorePointID]
}

struct ChatGPTProviderModeState: Codable, Equatable {
    let restorePointID: String
    let providerAccountID: String
    let providerDisplayName: String
    let activatedAt: Date
}

struct ChatGPTProviderModePreview: Equatable {
    let providerRecord: VaultAccountRecord
    let targetProviderID: String
    let filesToBackup: [URL]
    let rolloutFilesToUpdate: [URL]
    let codexWasRunning: Bool
}

struct ChatGPTProviderModeResult: Equatable {
    let providerAccountID: String
    let providerDisplayName: String
    let restorePoint: RestorePointManifest
    let updatedRolloutCount: Int
    let repairSummary: OfficialRepairSummary
}

struct ChatGPTProviderModeExitResult: Equatable {
    let restorePoint: RestorePointManifest
}

enum ChatGPTProviderModeError: LocalizedError, Equatable {
    case currentAccountIsNotChatGPT
    case providerAccountIsNotAPI
    case providerAccountMissingAPIKey(String)
    case providerAccountMissingBaseURL(String)
    case providerModeNotActive
    case automaticRollbackFailed
    case invalidAuthJSON

    var errorDescription: String? {
        switch self {
        case .currentAccountIsNotChatGPT:
            return AppLocalization.localized(
                en: "Third-party Provider mode requires the current Codex account to be signed in with ChatGPT.",
                zh: "第三方 Provider 模式需要当前 Codex 账号为 ChatGPT 登录。"
            )
        case .providerAccountIsNotAPI:
            return AppLocalization.localized(
                en: "Choose a saved API account as the third-party Provider.",
                zh: "请选择已保存的 API 账号作为第三方 Provider。"
            )
        case .providerAccountMissingAPIKey(let name):
            return AppLocalization.localized(
                en: "The saved API account “\(name)” does not contain an API key.",
                zh: "已保存的 API 账号“\(name)”没有 API Key。"
            )
        case .providerAccountMissingBaseURL(let name):
            return AppLocalization.localized(
                en: "The saved API account “\(name)” does not contain a Base URL.",
                zh: "已保存的 API 账号“\(name)”没有 Base URL。"
            )
        case .providerModeNotActive:
            return AppLocalization.localized(
                en: "Third-party Provider mode is not active.",
                zh: "第三方 Provider 模式未开启。"
            )
        case .automaticRollbackFailed:
            return AppLocalization.localized(
                en: "The operation failed and the automatic rollback could not be completed. Use the latest restore point to roll back manually.",
                zh: "操作失败，且自动回滚未能完成。请使用最新还原点手动回滚。"
            )
        case .invalidAuthJSON:
            return AppLocalization.localized(
                en: "auth.json is not valid JSON.",
                zh: "auth.json 不是有效的 JSON。"
            )
        }
    }
}

@MainActor
final class ChatGPTProviderModeManager {
    private let store: ProfileStore
    private let backupManager: BackupManager
    private let rolloutSynchronizer: RolloutProviderSynchronizer
    private let repairClient: OfficialThreadRepairing?
    private let desktopController: CodexDesktopControlling
    private let quotaChannelInvalidator: CodexRPCChannelInvalidating
    private let stateURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        store: ProfileStore,
        backupManager: BackupManager,
        rolloutSynchronizer: RolloutProviderSynchronizer = RolloutProviderSynchronizer(),
        repairClient: OfficialThreadRepairing? = nil,
        desktopController: CodexDesktopControlling,
        quotaChannelInvalidator: CodexRPCChannelInvalidating,
        stateURL: URL? = nil
    ) {
        self.store = store
        self.backupManager = backupManager
        self.rolloutSynchronizer = rolloutSynchronizer
        self.repairClient = repairClient
        self.desktopController = desktopController
        self.quotaChannelInvalidator = quotaChannelInvalidator
        self.stateURL = stateURL ?? chatGPTProviderModeStateURL(baseURL: store.baseURL)

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func currentModeState() throws -> ChatGPTProviderModeState? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return nil
        }
        return try decoder.decode(ChatGPTProviderModeState.self, from: Data(contentsOf: stateURL))
    }

    func isActive() throws -> Bool {
        try currentModeState() != nil
    }

    func preview(providerRecord: VaultAccountRecord) throws -> ChatGPTProviderModePreview {
        try validateCurrentAccountIsChatGPT()
        try validateAPIProviderRecord(providerRecord)
        let targetProviderID = try targetProviderID(for: providerRecord)
        let rolloutFilesToUpdate = try rolloutSynchronizer.plannedUpdates(
            in: [store.sessionsRootURL, store.archivedSessionsRootURL],
            targetProvider: targetProviderID
        )
        return ChatGPTProviderModePreview(
            providerRecord: providerRecord,
            targetProviderID: targetProviderID,
            filesToBackup: filesToBackup(rolloutFilesToUpdate: rolloutFilesToUpdate),
            rolloutFilesToUpdate: rolloutFilesToUpdate,
            codexWasRunning: desktopController.isRunning
        )
    }

    func enter(providerRecord: VaultAccountRecord) async throws -> ChatGPTProviderModeResult {
        _ = try preview(providerRecord: providerRecord)
        let previouslyRunning = try await desktopController.closeIfRunning()
        var restorePoint: RestorePointManifest?

        do {
            let latestPreview = try preview(providerRecord: providerRecord)
            let createdRestorePoint = try backupManager.createRestorePoint(
                reason: "chatgpt-provider-mode",
                summary: "Use third-party Provider \(providerRecord.metadata.displayName)",
                files: latestPreview.filesToBackup,
                codexWasRunning: previouslyRunning
            )
            restorePoint = createdRestorePoint
            let writer = ProtectedFileMutationContext(restorePoint: createdRestorePoint)

            let authData = try chatGPTProviderModeAuthData(from: store.currentAuthData())
            let targetConfigData = try chatGPTProviderModeConfigData(from: providerRecord)
            let mergedConfigData = try mergeRuntimeConfig(
                currentConfigData: store.currentConfigData(),
                targetConfigData: targetConfigData
            )
            let state = ChatGPTProviderModeState(
                restorePointID: createdRestorePoint.id,
                providerAccountID: providerRecord.id,
                providerDisplayName: providerRecord.metadata.displayName,
                activatedAt: Date()
            )

            try writer.write(authData, to: store.currentAuthURL)
            try writer.write(mergedConfigData, to: store.currentConfigURL)
            try writer.write(encoder.encode(state), to: stateURL)

            let rolloutResult = try rolloutSynchronizer.syncProviders(
                in: [store.sessionsRootURL, store.archivedSessionsRootURL],
                targetProvider: latestPreview.targetProviderID,
                writer: writer
            )
            let repairSummary = try await repairClient?.rescanAndRepair() ?? emptyOfficialRepairSummary()
            await quotaChannelInvalidator.invalidateAllReusableChannels()
            try await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)

            return ChatGPTProviderModeResult(
                providerAccountID: providerRecord.id,
                providerDisplayName: providerRecord.metadata.displayName,
                restorePoint: createdRestorePoint,
                updatedRolloutCount: rolloutResult.updatedFiles.count,
                repairSummary: repairSummary
            )
        } catch {
            if let restorePoint {
                do {
                    try backupManager.restoreRestorePoint(restorePoint)
                } catch {
                    try? await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)
                    throw ChatGPTProviderModeError.automaticRollbackFailed
                }
            }
            try? await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)
            throw error
        }
    }

    func exit() async throws -> ChatGPTProviderModeExitResult {
        guard let state = try currentModeState() else {
            throw ChatGPTProviderModeError.providerModeNotActive
        }

        let previouslyRunning = try await desktopController.closeIfRunning()

        do {
            let restored = try backupManager.restoreRestorePoint(id: state.restorePointID)
            try? FileManager.default.removeItem(at: stateURL)

            await quotaChannelInvalidator.invalidateAllReusableChannels()
            try await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)

            return ChatGPTProviderModeExitResult(restorePoint: restored)
        } catch {
            try? await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)
            throw error
        }
    }

    private func validateCurrentAccountIsChatGPT() throws {
        guard resolveAuthMode(authData: try store.currentAuthData()) == .chatgpt else {
            throw ChatGPTProviderModeError.currentAccountIsNotChatGPT
        }
    }

    private func validateAPIProviderRecord(_ record: VaultAccountRecord) throws {
        guard record.metadata.authMode == .apiKey
                || resolveAuthMode(authData: record.runtimeMaterial.authData) == .apiKey else {
            throw ChatGPTProviderModeError.providerAccountIsNotAPI
        }
        _ = try apiKey(from: record)
        _ = try providerBaseURL(from: record)
    }

    private func targetProviderID(for record: VaultAccountRecord) throws -> String {
        let configData = try chatGPTProviderModeConfigData(from: record)
        let summary = parseRuntimeConfig(configData)
        guard let providerID = summary.threadProviderID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerID.isEmpty else {
            return "OpenAI"
        }
        return providerID
    }

    private func filesToBackup(rolloutFilesToUpdate: [URL]) -> [URL] {
        deduplicatedStandardizedFileURLs(
            store.protectedMutationFileURLs(additionalFiles: rolloutFilesToUpdate + [stateURL])
        )
    }
}

private func emptyOfficialRepairSummary() -> OfficialRepairSummary {
    OfficialRepairSummary(
        createdThreads: 0,
        updatedThreads: 0,
        updatedSessionIndexEntries: 0,
        removedBrokenThreads: 0,
        hiddenSnapshotOnlySessions: 0
    )
}

func chatGPTProviderModeAuthData(from authData: Data) throws -> Data {
    guard var object = try JSONSerialization.jsonObject(with: authData) as? [String: Any] else {
        throw ChatGPTProviderModeError.invalidAuthJSON
    }

    object["auth_mode"] = "chatgpt"
    object["OPENAI_API_KEY"] = NSNull()

    guard JSONSerialization.isValidJSONObject(object) else {
        throw ChatGPTProviderModeError.invalidAuthJSON
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
}

func chatGPTProviderModeConfigData(from record: VaultAccountRecord) throws -> Data {
    let apiKey = try apiKey(from: record)
    let baseURL = try providerBaseURL(from: record)
    let model = parseRuntimeConfig(record.runtimeMaterial.configData).model ?? record.metadata.model
    return synthesizedChatGPTProviderModeConfig(baseURL: baseURL, apiKey: apiKey, model: model)
}

func synthesizedChatGPTProviderModeConfig(
    baseURL: String,
    apiKey: String,
    model: String?
) -> Data {
    let normalizedBaseURL = normalizedOpenAICompatibleProviderModeBaseURL(from: baseURL)
    let normalizedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)

    var lines = ["model_provider = \"OpenAI\""]
    if let normalizedModel,
       !normalizedModel.isEmpty {
        lines.append("model = \"\(escapedTOMLString(normalizedModel))\"")
    }

    lines.append("")
    lines.append("[model_providers.OpenAI]")
    lines.append("name = \"OpenAI\"")
    lines.append("base_url = \"\(escapedTOMLString(normalizedBaseURL))\"")
    lines.append("wire_api = \"responses\"")
    lines.append("experimental_bearer_token = \"\(escapedTOMLString(apiKey))\"")
    lines.append("requires_openai_auth = true")

    return Data((lines.joined(separator: "\n") + "\n").utf8)
}

private func trimmedNonEmptyProviderID(_ rawValue: String?) -> String? {
    let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
}

private func apiKey(from record: VaultAccountRecord) throws -> String {
    guard let envelope = try? JSONDecoder().decode(AuthEnvelope.self, from: record.runtimeMaterial.authData),
          let apiKey = envelope.openAIAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines),
          !apiKey.isEmpty else {
        throw ChatGPTProviderModeError.providerAccountMissingAPIKey(record.metadata.displayName)
    }
    return apiKey
}

private func providerBaseURL(from record: VaultAccountRecord) throws -> String {
    let summary = parseRuntimeConfig(record.runtimeMaterial.configData)
    let rawBaseURL = summary.baseURL ?? record.metadata.baseURL
    guard let rawBaseURL = rawBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawBaseURL.isEmpty else {
        throw ChatGPTProviderModeError.providerAccountMissingBaseURL(record.metadata.displayName)
    }
    return rawBaseURL
}

private func normalizedOpenAICompatibleProviderModeBaseURL(from rawValue: String) -> String {
    (try? normalizedOpenAICompatibleBaseURL(from: rawValue, ensureV1: true))
        ?? normalizedLooseBaseURL(from: rawValue)
        ?? rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
}
