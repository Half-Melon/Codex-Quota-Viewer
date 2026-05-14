# Windows Account Management Design

## Goal

Bring the Windows tray app's account management closer to the macOS app by
adding a local account vault, an Accounts settings page, API account creation,
current ChatGPT account import, account activation, rename, forget, and an
`All Accounts` tray submenu.

This phase builds the account foundation for later Safe Switch and Rollback
work. It intentionally implements direct activation only. Restore points,
automatic rollback, Codex relaunch orchestration, and thread/provider repair
remain a separate follow-up.

## Scope

This phase includes:

- A Windows account vault stored under the Tauri app data directory.
- Account models aligned with the macOS concepts where practical.
- Importing the current local ChatGPT Codex login as a saved account.
- Adding OpenAI-compatible API accounts with API key, base URL, and optional
  model/provider fields.
- Activating saved accounts into the resolved `CODEX_HOME` or
  `%USERPROFILE%\.codex`.
- Renaming and forgetting saved accounts.
- Opening the Windows account vault folder.
- A two-tab settings window: `General` and `Accounts`.
- An `All Accounts` tray submenu with current-account state and grouped rows.
- Documentation updates for Windows account management behavior.

This phase does not include:

- Browser-based ChatGPT OAuth inside the Windows app.
- Full Safe Switch orchestration.
- Restore points or rollback.
- Repairing official local thread/provider metadata after activation.
- Quota refresh for every saved account before opening the tray menu.
- Encryption beyond the same local-file trust model already used by the app.

## Current Context

The Windows tray app currently supports:

- Current active Codex account quota display.
- Manual and scheduled quota refresh.
- A General settings page.
- Language, tray style, refresh interval, and launch-at-login settings.
- Opening the bundled Session Manager.
- Opening the local Codex folder.

The Windows MVP documentation explicitly excludes multiple saved accounts,
safe account switching, rollback restore points, and account settings beyond
General settings. This phase removes the first of those exclusions and prepares
the shape needed for later switching work.

The macOS app already has mature account concepts:

- Local account vault.
- ChatGPT and API account records.
- Settings `Accounts` tab.
- Account activation, rename, forget, and vault folder actions.
- Menu-level account overview and `All Accounts`.

The Windows implementation should match those user-facing concepts without
copying AppKit-specific UI structure.

## Confirmed Approach

Use a Windows-native Rust/Tauri implementation of the macOS account concepts.

Rust owns account storage, validation, activation, and error mapping. The
TypeScript frontend owns only presentation, form state, and command calls.

This approach keeps the Windows app aligned with macOS semantics while allowing
platform-specific details:

- Windows paths use Tauri app data and resolved Codex home.
- Windows activation updates files directly in Codex home for this phase.
- ChatGPT account creation imports the current local Codex login instead of
  embedding a browser OAuth flow.
- API account creation uses a local form.

## User Experience

The settings window becomes a compact two-tab tool:

- `General`: the existing settings controls remain unchanged.
- `Accounts`: the new account management surface.

The Accounts tab contains:

- `Sign in with ChatGPT`
- `Add API Account`
- `Open Vault Folder`
- Account list

`Sign in with ChatGPT` means "save the currently signed-in Codex ChatGPT
profile." If the current Codex home has no usable `auth.json`, the app shows a
short message asking the user to sign in with Codex first.

`Add API Account` opens an inline form or small modal with:

- Display name
- API key
- Base URL
- Optional model
- Optional provider name

Each account row shows:

- Display name
- Account type: ChatGPT or API
- Active/current marker when applicable
- Short status text
- Actions: `Activate`, `Rename`, `Forget`

Activation asks for confirmation because this phase directly updates local
Codex configuration without a restore point. The confirmation text should make
that explicit:

```text
Activate this account for local Codex? This updates files in your Codex home.
```

Forgetting an account asks for confirmation. Forgetting the currently active
saved account removes it from the app vault but does not automatically sign out
Codex.

## Tray Menu

