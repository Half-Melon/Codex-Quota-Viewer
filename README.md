English | [中文](README.zh-CN.md)

# Codex Quota Viewer

A native macOS menu bar app for monitoring local Codex account status and quota
usage.

Codex Quota Viewer gives you a fast, desktop-native way to check the account
currently used by Codex, inspect short-window and weekly quota usage, and see
additional Codex profiles stored by CC Switch. It is designed for people who
want quota visibility without opening terminals, parsing JSON, or switching
between multiple local profile stores.

![Codex Quota Viewer screenshot](docs/images/menu-screenshot.png)

## Highlights

- **Menu bar first**: runs as a lightweight menu bar utility with no main
  window and no Dock presence
- **Current account awareness**: reads the active local Codex profile and shows
  its status immediately
- **Quota visibility**: displays short-window and weekly usage for standard
  Codex logins
- **API key aware**: detects API key profiles and shows provider details when
  official Codex quota data is unavailable
- **CC Switch integration**: discovers additional local Codex profiles from
  CC Switch
- **Bundled session manager**: opens the CodexMM web console from the menu
  bar and starts it automatically when needed
- **Practical controls**: supports manual refresh, scheduled refresh, text or
  meter display, and launch at login

## Version 0.2.1

This release fixes the session manager sidebar so the left project directory
list scrolls independently from the right detail pane.

- fixes the bug where the left project directory list could stop scrolling
- preserves independent scrolling for both the left project list and the right
  session detail pane

## Version 0.2.0

This release turns Codex Quota Viewer into a single-download desktop package
for both quota viewing and session management.

- adds a new **Manage Sessions** menu action
- bundles CodexMM inside `CodexQuotaViewer.app`
- starts the local session manager automatically on demand and opens the web UI
- packages a private Node runtime so end users do not need to install CodexMM
  or Node separately

## Requirements

- macOS 13 or later
- A working local Codex installation:
  - `Codex.app` in `/Applications`, or
  - the `codex` CLI available in your shell `PATH`
- A signed-in Codex profile in `~/.codex/auth.json`

Optional:

- CC Switch with a local database at `~/.cc-switch/cc-switch.db`

## Quick start

### Build the app bundle

Run:

```bash
./scripts/build-app.sh
```

`build-app.sh` builds the native Swift app and the bundled session manager in
one pass. To package the full `.app` from source, the build machine needs:

- Swift
- `node`
- `npm`

This creates:

```text
dist/CodexQuotaViewer.app
```

### Launch the app

Open `dist/CodexQuotaViewer.app`.

Codex Quota Viewer runs as a menu bar app. After launch, it places a status
item in the macOS menu bar instead of opening a standard window.

### Check your account

Open the menu bar item to view:

- **Current Account**
- **CC Switch Accounts**, when available
- **Refresh All**
- **Manage Sessions**
- **Settings**

## Session Manager

Codex Quota Viewer now bundles the CodexMM session manager inside the packaged
app. End users do not need a separate CodexMM checkout, a standalone server
launch, or a system-wide Node installation.

When you click **Manage Sessions** in the menu bar:

- if `http://127.0.0.1:4318/api/health` is already healthy, the app opens
  `http://127.0.0.1:4318` in the default browser
- if the service is not running, the app starts the bundled session manager,
  waits for health to succeed, and then opens the browser

The packaged app stores the bundled runtime here:

```text
CodexQuotaViewer.app/Contents/Resources/SessionManager/
```

That resource directory includes:

- the vendored CodexMM production build (`dist/server` and `dist/client`)
- production `node_modules`, including `better-sqlite3`
- a private Node runtime copied into the app during packaging

Runtime notes:

- the session manager still manages local `~/.codex` session files
- its local index, snapshots, and audit data are still stored in
  `~/.codex-session-manager`
- the standalone executable from `swift build` does not include these bundled
  resources, so **Manage Sessions** is intended for the packaged `.app`

## What the app shows

### Current Account

This section reflects the Codex profile currently represented by:

```text
~/.codex/auth.json
```

For standard Codex logins, the app shows two usage windows:

- `5h`: the short-window quota summary
- `1w`: the weekly quota summary

For API key profiles, Codex Quota Viewer does not invent quota data. Instead,
it shows the best local metadata it can infer, such as:

- provider name
- model
- provider host
- masked key suffix

### CC Switch Accounts

If CC Switch is installed and has stored Codex profiles locally, the app lists
those accounts in the same menu for quick comparison.

CC Switch entries are intentionally limited to ordinary Codex logins. API
key-only CC Switch profiles are excluded from the additional account list.

