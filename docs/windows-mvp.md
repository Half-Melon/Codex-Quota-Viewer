# Windows Tray MVP

The Windows MVP is a Tauri-based system tray app for Codex Quota Viewer.

## Features

- Shows the current active Codex account quota in the Windows system tray menu.
- Supports manual quota refresh.
- Opens the bundled Session Manager on `http://127.0.0.1:4318`.
- Opens the local Codex folder.
- Quits cleanly and stops only the Session Manager process it started.

## Local Data

The MVP reads the active Codex profile from `%USERPROFILE%\.codex` unless
`CODEX_HOME` is set.

## Not Included In The MVP

- Multiple saved accounts.
- Safe account switching.
- Rollback restore points.
- Full settings UI.
- Launch at login.

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
