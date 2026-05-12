# Windows Tauri Tray MVP Design

## Goal

Create a Windows-usable MVP of Codex Quota Viewer as a right-side system tray
program. The MVP must show the current Codex account quota, support manual
refresh, open the bundled Session Manager, open the local Codex folder, and
quit cleanly.

The existing macOS Swift/AppKit app remains intact. The Windows MVP is added as
an independent Tauri application so the current macOS release line is not
disrupted.

## Confirmed Approach

Use a new Tauri-based Windows tray app.

- Tauri provides the Windows tray shell, menu handling, packaging, and native
  integration.
- Rust owns the Windows backend work: quota refresh, Codex home path
  resolution, sidecar process lifecycle, and error classification.
- The existing vendored Session Manager under `Vendor/CodexMM` remains the
  browser-based session console.
- A Windows Node runtime is bundled as a sidecar so end users do not need to
  install Node separately.

## Repository Shape

Add a new Windows app directory, for example `WindowsTray/` or
`Apps/WindowsTray/`.

Expected structure:

```text
WindowsTray/
  package.json
  src/
    main.ts
  src-tauri/
    Cargo.toml
    tauri.conf.json
    src/
      main.rs
      codex_home.rs
      quota.rs
      session_manager.rs
      tray.rs
```

The existing macOS app stays in:

```text
Sources/CodexQuotaViewer/
```

The existing Session Manager source stays in:

```text
Vendor/CodexMM/
```

Build scripts may add generated Windows bundle resources under an ignored build
directory, not under source control.

## MVP Tray Menu

The tray menu must include:

- Current account summary, or a clear signed-out/error state.
- Quota rows for `5h` and `1w` when available.
- Last refresh timestamp or stale/error indicator.
- `Refresh Quota`.
- `Open Session Manager`.
- `Open Codex Folder`.
- `Quit`.

The app starts into tray mode and does not show a primary window by default. A
minimal hidden or diagnostic Tauri window is acceptable if required by Tauri,
but it is not part of the user-facing MVP.

## Startup Flow

On launch:

1. Create the tray icon and initialize the menu with a loading state.
2. Resolve the Codex home directory:
   - Prefer an explicit supported environment/config override if one exists in
     the final implementation.
   - Otherwise use `%USERPROFILE%\.codex`.
3. Read the current local runtime material needed for quota refresh.
4. Start an initial quota refresh asynchronously.
5. Update the tray menu with quota data or a user-facing error.

The UI must not block while quota refresh or Session Manager startup is running.

## Quota Refresh

The MVP only refreshes the currently active Codex identity. It does not manage
or refresh saved accounts.

Refresh behavior:

1. Mark the tray state as refreshing.
2. Use the local Codex runtime or command path to obtain the current account
   snapshot and quota.
3. Parse standard `5h` and `1w` quota windows when present.
4. Support weekly-only quota display when no `5h` window exists.
5. Store the last successful result in memory.
6. On failure, keep the previous successful result when present and add the
   latest error state to the tray menu.

Timeouts must be explicit so a broken Codex runtime cannot hang the tray app.

## Session Manager Flow

`Open Session Manager` uses the bundled web app on `127.0.0.1:4318`.

Flow:

1. Check `http://127.0.0.1:4318/api/health`.
2. If healthy, reuse the existing service and open the default browser.
3. If unhealthy, start the bundled Windows Node sidecar with the built
   `Vendor/CodexMM` server entry.
4. Poll health until ready or until startup timeout.
5. Open `http://127.0.0.1:4318` in the default browser.
6. Track whether this app started the sidecar.
7. On tray app quit, stop only the sidecar process started by this app.

If port `4318` is occupied by an unrelated process, the app reports a port
conflict and does not kill anything.

## Error Handling

Errors should be classified into stable user-facing categories:

- `Codex folder not found`
- `Sign in required`
- `Timed out while reading quota`
- `Quota refresh failed`
- `Session Manager port 4318 is already in use`
- `Bundled Session Manager files are incomplete`
- `Bundled Node runtime is missing`
- `Session Manager could not start`

Session Manager startup failures should preserve a short diagnostics tail from
stdout/stderr for troubleshooting.

## Explicit Non-Goals For MVP

The first Windows version does not include:

- Multiple-account vault management.
- Safe account switching.
- Restore points or rollback.
- Full settings window.
- Launch-at-login support.
- Migration or deletion of the macOS Swift app.
- Major Session Manager UI changes.

These are intentionally deferred so the first Windows version can validate the
tray, quota, and bundled Session Manager path.

## Build And Packaging

Add Windows-focused scripts:

```text
scripts/build-session-manager-windows.ps1
scripts/build-windows-tray.ps1
```

`build-session-manager-windows.ps1` should:

1. Install or verify `Vendor/CodexMM` dependencies.
2. Build the Session Manager client/server.
3. Place built assets in the Windows app bundle staging area.

`build-windows-tray.ps1` should:

1. Prepare or verify the bundled Windows Node runtime.
2. Copy the Session Manager build output into Tauri resources.
3. Run the Tauri Windows build.
4. Produce an installer or executable according to `tauri.conf.json`.

Generated bundle resources and downloaded runtimes should be ignored by git.

## Tests

Rust unit tests should cover:

- Codex home path resolution.
- Missing Codex home and missing auth handling.
- Quota output parsing.
- Quota timeout/error classification.
- Session Manager health checks.
- Session Manager launcher state:
  - reuse existing healthy service
  - start bundled sidecar
  - detect port conflict
  - stop only the owned sidecar

Manual Windows verification should cover:

- App starts with only a tray icon.
- Tray menu updates after quota refresh.
- Refresh does not freeze the tray menu.
- Session Manager starts from bundled sidecar and opens in the browser.
- Quitting stops the owned sidecar.
- Existing healthy Session Manager service is reused and not stopped on quit.

## Documentation

Add Windows MVP documentation to the README or a dedicated Windows document:

- Current MVP feature scope.
- Requirement for a working local Codex installation.
- Use of `%USERPROFILE%\.codex`.
- Session Manager binding to `127.0.0.1:4318`.
- Bundled Node runtime behavior.
- Features deferred from the MVP.

## Open Implementation Notes

The exact quota retrieval mechanism should be selected during implementation
after inspecting the current Swift `CodexRPCClient` behavior and the available
Windows Codex runtime interface. The MVP contract is the tray behavior and
error handling above; the implementation should prefer the least invasive path
that works with a normal Windows Codex installation.
