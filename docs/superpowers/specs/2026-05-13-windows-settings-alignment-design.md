# Windows Settings Alignment Design

## Goal

Bring the Windows tray app closer to the macOS app by adding the first real
settings layer. This phase focuses on General settings only: refresh interval,
language, launch at login, and tray display style.

The Windows app should remain a tray-first utility. It should not show a main
window on startup. The settings window opens only when the user chooses
`Settings...` from the tray menu.

## Scope

This phase includes:

- Persistent Windows settings stored in the app data directory.
- A Tauri settings window for General settings.
- Tray menu text and settings UI localization for English and Chinese.
- Configurable automatic quota refresh.
- Launch-at-login support on Windows.
- A tray display style setting that establishes the same contract as macOS.

This phase does not include:

- Multiple-account vault management.
- ChatGPT sign-in onboarding inside the Windows app.
- API account creation.
- Safe account switching.
- Restore points or rollback.
- Session Manager language bridging.
- A full macOS feature rewrite in Tauri.

## Current Context

The existing Windows Tauri MVP already provides:

- A tray icon and tray menu.
- Current active Codex account quota refresh.
- Manual `Refresh Quota`.
- `Open Session Manager`.
- `Open Codex Folder`.
- Clean quit that stops only the owned Session Manager sidecar.

The macOS app already has a broader settings model in `AppSettings`:

- `refreshIntervalPreset`
- `launchAtLoginEnabled`
- `statusItemStyle`
- `appLanguage`
- `lastResolvedLanguage`
- `preferredAccountID`

The Windows settings model should use compatible field names where practical so
future cross-platform account and settings behavior can share concepts.

## User Experience

The tray menu gains a `Settings...` item near the existing maintenance actions.
Choosing it opens a small Windows settings window with one General page.

The General page contains:

- `Refresh interval`: `Manual`, `1 minute`, `5 minutes`, `15 minutes`.
- `Language`: `Follow System`, `English`, `Chinese`.
- `Tray style`: `Meter`, `Text`.
- `Launch at login`: checkbox.

The settings window applies changes immediately and persists them. If a setting
cannot be applied, the app should keep the previous value and show a concise
error state in the settings window.

The app still starts hidden in the tray. Closing the settings window hides or
closes that window only; it does not quit the tray app.

## Settings Storage

Add a Windows settings module in Rust.

Suggested file:

```text
WindowsTray/src-tauri/src/settings.rs
```

Settings are stored under Tauri's app data directory:

```text
%APPDATA%\Codex Quota Viewer\settings.json
```

The JSON shape should be compatible with the macOS names:

```json
{
  "refreshIntervalPreset": "fiveMinutes",
  "launchAtLoginEnabled": false,
  "statusItemStyle": "meter",
  "appLanguage": "system",
  "lastResolvedLanguage": "english"
}
```

`preferredAccountID` is intentionally not used in this phase because Windows
does not yet have account vault support.

Default values:

- `refreshIntervalPreset`: `fiveMinutes`
- `launchAtLoginEnabled`: `false`
- `statusItemStyle`: `meter`
- `appLanguage`: `system`

If the settings file is missing, defaults are used. If it is corrupted, the app
uses defaults and reports a recoverable settings error rather than failing to
start.

## Localization

Add a small Windows localization module that resolves app language from:

1. Explicit setting: `english` or `chinese`.
2. System language when the setting is `system`.
3. English fallback.

The first implementation localizes:

- Tray menu labels.
- Tray loading/error labels.
- Settings window labels.
- Settings option display names.

The Codex RPC error categories can remain stable English strings internally,
but user-facing menu labels should pass through the localization layer.

Session Manager language bridging is deferred because it touches a separate web
app configuration path and should be implemented as a focused follow-up.

## Refresh Behavior

The app currently refreshes on startup and on manual request. This phase adds a
refresh scheduler:

- On startup, load settings before installing the final tray menu.
- If `refreshIntervalPreset` is not `manual`, start a repeating timer.
- On settings changes, cancel the previous timer and install a new one.
- Manual refresh remains available in every mode.
- A refresh already in progress should not be duplicated by a timer tick.

Intervals match macOS:

- `manual`: no timer
- `oneMinute`: 60 seconds
- `fiveMinutes`: 300 seconds
- `fifteenMinutes`: 900 seconds