### Menu bar display

You can choose between two display styles:

- **Meter**: a compact visual indicator for remaining quota
- **Text**: a textual summary such as `5h82% 1w64%`

## Settings

Codex Quota Viewer includes three user-facing settings:

- **Refresh interval**: Manual, 1 minute, 5 minutes, or 15 minutes
- **Menu bar style**: Meter or Text
- **Launch at login**: available when the app is launched from the packaged
  `.app`

Settings are stored locally at:

```text
~/Library/Application Support/CodexQuotaViewer/settings.json
```

## Privacy and local data

Codex Quota Viewer is designed for local desktop use. It reads data already
present on your machine and does not ask you to paste credentials into the UI.

The app reads from these local sources when available:

- `~/.codex/auth.json`
- `~/.codex/config.toml`
- `~/.cc-switch/cc-switch.db`
- `~/.codex/sessions/**/*.jsonl`
- `~/.codex/archived_sessions/**/*.jsonl`

To fetch account state, the app starts your local Codex installation in
`app-server` mode. It does not rely on a separate hosted backend operated by
this project.

For session management, the bundled CodexMM service reads local session files
and serves its web UI only on `127.0.0.1`.

## Troubleshooting

### “Could not find the codex executable.”

Make sure that:

- `Codex.app` is installed in `/Applications`, or
- `codex` is installed and available in your shell `PATH`

### “Sign in required.”

Your current Codex session is missing, invalid, or expired. Sign in again with
Codex and confirm that `~/.codex/auth.json` exists and is current.

### “Timed out while reading quota.”

The local Codex process did not return account data in time. Try **Refresh
All** again. If the problem continues, verify that Codex itself can run
normally on the machine.

### “Launch at login can only be configured when running from the app bundle.”

Launch at login only works when the app is started from the packaged `.app`.
It does not work when running the executable directly from a Swift build output.

### “Bundled session manager is missing. Rebuild CodexQuotaViewer.app.”

This means the app was launched without the packaged `SessionManager`
resources, or the bundle contents are incomplete. Rebuild the app with:

```bash
./scripts/build-app.sh
```

Then launch `dist/CodexQuotaViewer.app`, not just the bare executable.

### “Session manager could not start because port 4318 is already in use.”

Another local process is already listening on port `4318`. If it is an
existing session manager instance, you can use that running service directly.
If it is unrelated, stop it before using **Manage Sessions** from the app.

### “Failed to read CC Switch data.”

Check that:

- CC Switch is installed
- `~/.cc-switch/cc-switch.db` exists
- `/usr/bin/sqlite3` is available on your system

If any of those are missing, Codex Quota Viewer still works for the current
Codex account, but CC Switch accounts will not appear.

## Build from source

If you want to build the executable without packaging the app bundle, run:

```bash
swift build -c release --product CodexQuotaViewer
```

This is useful for native app development, but it does **not** include the
bundled session manager resources. Use `./scripts/build-app.sh` for the
distributable app bundle.

## Updating Vendored CodexMM

The bundled session manager source lives in:

```text
Vendor/CodexMM
```

For the current snapshot metadata and the recommended sync workflow, see:

```text
Vendor/CodexMM/VENDORED.md
```

The intended update path is an in-place overwrite of the vendored directory
while preserving the upstream repository layout:

```bash
rsync -a --delete \
  --exclude '.git' \
  --exclude 'node_modules' \
  --exclude 'dist' \
  --exclude '.DS_Store' \
  /path/to/CodexMM/ Vendor/CodexMM/
```

After syncing, rebuild the packaged app and rerun the relevant checks before
shipping.

## Distribution note

The current DMG is a preview build for testing. It is not notarized for broad
consumer distribution, and macOS may require manual approval on first launch.

The bundled private Node runtime is copied from the build machine's local Node
installation. Its CPU architecture therefore follows the build machine, and
this project still needs proper release engineering before broad distribution.

## Acknowledgements

This project integrates with local profile data managed by
[CC Switch](https://github.com/farion1231/cc-switch) to make multi-account
Codex usage more practical.

Special thanks to the CC Switch project for reducing the friction of local
account switching and profile management. Codex Quota Viewer benefits directly
from that workflow and ecosystem.

## Community Thanks

Thank you to the [LinuxDo](https://linux.do) community for your support.

LinuxDo is a welcoming place for tech discussions, AI frontiers, and practical
AI experience sharing. Communities like it help tools such as Codex Quota
Viewer become more useful, more understandable, and easier to improve.
