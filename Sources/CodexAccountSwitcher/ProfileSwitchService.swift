import Foundation

protocol CodexRPCClientProtocol: Sendable {
    func fetchCurrentSnapshot() async throws -> CodexSnapshot
    func fetchSnapshot(authData: Data) async throws -> CodexSnapshot
}

protocol CodexAppManaging: Sendable {
    func isCodexRunning() -> Bool
    func terminateCodex() async throws
    func launchCodex(activate: Bool) throws
}

struct ProfileSwitchResult {
    let expectedSnapshot: CodexSnapshot
    let verifiedSnapshot: CodexSnapshot
}

enum ProfileSwitchError: LocalizedError {
    case verificationFailed(expected: String, actual: String)
    case rolledBack(reason: String)

    var errorDescription: String? {
        switch self {
        case .verificationFailed(let expected, let actual):
            return "切换后账号校验失败。预期 \(expected)，实际 \(actual)"
        case .rolledBack(let reason):
            return "切换失败，已回滚：\(reason)"
        }
    }
}

@MainActor
final class ProfileSwitchService {
    private let store: ProfileStore
    private let rpcClient: any CodexRPCClientProtocol
    private let appManager: any CodexAppManaging

    init(
        store: ProfileStore,
        rpcClient: any CodexRPCClientProtocol,
        appManager: any CodexAppManaging
    ) {
        self.store = store
        self.rpcClient = rpcClient
        self.appManager = appManager
    }

    func switchToProfile(
        targetProfile: CodexProfile,
        activeProfileID: UUID?,
        currentSnapshot: CodexSnapshot?,
        autoOpenCodexAfterSwitch: Bool
    ) async throws -> ProfileSwitchResult {
        let originalAuth = try store.currentAuthData()
        let wasCodexRunning = appManager.isCodexRunning()

        if let activeProfileID, let currentSnapshot {
            try store.updateProfile(
                id: activeProfileID,
                authData: originalAuth,
                snapshot: currentSnapshot.cached
            )
        }

        let targetAuth = try store.readAuthData(for: targetProfile.id)
        let expectedSnapshot = try await rpcClient.fetchSnapshot(authData: targetAuth)

        var didOverwriteCurrentAuth = false

        do {
            try store.overwriteCurrentAuthData(targetAuth)
            didOverwriteCurrentAuth = true

            try await appManager.terminateCodex()

            let verifiedSnapshot = try await rpcClient.fetchCurrentSnapshot()
            guard verifiedSnapshot.account.matchesIdentity(expectedSnapshot.account) else {
                throw ProfileSwitchError.verificationFailed(
                    expected: expectedSnapshot.account.displayLabel,
                    actual: verifiedSnapshot.account.displayLabel
                )
            }

            if autoOpenCodexAfterSwitch {
                try appManager.launchCodex(activate: true)
            }

            return ProfileSwitchResult(
                expectedSnapshot: expectedSnapshot,
                verifiedSnapshot: verifiedSnapshot
            )
        } catch {
            guard didOverwriteCurrentAuth else {
                throw error
            }

            try? store.overwriteCurrentAuthData(originalAuth)
            if wasCodexRunning {
                try? appManager.launchCodex(activate: true)
            }

            let reason: String
            if let localized = error as? LocalizedError,
               let description = localized.errorDescription {
                reason = description
            } else {
                reason = error.localizedDescription
            }

            throw ProfileSwitchError.rolledBack(reason: reason)
        }
    }
}
