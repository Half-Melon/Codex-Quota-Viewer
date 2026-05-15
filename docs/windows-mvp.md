# Windows Tray MVP

The Windows MVP is a Tauri-based system tray app for Codex Quota Viewer.

## Features

- Shows the current active Codex account quota in the Windows system tray menu.
- Supports manual quota refresh.
- Opens a General settings window from the tray.
- Persists refresh interval, language, tray style, and launch-at-login settings.
- Supports automatic quota refresh when the refresh interval is not `Manual`.
- Opens the bundled Session Manager on `http://127.0.0.1:4318`.
- Opens the local Codex folder.
- Quits cleanly and stops only the Session Manager process it started.
- Saves multiple ChatGPT and API accounts in a local Windows account vault.
- Imports the current local ChatGPT Codex login as a saved account.
- Adds OpenAI-compatible API accounts from the Windows settings window.
- Activates saved accounts directly into the resolved Codex home.
- Shows saved accounts in an `All Accounts` tray submenu.

## Local Data

The MVP reads the active Codex profile from `%USERPROFILE%\.codex` unless
`CODEX_HOME` is set.

## Account Activation

Windows account activation currently writes directly into the resolved Codex
home. It does not yet create restore points or perform the full Safe Switch
repair flow available in the macOS app. Use the confirmation prompt as the
boundary for this direct activation behavior.

## Not Included In The MVP

- Full Safe Switch orchestration.
- Rollback restore points.
- Thread/provider repair after account activation.

## Build

Prerequisites:

- Node available through `PATH`.
- Rust/Cargo available through `PATH`.
- Windows native build tools required by Tauri.

Run on Windows:

```powershell
scripts\build-windows-tray.ps1
```

The build script stages the bundled Session Manager, installs its production
dependencies, and prepares `WindowsTray\src-tauri\NodeRuntime\node.exe` in the
ignored staging directory. If `node.exe` is not already staged, the script first
copies the local Node executable from `PATH`; if Node is not installed locally,
it downloads the official Windows Node v22 runtime.