The stale-state polish from macOS is not required in this phase, but the design
should leave room to add it by keeping `fetched_at` and the current settings in
shared app state.

## Tray Style

Windows tray APIs are more constrained than macOS menu bar rendering. This
phase still adds `statusItemStyle` because it is part of the shared user-facing
settings contract.

Behavior:

- `text`: the tray menu quota row uses the current textual format, such as
  `5h: 42%   1w: 88%`.
- `meter`: keep the same textual menu row for now, but use this value as the
  future contract for richer tray icon rendering.

This avoids pretending Windows has feature parity before the icon-rendering work
exists, while preserving the setting needed to align later.

## Launch At Login

Add a Windows launch-at-login manager behind a small interface.

The implementation may use the Tauri autostart plugin or a native Windows
Startup-folder/registry approach, selected during implementation based on the
least invasive dependency fit for the current Tauri app.

Behavior:

- When the checkbox is enabled, register the installed app to launch at login.
- When disabled, unregister it.
- If registration fails, do not persist the new setting.
- If settings persistence fails after registration changed, attempt to restore
  the previous launch-at-login state.

This mirrors the macOS transaction behavior in `applySettingsTransaction`.

## Tauri API Surface

Expose a small command surface from Rust to the frontend:

- `get_settings() -> SettingsPresentation`
- `update_settings(updated: AppSettings) -> SettingsPresentation`
- `get_settings_options() -> SettingsOptions`

`SettingsPresentation` should include:

- Current settings.
- Resolved language.
- Optional warning or error message.
- Localized display labels for controls and options.

The frontend should not duplicate business rules for settings defaults,
language resolution, launch-at-login behavior, or timer management.

## Frontend Shape

The existing TypeScript entry is minimal. Extend it into a small settings UI
without introducing a heavy framework.

Suggested files:

```text
WindowsTray/src/main.ts
WindowsTray/src/styles.css
```

The hidden default window can become the settings window. The app should still
start with the window hidden, and the tray `Settings...` item should show and
focus it.

The UI should be quiet and native-feeling:

- Compact form rows.
- Standard selects and checkbox.
- A small status/error message area.
- No marketing content or decorative panels.

## App State

Extend shared state with:

- Loaded `AppSettings`.
- Last settings load issue, if any.
- Refresh scheduler handle or cancellation token.

Settings updates must:

1. Validate and apply side effects.
2. Persist settings.
3. Update shared state.
4. Rebuild the tray menu with localized labels.
5. Restart the refresh scheduler if the interval changed.
6. Return a fresh settings presentation to the window.

## Error Handling

Add settings-specific errors:

- Settings file corrupted.
- Settings save failed.
- Launch-at-login setup failed.

Error handling rules:

- Startup should continue with defaults when settings cannot be read.
- Failed updates should keep the previous settings.
- Tray menu should stay usable even when the settings window reports an error.
- Diagnostics can remain in logs or internal messages; visible text should be
  short and understandable.

## Testing

Rust unit tests should cover:

- Default settings decode when the file is missing.
- Backward-compatible decode with missing fields.
- Corrupted settings file returns defaults plus a load issue.
- Save and reload round trip.
- Refresh interval conversion.
- Settings transaction rollback when launch-at-login sync fails.
- Settings transaction rollback when save fails after launch-at-login changes.
- Language resolution for explicit and system settings.

Frontend checks should cover:

- TypeScript compile.
- Rendering settings values returned from Rust.
- Calling update commands when controls change.

Manual Windows verification should cover:

- App still starts hidden in tray.
- `Settings...` opens and focuses the settings window.
- Refresh interval changes start and stop automatic refresh.
- `Manual` disables automatic refresh while preserving manual refresh.
- Language changes update the tray menu and settings labels.
- Launch-at-login enable/disable reports success or a clear error.
- Quitting the tray app still stops only the owned Session Manager sidecar.

## Rollout Order

1. Add settings models, persistence, localization, and transaction tests.
2. Add refresh scheduler and wire it to loaded settings.
3. Add tray `Settings...` menu item and localized menu labels.
4. Add Tauri settings commands.
5. Build the settings window UI.
6. Add launch-at-login side effect.
7. Verify Rust tests, TypeScript checks, and manual Windows behavior.

This order keeps the behavioral foundation testable before introducing the
frontend surface.
