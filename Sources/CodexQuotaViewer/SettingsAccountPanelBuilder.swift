import Foundation

func buildSettingsAccountPanelState(
    vaultSnapshot: AccountVaultSnapshot?,
    vaultProfiles: [ProviderProfile],
    currentProviderProfile: ProviderProfile?,
    refreshIntervalPreset: RefreshIntervalPreset,
    actionsEnabled: Bool
) -> SettingsAccountPanelState {
    let inputs = (vaultSnapshot?.accounts ?? []).map { record in
        let matchingProfile = vaultProfiles.first(where: { $0.id == record.id })
            ?? currentProviderProfile.flatMap {
                stableRuntimeIdentityMatches($0.runtimeMaterial, record.runtimeMaterial) ? $0 : nil
            }
        let isCurrent = matchingProfile?.isCurrent
            ?? currentProviderProfile.map { stableRuntimeIdentityMatches($0.runtimeMaterial, record.runtimeMaterial) }
            ?? false

        return SettingsAccountPresentationInput(
            id: record.id,
            title: record.metadata.displayName,
            authMode: record.metadata.authMode,
            state: settingsAccountState(
                for: matchingProfile,
                refreshIntervalPreset: refreshIntervalPreset
            ),
            isCurrent: isCurrent,
            lastUsedAt: record.metadata.lastUsedAt,
            host: displayHost(from: record.metadata.baseURL),
            model: record.metadata.model
        )
    }

    return SettingsAccountPanelState(
        importStatusText: AppLocalization.accountVaultSummary(savedCount: vaultSnapshot?.accounts.count ?? 0),
        sections: buildSettingsAccountSections(inputs),
        actionsEnabled: actionsEnabled
    )
}

private func settingsAccountState(
    for profile: ProviderProfile?,
    refreshIntervalPreset: RefreshIntervalPreset
) -> SettingsAccountState {
    guard let profile else {
        return .healthy
    }

    switch quotaTileState(
        for: profile,
        refreshIntervalPreset: refreshIntervalPreset
    ) {
    case .healthy:
        return .healthy
    case .lowQuota:
        return .limited
    case .stale, .signInRequired, .expired, .readFailure:
        return .attention
    }
}