The Windows tray menu gains account awareness while staying tray-first:

```text
Current account
Quota
---
All Accounts >
Refresh Quota
Settings...
Open Session Manager
Open Codex Folder
Quit
```

`All Accounts` shows saved accounts grouped with a lightweight version of the
macOS grouping:

- Current Account
- ChatGPT Accounts
- API Accounts
- Needs Attention

Rows should show a checkmark or disabled current marker for the active account.
Clicking a non-current account triggers activation confirmation.

If there are no saved accounts, `All Accounts` contains a disabled
`No saved accounts` row.

## Account Storage

Store account records under Tauri app data:

```text
%APPDATA%\Codex Quota Viewer\Accounts\
```

Suggested layout:

```text
Accounts\
  index.json
  records\
    <account-id>.json
```

`index.json` stores ordering and the preferred account id:

```json
{
  "version": 1,
  "preferredAccountId": "account-id",
  "accountIds": ["account-id"]
}
```

Each account record stores metadata and account-specific payload:

```json
{
  "version": 1,
  "id": "account-id",
  "metadata": {
    "displayName": "Work",
    "kind": "chatgpt",
    "createdAt": "2026-05-14T00:00:00Z",
    "updatedAt": "2026-05-14T00:00:00Z"
  },
  "payload": {
    "type": "chatgpt",
    "authJson": {}
  }
}
```

API account payload:

```json
{
  "type": "api",
  "apiKey": "sk-...",
  "baseUrl": "https://api.openai.com/v1",
  "model": "gpt-5.4",
  "providerName": "OpenAI"
}
```

This design keeps the storage simple and explicit. If encryption is needed
later, it can be added behind the vault module without changing the command
surface.

## Rust Module Shape

Add focused modules under `WindowsTray/src-tauri/src/`:

```text
account_models.rs
account_vault.rs
account_activation.rs
account_commands.rs
```

Responsibilities:

- `account_models.rs`: serializable data types and validation helpers.
- `account_vault.rs`: load, save, list, rename, forget, and folder path logic.
- `account_activation.rs`: write selected account material into Codex home.
- `account_commands.rs`: Tauri command handlers and presentation mapping.

The existing app state should gain:

- `account_vault_path`
- account vault service or path-backed helper
- current account presentation cache, if needed for tray rebuilding

Avoid putting account storage logic directly in `main.rs`; it should stay in
small testable modules.

## Activation Behavior

ChatGPT activation:

1. Read the saved account payload.
2. Validate the payload contains a usable `authJson` object.
3. Write `auth.json` into the resolved Codex home.
4. Update `preferredAccountId` in the account index.
5. Trigger current quota refresh.
6. Rebuild the tray menu.

API activation:

1. Read the saved API payload.
2. Validate API key and base URL.
3. Write local Codex auth/config material needed for an API account.
4. Update `preferredAccountId`.
5. Trigger current quota refresh.
6. Rebuild the tray menu.

The exact API account file shape should follow the existing macOS profile
runtime support as closely as the Windows Codex runtime allows. If the current
Codex runtime requires separate `auth.json` and `config.toml` changes, those
writes belong in `account_activation.rs`.

Activation should be atomic at the file level where practical:

- Write replacement files through temp files and rename.
- Create the Codex home directory if it does not exist.
- Do not mutate the vault record until activation validation passes.

This phase does not create restore points. The confirmation copy and
documentation must be explicit about that limitation.

## Tauri API Surface

Expose commands:

- `get_accounts() -> AccountsPresentation`
- `import_current_chatgpt_account(display_name: Option<String>) -> AccountsPresentation`
- `add_api_account(input: AddApiAccountInput) -> AccountsPresentation`
- `activate_account(account_id: String) -> AccountsPresentation`
- `rename_account(account_id: String, display_name: String) -> AccountsPresentation`
- `forget_account(account_id: String) -> AccountsPresentation`
- `open_vault_folder() -> ()`

`AccountsPresentation` should include:

