import Foundation

struct CurrentSnapshotFetcher: Sendable {
    let fetchFromRuntimeMaterial: @Sendable (ProfileRuntimeMaterial) async throws -> CodexSnapshot
    let fetchFromCodexHome: @Sendable (URL) async throws -> CodexSnapshot

    init(
        fetchFromRuntimeMaterial: @escaping @Sendable (ProfileRuntimeMaterial) async throws -> CodexSnapshot,
        fetchFromCodexHome: @escaping @Sendable (URL) async throws -> CodexSnapshot
    ) {
        self.fetchFromRuntimeMaterial = fetchFromRuntimeMaterial
        self.fetchFromCodexHome = fetchFromCodexHome
    }

    func fetch(
        currentRuntimeMaterial: ProfileRuntimeMaterial?,
        codexHomeURL: URL
    ) async throws -> CodexSnapshot {
        if let currentRuntimeMaterial {
            return try await fetchFromRuntimeMaterial(currentRuntimeMaterial)
        }

        return try await fetchFromCodexHome(codexHomeURL)
    }
}
