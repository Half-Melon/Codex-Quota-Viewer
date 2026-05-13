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

Run on Windows:

```powershell
scripts\build-windows-tray.ps1
```

Before building, place the Windows Node runtime under:

```text
WindowsTray\src-tauri\NodeRuntime\
```

The runtime directory must contain `node.exe`.
