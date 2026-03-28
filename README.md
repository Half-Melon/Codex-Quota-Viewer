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
- **Practical controls**: supports manual refresh, scheduled refresh, text or
  meter display, and launch at login

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
- **Settings**

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

To fetch account state, the app starts your local Codex installation in
`app-server` mode. It does not rely on a separate hosted backend operated by
this project.

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

## Distribution note

The current DMG is a preview build for testing. It is not notarized for broad
consumer distribution, and macOS may require manual approval on first launch.