- localized labels
- account rows
- current/preferred account id
- optional warning message
- optional last action message

The frontend should not infer account validity from raw files. Rust should
return clear row states, such as:

- `active`
- `available`
- `needsAttention`

## Frontend Shape

Keep the current no-framework TypeScript approach, but split responsibilities
enough to prevent `main.ts` from becoming unmanageable.

Suggested files:

```text
WindowsTray/src/main.ts
WindowsTray/src/settings-view.ts
WindowsTray/src/accounts-view.ts
WindowsTray/src/dom.ts
WindowsTray/src/types.ts
WindowsTray/src/styles.css
```

The UI should remain compact and desktop-native:

- Standard tabs.
- Standard selects, checkboxes, inputs, and buttons.
- Dense account list.
- Confirmation dialogs for activation and forget.
- Inline form validation for API account creation.

No landing page, hero section, or explanatory marketing content should be
introduced.

## Localization

Account labels, button text, validation errors, and tray menu account labels
should use the existing Windows localization layer.

Minimum English/Chinese labels:

- Accounts
- Sign in with ChatGPT
- Add API Account
- Open Vault Folder
- Activate
- Rename
- Forget
- Current
- ChatGPT Accounts
- API Accounts
- Needs Attention
- No saved accounts
- Sign in with Codex first
- Activation failed
- Account saved

Session Manager language bridging remains separate from this account-management
phase.

## Error Handling

User-facing errors should be short. Detailed diagnostics can stay in internal
strings.

Required cases:

- Current Codex `auth.json` is missing or invalid when importing ChatGPT.
- Account vault index is missing: create defaults.
- Account vault index is corrupted: load valid records where possible and show
  a warning.
- Individual account record is corrupted: skip that row and show a warning.
- API key missing.
- Base URL missing or not URL-shaped.
- Activation write failed.
- Rename display name is empty.
- Forget account failed.
- Opening vault folder failed.

Failed activation must not mark the account as active/preferred. Failed
rename/forget must leave the previous record intact.

## Testing

Rust unit tests should cover:

- Account model serialization and deserialization.
- Vault creation when files are missing.
- Save/list/load round trip.
- Rename updates metadata and preserves payload.
- Forget removes record and updates index.
- Corrupted index recovery.
- Corrupted record skip behavior.
- Import current ChatGPT account from a temporary Codex home.
- API input validation.
- ChatGPT activation writes `auth.json`.
- API activation writes expected Codex files.
- Preferred account id updates only after successful activation.

Frontend checks should cover:

- TypeScript typecheck.
- General tab still renders existing settings.
- Accounts tab renders rows from presentation data.
- API account form validates required fields.
- Account action buttons call the expected Tauri commands.

Manual Windows verification should cover:

- App starts hidden in tray.
- `Settings...` opens General and Accounts tabs.
- Current Codex ChatGPT login can be imported.
- API account can be added.
- Accounts can be renamed and forgotten.
- Activating an account updates local Codex state.
- Tray `All Accounts` reflects saved accounts and current state.
- Manual quota refresh works after activation.
- Existing Session Manager and General settings behavior still works.

## Documentation

Update Windows documentation and README release/build notes to explain:

- Windows now supports saved accounts.
- ChatGPT account creation imports the current local Codex login.
- API accounts can be added from the Windows settings window.
- Activation in this phase directly updates Codex home and does not yet create
  restore points.
- Safe Switch and Rollback remain planned follow-ups.

## Rollout Order

1. Add account models and vault persistence tests.
2. Add account activation helpers and tests.
3. Add Tauri account commands and presentation mapping.
4. Extend app state and tray menu with `All Accounts`.
5. Split the settings frontend into General and Accounts tabs.
6. Add API account form and current ChatGPT import flow.
7. Add rename, forget, activate, and open vault folder UI actions.
8. Update documentation.
9. Run Rust tests, TypeScript typecheck, and manual Windows verification.

This order keeps storage and activation behavior testable before adding the UI
that depends on it.
