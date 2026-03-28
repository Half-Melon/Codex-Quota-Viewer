import Foundation

func applySettingsTransaction(
    previous: AppSettings,
    updated: AppSettings,
    syncLaunchAtLogin: (Bool) throws -> Void,
    saveSettings: (AppSettings) throws -> Void
) throws -> AppSettings {
    let launchAtLoginChanged = previous.launchAtLoginEnabled != updated.launchAtLoginEnabled

    if launchAtLoginChanged {
        try syncLaunchAtLogin(updated.launchAtLoginEnabled)
    }

    do {
        try saveSettings(updated)
        return updated
    } catch {
        if launchAtLoginChanged {
            try? syncLaunchAtLogin(previous.launchAtLoginEnabled)
        }
        throw error
    }
}
