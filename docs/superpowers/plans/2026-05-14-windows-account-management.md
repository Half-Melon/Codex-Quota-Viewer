# Windows Account Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Windows saved-account management with a local vault, Accounts settings tab, current ChatGPT import, API account creation, activation, rename, forget, and an `All Accounts` tray submenu.

**Architecture:** Rust owns account models, vault persistence, activation, validation, localization, and Tauri command results. TypeScript renders a compact two-tab settings UI and calls Rust commands without duplicating business rules. The tray reads account presentation from shared app state and rebuilds the menu after account or quota changes.

**Tech Stack:** Rust, Tauri 2, serde/serde_json, tempfile tests, TypeScript, Vite, native Windows filesystem integration through Rust and the existing `open` crate.

---

## Scope Check

The approved design covers one subsystem: Windows account management. Safe Switch,
restore points, rollback, and thread/provider repair are deliberately outside
this plan. This plan still prepares activation boundaries so those features can
attach to `account_activation.rs` in a later design.

## File Structure

Create focused Rust modules:

- `WindowsTray/src-tauri/src/account_models.rs`
  - Serializable account ids, metadata, payloads, API input validation, and row state types.
- `WindowsTray/src-tauri/src/account_vault.rs`
  - Path-backed account vault CRUD: load, list, save, rename, forget, import current ChatGPT record.
- `WindowsTray/src-tauri/src/account_activation.rs`
  - File writes into resolved Codex home for ChatGPT and API accounts.
- `WindowsTray/src-tauri/src/account_commands.rs`
  - Tauri command handlers and localized `AccountsPresentation` mapping.

Modify existing Rust files:

- `WindowsTray/src-tauri/src/main.rs`
  - Register modules and Tauri commands, initialize account vault paths, update app state, handle account menu ids.
- `WindowsTray/src-tauri/src/app_state.rs`
  - Store `accounts_dir` and an in-memory accounts presentation cache if needed.
- `WindowsTray/src-tauri/src/tray.rs`
  - Add `All Accounts` submenu and dynamic account menu ids.
- `WindowsTray/src-tauri/src/errors.rs`
  - Add account-specific error variants.
- `WindowsTray/src-tauri/src/localization.rs`
  - Add account-management labels and account error messages.

Modify frontend files:

- `WindowsTray/src/main.ts`
  - Convert settings UI to a small tab shell and delegate rendering.
- `WindowsTray/src/types.ts`
  - Shared frontend command result types.
- `WindowsTray/src/settings-view.ts`
  - Existing General settings rendering and control binding.
- `WindowsTray/src/accounts-view.ts`
  - Account list, API form, import, activate, rename, forget, open vault actions.
- `WindowsTray/src/dom.ts`
  - Shared HTML escaping, option markup, and element helpers.
- `WindowsTray/src/styles.css`
  - Compact tab and account-list styles.
- `WindowsTray/package.json`
  - Update `typecheck` so TypeScript checks all new source files.

Modify docs:

- `docs/windows-mvp.md`
- `README.md`
- `README.zh-CN.md`

---

### Task 1: Account Models And Validation

**Files:**
- Create: `WindowsTray/src-tauri/src/account_models.rs`
- Modify: `WindowsTray/src-tauri/src/main.rs`
- Test: `WindowsTray/src-tauri/src/account_models.rs`

- [ ] **Step 1: Add the module declaration**

Modify `WindowsTray/src-tauri/src/main.rs` near the existing module list:

```rust
mod account_models;
mod app_state;
mod codex_home;
mod errors;
mod launch_at_login;
mod localization;
mod quota;
mod scheduler;
mod session_manager;
mod settings;
mod tray;
```

- [ ] **Step 2: Create failing model tests**

Create `WindowsTray/src-tauri/src/account_models.rs` with the tests first:

```rust
use serde::{Deserialize, Serialize};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serializes_chatgpt_record_with_camel_case_fields() {
        let record = VaultAccountRecord::new_chatgpt(
            AccountId::new("acct-chatgpt"),
            "Personal".to_string(),
            serde_json::json!({"tokens": {"id_token": "abc"}}),
        );

        let text = serde_json::to_string(&record).unwrap();

        assert!(text.contains("\"displayName\":\"Personal\""));
        assert!(text.contains("\"type\":\"chatgpt\""));
        assert!(text.contains("\"authJson\""));
    }

    #[test]
    fn validates_api_account_input() {
        let input = AddApiAccountInput {
            display_name: "Work API".to_string(),
            api_key: "sk-test".to_string(),
            base_url: "https://api.openai.com/v1".to_string(),
            model: Some("gpt-5.4".to_string()),
            provider_name: Some("OpenAI".to_string()),
        };

        let payload = input.validate().unwrap();

        assert_eq!(payload.api_key, "sk-test");
        assert_eq!(payload.base_url, "https://api.openai.com/v1");
        assert_eq!(payload.model.as_deref(), Some("gpt-5.4"));
        assert_eq!(payload.provider_name.as_deref(), Some("OpenAI"));
    }

    #[test]
    fn rejects_blank_api_key() {
        let input = AddApiAccountInput {
            display_name: "Work API".to_string(),
            api_key: " ".to_string(),
            base_url: "https://api.openai.com/v1".to_string(),
            model: None,
            provider_name: None,
        };

        assert_eq!(input.validate(), Err(AccountValidationError::MissingApiKey));
    }

    #[test]
    fn rejects_non_url_base_url() {
        let input = AddApiAccountInput {
            display_name: "Work API".to_string(),
            api_key: "sk-test".to_string(),
            base_url: "not-a-url".to_string(),
            model: None,
            provider_name: None,
        };

        assert_eq!(input.validate(), Err(AccountValidationError::InvalidBaseUrl));
    }
}
```

- [ ] **Step 3: Run the model tests and verify they fail**

Run:

```powershell
cargo test account_models --lib
```

Expected: compile fails because `VaultAccountRecord`, `AccountId`,
`AddApiAccountInput`, and `AccountValidationError` are not defined.

- [ ] **Step 4: Add the model implementation**

Replace `WindowsTray/src-tauri/src/account_models.rs` with:

```rust
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct AccountId(String);

impl AccountId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AccountKind {
    ChatGpt,
    Api,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountMetadata {
    pub display_name: String,
    pub kind: AccountKind,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum AccountPayload {
    ChatGpt { auth_json: serde_json::Value },
    Api(ApiAccountPayload),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApiAccountPayload {
    pub api_key: String,
    pub base_url: String,
    pub model: Option<String>,
    pub provider_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VaultAccountRecord {
    pub version: u32,
    pub id: AccountId,
    pub metadata: AccountMetadata,
    pub payload: AccountPayload,
}

impl VaultAccountRecord {
    pub fn new_chatgpt(id: AccountId, display_name: String, auth_json: serde_json::Value) -> Self {
        let now = Utc::now();
        Self {
            version: 1,
            id,
            metadata: AccountMetadata {
                display_name,
                kind: AccountKind::ChatGpt,
                created_at: now,
                updated_at: now,
            },
            payload: AccountPayload::ChatGpt { auth_json },
        }
    }

    pub fn new_api(id: AccountId, display_name: String, payload: ApiAccountPayload) -> Self {
        let now = Utc::now();
        Self {
            version: 1,
            id,
            metadata: AccountMetadata {
                display_name,
                kind: AccountKind::Api,
                created_at: now,
                updated_at: now,
            },
            payload: AccountPayload::Api(payload),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AddApiAccountInput {
    pub display_name: String,
    pub api_key: String,
    pub base_url: String,
    pub model: Option<String>,
    pub provider_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AccountValidationError {
    MissingDisplayName,
    MissingApiKey,
    MissingBaseUrl,
    InvalidBaseUrl,
}

impl AddApiAccountInput {
    pub fn validate(self) -> Result<ApiAccountPayload, AccountValidationError> {
        let display_name = self.display_name.trim();
        if display_name.is_empty() {
            return Err(AccountValidationError::MissingDisplayName);
        }

        let api_key = self.api_key.trim();
        if api_key.is_empty() {
            return Err(AccountValidationError::MissingApiKey);
        }

        let base_url = self.base_url.trim().trim_end_matches('/').to_string();
        if base_url.is_empty() {
            return Err(AccountValidationError::MissingBaseUrl);
        }
        if !(base_url.starts_with("https://") || base_url.starts_with("http://")) {
            return Err(AccountValidationError::InvalidBaseUrl);
        }

        Ok(ApiAccountPayload {
            api_key: api_key.to_string(),
            base_url,
            model: self.model.and_then(non_empty_trimmed),
            provider_name: self.provider_name.and_then(non_empty_trimmed),
        })
    }
}

fn non_empty_trimmed(value: String) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum AccountRowState {
    Active,
    Available,
    NeedsAttention,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serializes_chatgpt_record_with_camel_case_fields() {
        let record = VaultAccountRecord::new_chatgpt(
            AccountId::new("acct-chatgpt"),
            "Personal".to_string(),
            serde_json::json!({"tokens": {"id_token": "abc"}}),
        );

        let text = serde_json::to_string(&record).unwrap();

        assert!(text.contains("\"displayName\":\"Personal\""));
        assert!(text.contains("\"type\":\"chatGpt\""));
        assert!(text.contains("\"authJson\""));
    }

    #[test]
    fn validates_api_account_input() {
        let input = AddApiAccountInput {
            display_name: "Work API".to_string(),
            api_key: "sk-test".to_string(),
            base_url: "https://api.openai.com/v1/".to_string(),
            model: Some("gpt-5.4".to_string()),
            provider_name: Some("OpenAI".to_string()),
        };

        let payload = input.validate().unwrap();

        assert_eq!(payload.api_key, "sk-test");
        assert_eq!(payload.base_url, "https://api.openai.com/v1");
        assert_eq!(payload.model.as_deref(), Some("gpt-5.4"));
        assert_eq!(payload.provider_name.as_deref(), Some("OpenAI"));
    }

    #[test]
    fn rejects_blank_api_key() {
        let input = AddApiAccountInput {
            display_name: "Work API".to_string(),
            api_key: " ".to_string(),
            base_url: "https://api.openai.com/v1".to_string(),
            model: None,
            provider_name: None,
        };

        assert_eq!(input.validate(), Err(AccountValidationError::MissingApiKey));
    }

    #[test]
    fn rejects_non_url_base_url() {
        let input = AddApiAccountInput {
            display_name: "Work API".to_string(),
            api_key: "sk-test".to_string(),
            base_url: "not-a-url".to_string(),
            model: None,
            provider_name: None,
        };

        assert_eq!(input.validate(), Err(AccountValidationError::InvalidBaseUrl));
    }
}
```

- [ ] **Step 5: Run model tests**

Run:

```powershell
cargo test account_models --lib
```

Expected: PASS.

- [ ] **Step 6: Commit**

```powershell
git add WindowsTray/src-tauri/src/main.rs WindowsTray/src-tauri/src/account_models.rs
git commit -m "feat: add windows account models"
```

---

### Task 2: Account Vault Persistence

**Files:**
- Create: `WindowsTray/src-tauri/src/account_vault.rs`
- Modify: `WindowsTray/src-tauri/src/main.rs`
- Test: `WindowsTray/src-tauri/src/account_vault.rs`

- [ ] **Step 1: Add the module declaration**

Modify `WindowsTray/src-tauri/src/main.rs`:

```rust
mod account_models;
mod account_vault;
mod app_state;
```

- [ ] **Step 2: Write failing vault tests**

Create `WindowsTray/src-tauri/src/account_vault.rs` with tests:

```rust
use std::fs;
use std::path::{Path, PathBuf};

use chrono::Utc;
use serde::{Deserialize, Serialize};

use crate::account_models::{AccountId, AccountPayload, AddApiAccountInput, VaultAccountRecord};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_vault_lists_no_accounts() {
        let temp = tempfile::tempdir().unwrap();
        let vault = AccountVault::new(temp.path().join("Accounts"));

        let listed = vault.list_accounts().unwrap();

        assert_eq!(listed.records.len(), 0);
        assert_eq!(listed.issue, None);
    }

    #[test]
    fn saves_and_lists_api_account() {
        let temp = tempfile::tempdir().unwrap();
        let vault = AccountVault::new(temp.path().join("Accounts"));
        let input = AddApiAccountInput {
            display_name: "Work API".to_string(),
            api_key: "sk-test".to_string(),
            base_url: "https://api.openai.com/v1".to_string(),
            model: None,
            provider_name: Some("OpenAI".to_string()),
        };

        let record = vault.add_api_account(input).unwrap();
        let listed = vault.list_accounts().unwrap();

        assert_eq!(listed.records.len(), 1);
        assert_eq!(listed.records[0].id, record.id);
        assert_eq!(listed.records[0].metadata.display_name, "Work API");
    }

    #[test]
    fn imports_current_chatgpt_auth_json() {
        let temp = tempfile::tempdir().unwrap();
        let codex_home = temp.path().join(".codex");
        fs::create_dir_all(&codex_home).unwrap();
        fs::write(codex_home.join("auth.json"), r#"{"account":{"email":"ada@example.com"}}"#)
            .unwrap();
        let vault = AccountVault::new(temp.path().join("Accounts"));

        let record = vault
            .import_current_chatgpt_account(&codex_home, Some("Ada".to_string()))
            .unwrap();

        assert_eq!(record.metadata.display_name, "Ada");
        assert!(matches!(record.payload, AccountPayload::ChatGpt { .. }));
    }

    #[test]
    fn rename_updates_display_name() {
        let temp = tempfile::tempdir().unwrap();
        let vault = AccountVault::new(temp.path().join("Accounts"));
        let record = vault
            .add_api_account(AddApiAccountInput {
                display_name: "Old".to_string(),
                api_key: "sk-test".to_string(),
                base_url: "https://api.openai.com/v1".to_string(),
                model: None,
                provider_name: None,
            })
            .unwrap();

        let renamed = vault.rename_account(record.id.as_str(), "New").unwrap();

        assert_eq!(renamed.metadata.display_name, "New");
    }

    #[test]
    fn forget_removes_record_and_index_entry() {
        let temp = tempfile::tempdir().unwrap();
        let vault = AccountVault::new(temp.path().join("Accounts"));
        let record = vault
            .add_api_account(AddApiAccountInput {
                display_name: "Delete Me".to_string(),
                api_key: "sk-test".to_string(),
                base_url: "https://api.openai.com/v1".to_string(),
                model: None,
                provider_name: None,
            })
            .unwrap();

        vault.forget_account(record.id.as_str()).unwrap();
        let listed = vault.list_accounts().unwrap();

        assert_eq!(listed.records.len(), 0);
    }
}
```

- [ ] **Step 3: Run vault tests and verify they fail**

Run:

```powershell
cargo test account_vault --lib
```

Expected: compile fails because `AccountVault` and `VaultListResult` are not
defined.

- [ ] **Step 4: Implement path-backed vault CRUD**

Replace `WindowsTray/src-tauri/src/account_vault.rs` with a full implementation
containing these public APIs:

```rust
pub struct AccountVault {
    root: PathBuf,
}

pub struct VaultListResult {
    pub records: Vec<VaultAccountRecord>,
    pub issue: Option<String>,
}

impl AccountVault {
    pub fn new(root: PathBuf) -> Self;
    pub fn root(&self) -> &Path;
    pub fn list_accounts(&self) -> Result<VaultListResult, AppError>;
    pub fn add_api_account(&self, input: AddApiAccountInput) -> Result<VaultAccountRecord, AppError>;
    pub fn import_current_chatgpt_account(
        &self,
        codex_home: &Path,
        display_name: Option<String>,
    ) -> Result<VaultAccountRecord, AppError>;
    pub fn rename_account(&self, account_id: &str, display_name: &str) -> Result<VaultAccountRecord, AppError>;
    pub fn forget_account(&self, account_id: &str) -> Result<(), AppError>;
    pub fn load_record(&self, account_id: &str) -> Result<VaultAccountRecord, AppError>;
}
```

Implementation requirements:

- Store index at `root/index.json`.
- Store records at `root/records/<id>.json`.
- Generate ids as `acct-<timestamp-millis>` using `Utc::now().timestamp_millis()`.
- Use `serde_json::to_vec_pretty`.
- Create parent directories before writes.
- For missing index, return defaults.
- For corrupted index, list readable record files and return an issue string.
- For corrupted record files, skip the broken file and return an issue string.
- For empty rename display name, return `AppError::AccountValidationFailed("Display name is required".into())`.
- For missing `auth.json`, return `AppError::SignInRequired`.

Add these helper structs inside the file:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct VaultIndex {
    version: u32,
    preferred_account_id: Option<String>,
    account_ids: Vec<String>,
}

impl Default for VaultIndex {
    fn default() -> Self {
        Self {
            version: 1,
            preferred_account_id: None,
            account_ids: Vec::new(),
        }
    }
}
```

- [ ] **Step 5: Add account error variants**

Modify `WindowsTray/src-tauri/src/errors.rs`:

```rust
pub enum AppError {
    CodexFolderNotFound,
    SignInRequired,
    QuotaTimeout,
    QuotaRefreshFailed(String),
    SessionManagerPortInUse,
    SessionManagerFilesIncomplete,
    NodeRuntimeMissing,
    SessionManagerStartFailed(String),
    SettingsLoadFailed(String),
    SettingsSaveFailed(String),
    LaunchAtLoginFailed(String),
    AccountVaultFailed(String),
    AccountValidationFailed(String),
    AccountNotFound(String),
    AccountActivationFailed(String),
}
```

Add user messages:

```rust
Self::AccountVaultFailed(_) => "Account vault operation failed",
Self::AccountValidationFailed(_) => "Account information is invalid",
Self::AccountNotFound(_) => "Account not found",
Self::AccountActivationFailed(_) => "Account activation failed",
```

Add diagnostics arms:

```rust
| Self::AccountVaultFailed(message)
| Self::AccountValidationFailed(message)
| Self::AccountNotFound(message)
| Self::AccountActivationFailed(message) => Some(message),
```

- [ ] **Step 6: Run vault tests**

Run:

```powershell
cargo test account_vault --lib
```

Expected: PASS.

- [ ] **Step 7: Commit**

```powershell
git add WindowsTray/src-tauri/src/main.rs WindowsTray/src-tauri/src/account_vault.rs WindowsTray/src-tauri/src/errors.rs
git commit -m "feat: add windows account vault"
```

---

### Task 3: Account Activation

**Files:**
- Create: `WindowsTray/src-tauri/src/account_activation.rs`
- Modify: `WindowsTray/src-tauri/src/main.rs`
- Test: `WindowsTray/src-tauri/src/account_activation.rs`

- [ ] **Step 1: Add the module declaration**

Modify `WindowsTray/src-tauri/src/main.rs`:

```rust
mod account_activation;
mod account_models;
mod account_vault;
```

- [ ] **Step 2: Write failing activation tests**

Create `WindowsTray/src-tauri/src/account_activation.rs` with tests:

```rust
use std::fs;
use std::path::Path;

use crate::account_models::{
    AccountId, AddApiAccountInput, VaultAccountRecord,
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn activates_chatgpt_by_writing_auth_json() {
        let temp = tempfile::tempdir().unwrap();
        let codex_home = temp.path().join(".codex");
        let record = VaultAccountRecord::new_chatgpt(
            AccountId::new("acct-chat"),
            "Chat".to_string(),
            serde_json::json!({"account":{"email":"ada@example.com"}}),
        );

        activate_account_record(&record, &codex_home).unwrap();

        let text = fs::read_to_string(codex_home.join("auth.json")).unwrap();
        assert!(text.contains("ada@example.com"));
    }

    #[test]
    fn activates_api_by_writing_auth_and_config() {
        let temp = tempfile::tempdir().unwrap();
        let codex_home = temp.path().join(".codex");
        let payload = AddApiAccountInput {
            display_name: "API".to_string(),
            api_key: "sk-test".to_string(),
            base_url: "https://api.openai.com/v1".to_string(),
            model: Some("gpt-5.4".to_string()),
            provider_name: Some("OpenAI".to_string()),
        }
        .validate()
        .unwrap();
        let record = VaultAccountRecord::new_api(AccountId::new("acct-api"), "API".to_string(), payload);

        activate_account_record(&record, &codex_home).unwrap();

        let auth = fs::read_to_string(codex_home.join("auth.json")).unwrap();
        let config = fs::read_to_string(codex_home.join("config.toml")).unwrap();
        assert!(auth.contains("sk-test"));
        assert!(config.contains("https://api.openai.com/v1"));
        assert!(config.contains("gpt-5.4"));
    }
}
```

- [ ] **Step 3: Run activation tests and verify they fail**

Run:

```powershell
cargo test account_activation --lib
```

Expected: compile fails because `activate_account_record` is not defined.

- [ ] **Step 4: Implement direct activation helpers**

Replace `WindowsTray/src-tauri/src/account_activation.rs` with:

```rust
use std::fs;
use std::path::Path;

use crate::account_models::{AccountPayload, VaultAccountRecord};
use crate::errors::AppError;

pub fn activate_account_record(
    record: &VaultAccountRecord,
    codex_home: &Path,
) -> Result<(), AppError> {
    fs::create_dir_all(codex_home)
        .map_err(|error| AppError::AccountActivationFailed(error.to_string()))?;

    match &record.payload {
        AccountPayload::ChatGpt { auth_json } => write_json_file(&codex_home.join("auth.json"), auth_json),
        AccountPayload::Api(payload) => {
            let auth_json = serde_json::json!({
                "OPENAI_API_KEY": payload.api_key,
                "type": "api"
            });
            write_json_file(&codex_home.join("auth.json"), &auth_json)?;

            let model = payload.model.as_deref().unwrap_or("gpt-5.4");
            let provider = payload.provider_name.as_deref().unwrap_or("openai");
            let config = format!(
                "model = \"{}\"\nmodel_provider = \"{}\"\n\n[model_providers.{}]\nname = \"{}\"\nbase_url = \"{}\"\nenv_key = \"OPENAI_API_KEY\"\n",
                escape_toml(model),
                escape_toml(provider),
                escape_toml(provider),
                escape_toml(provider),
                escape_toml(&payload.base_url)
            );
            write_text_file(&codex_home.join("config.toml"), &config)
        }
    }
}

fn write_json_file(path: &Path, value: &serde_json::Value) -> Result<(), AppError> {
    let data = serde_json::to_vec_pretty(value)
        .map_err(|error| AppError::AccountActivationFailed(error.to_string()))?;
    write_bytes_file(path, &data)
}

fn write_text_file(path: &Path, text: &str) -> Result<(), AppError> {
    write_bytes_file(path, text.as_bytes())
}

fn write_bytes_file(path: &Path, data: &[u8]) -> Result<(), AppError> {
    let temp = path.with_extension("tmp");
    fs::write(&temp, data).map_err(|error| AppError::AccountActivationFailed(error.to_string()))?;
    fs::rename(&temp, path).map_err(|error| AppError::AccountActivationFailed(error.to_string()))
}

fn escape_toml(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}
```

Keep the tests from Step 2 at the bottom of the file.

- [ ] **Step 5: Run activation tests**

Run:

```powershell
cargo test account_activation --lib
```

Expected: PASS.

- [ ] **Step 6: Commit**

```powershell
git add WindowsTray/src-tauri/src/main.rs WindowsTray/src-tauri/src/account_activation.rs
git commit -m "feat: activate windows accounts"
```

---

### Task 4: Account Commands And Presentation

**Files:**
- Create: `WindowsTray/src-tauri/src/account_commands.rs`
- Modify: `WindowsTray/src-tauri/src/main.rs`
- Modify: `WindowsTray/src-tauri/src/app_state.rs`
- Modify: `WindowsTray/src-tauri/src/localization.rs`
- Test: `WindowsTray/src-tauri/src/account_commands.rs`

- [ ] **Step 1: Extend app state**

Modify `WindowsTray/src-tauri/src/app_state.rs` by adding:

```rust
use std::path::PathBuf;

pub struct AppState {
    pub codex_home: PathBuf,
    pub settings_path: PathBuf,
    pub accounts_dir: PathBuf,
    pub settings: Mutex<AppSettings>,
    pub settings_load_issue: Mutex<Option<String>>,
    pub tray_snapshot: Mutex<TraySnapshot>,
    pub session_manager: Mutex<SessionManager>,
    pub refresh_scheduler: Mutex<RefreshScheduler>,
    pub refresh_in_progress: Mutex<bool>,
    pub quota_timeout: Duration,
}
```

When editing, preserve the existing fields and insert `accounts_dir` after
`settings_path`.

- [ ] **Step 2: Initialize the account directory**

Modify the `AppState` initialization in `WindowsTray/src-tauri/src/main.rs`:

```rust
let accounts_dir = app_data_dir.join("Accounts");

let state: SharedAppState = Arc::new(AppState {
    codex_home,
    settings_path,
    accounts_dir,
    settings: tauri::async_runtime::Mutex::new(settings.clone()),
    settings_load_issue: tauri::async_runtime::Mutex::new(settings_result.issue),
    tray_snapshot: tauri::async_runtime::Mutex::new(TraySnapshot::loading()),
    session_manager: tauri::async_runtime::Mutex::new(SessionManager::new(session_paths)),
    refresh_scheduler: tauri::async_runtime::Mutex::new(RefreshScheduler::new()),
    refresh_in_progress: tauri::async_runtime::Mutex::new(false),
    quota_timeout: Duration::from_secs(10),
});
```

- [ ] **Step 3: Add command module and invoke handler entries**

Modify `WindowsTray/src-tauri/src/main.rs`:

```rust
mod account_activation;
mod account_commands;
mod account_models;
mod account_vault;
```

Update the invoke handler:

```rust
.invoke_handler(tauri::generate_handler![
    get_settings,
    update_settings,
    account_commands::get_accounts,
    account_commands::import_current_chatgpt_account,
    account_commands::add_api_account,
    account_commands::activate_account,
    account_commands::rename_account,
    account_commands::forget_account,
    account_commands::open_vault_folder
])
```

- [ ] **Step 4: Write command presentation tests**

Create `WindowsTray/src-tauri/src/account_commands.rs` with tests:

```rust
use serde::Serialize;

use crate::account_models::{AccountKind, AccountRowState, VaultAccountRecord};
use crate::localization::{localize, LocalizedText};
use crate::settings::ResolvedAppLanguage;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account_models::{AccountId, AddApiAccountInput};
    use crate::account_vault::AccountVault;

    #[test]
    fn builds_empty_accounts_presentation() {
        let temp = tempfile::tempdir().unwrap();
        let vault = AccountVault::new(temp.path().join("Accounts"));

        let presentation = build_accounts_presentation(
            &vault,
            ResolvedAppLanguage::English,
            None,
        )
        .unwrap();

        assert_eq!(presentation.rows.len(), 0);
        assert_eq!(presentation.labels.accounts, "Accounts");
        assert_eq!(presentation.labels.no_saved_accounts, "No saved accounts");
    }

    #[test]
    fn maps_api_record_to_available_row() {
        let temp = tempfile::tempdir().unwrap();
        let vault = AccountVault::new(temp.path().join("Accounts"));
        vault.add_api_account(AddApiAccountInput {
            display_name: "Work API".to_string(),
            api_key: "sk-test".to_string(),
            base_url: "https://api.openai.com/v1".to_string(),
            model: None,
            provider_name: None,
        })
        .unwrap();

        let presentation = build_accounts_presentation(
            &vault,
            ResolvedAppLanguage::English,
            Some("Saved".to_string()),
        )
        .unwrap();

        assert_eq!(presentation.rows[0].display_name, "Work API");
        assert_eq!(presentation.rows[0].kind, AccountKind::Api);
        assert_eq!(presentation.rows[0].state, AccountRowState::Available);
        assert_eq!(presentation.message.as_deref(), Some("Saved"));
    }
}
```

- [ ] **Step 5: Run command tests and verify they fail**

Run:

```powershell
cargo test account_commands --lib
```

Expected: compile fails because `AccountsPresentation`,
`build_accounts_presentation`, and command handlers are not defined.

- [ ] **Step 6: Implement command presentation and handlers**

Implement `account_commands.rs` with:

```rust
use serde::Serialize;
use tauri::{AppHandle, Manager};

use crate::account_activation::activate_account_record;
use crate::account_models::{AccountKind, AccountRowState, AddApiAccountInput};
use crate::account_vault::AccountVault;
use crate::app_state::SharedAppState;
use crate::errors::AppError;
use crate::localization::{app_error_message, localize, resolve_language, LocalizedText};
use crate::settings::ResolvedAppLanguage;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountRow {
    pub id: String,
    pub display_name: String,
    pub kind: AccountKind,
    pub state: AccountRowState,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountLabels {
    pub accounts: String,
    pub sign_in_with_chatgpt: String,
    pub add_api_account: String,
    pub open_vault_folder: String,
    pub activate: String,
    pub rename: String,
    pub forget: String,
    pub current: String,
    pub no_saved_accounts: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountsPresentation {
    pub labels: AccountLabels,
    pub rows: Vec<AccountRow>,
    pub message: Option<String>,
}

pub fn build_accounts_presentation(
    vault: &AccountVault,
    language: ResolvedAppLanguage,
    message: Option<String>,
) -> Result<AccountsPresentation, AppError> {
    let listed = vault.list_accounts()?;
    let rows = listed.records.into_iter().map(|record| AccountRow {
        id: record.id.as_str().to_string(),
        display_name: record.metadata.display_name,
        kind: record.metadata.kind,
        state: AccountRowState::Available,
        status: localize(language, LocalizedText::new("Available", "可用")),
    }).collect();

    Ok(AccountsPresentation {
        labels: AccountLabels {
            accounts: localize(language, LocalizedText::new("Accounts", "账号")),
            sign_in_with_chatgpt: localize(language, LocalizedText::new("Sign in with ChatGPT", "使用 ChatGPT 登录")),
            add_api_account: localize(language, LocalizedText::new("Add API Account", "添加 API 账号")),
            open_vault_folder: localize(language, LocalizedText::new("Open Vault Folder", "打开账号仓文件夹")),
            activate: localize(language, LocalizedText::new("Activate", "激活")),
            rename: localize(language, LocalizedText::new("Rename", "重命名")),
            forget: localize(language, LocalizedText::new("Forget", "移除")),
            current: localize(language, LocalizedText::new("Current", "当前")),
            no_saved_accounts: localize(language, LocalizedText::new("No saved accounts", "暂无已保存账号")),
        },
        rows,
        message: message.or(listed.issue),
    })
}

#[tauri::command]
pub async fn get_accounts(
    state: tauri::State<'_, SharedAppState>,
) -> Result<AccountsPresentation, String> {
    let app_state = state.inner().clone();
    let language = super::current_resolved_language(&app_state).await;
    let vault = AccountVault::new(app_state.accounts_dir.clone());
    build_accounts_presentation(&vault, language, None)
        .map_err(|error| app_error_message(language, &error))
}

#[tauri::command]
pub async fn import_current_chatgpt_account(
    state: tauri::State<'_, SharedAppState>,
    display_name: Option<String>,
) -> Result<AccountsPresentation, String> {
    let app_state = state.inner().clone();
    let language = super::current_resolved_language(&app_state).await;
    let vault = AccountVault::new(app_state.accounts_dir.clone());
    vault.import_current_chatgpt_account(&app_state.codex_home, display_name)
        .map_err(|error| app_error_message(language, &error))?;
    build_accounts_presentation(&vault, language, Some(localize(language, LocalizedText::new("Account saved", "账号已保存"))))
        .map_err(|error| app_error_message(language, &error))
}

#[tauri::command]
pub async fn add_api_account(
    state: tauri::State<'_, SharedAppState>,
    input: AddApiAccountInput,
) -> Result<AccountsPresentation, String> {
    let app_state = state.inner().clone();
    let language = super::current_resolved_language(&app_state).await;
    let vault = AccountVault::new(app_state.accounts_dir.clone());
    vault.add_api_account(input).map_err(|error| app_error_message(language, &error))?;
    build_accounts_presentation(&vault, language, Some(localize(language, LocalizedText::new("Account saved", "账号已保存"))))
        .map_err(|error| app_error_message(language, &error))
}

#[tauri::command]
pub async fn activate_account(
    app: AppHandle,
    state: tauri::State<'_, SharedAppState>,
    account_id: String,
) -> Result<AccountsPresentation, String> {
    let app_state = state.inner().clone();
    let language = super::current_resolved_language(&app_state).await;
    let vault = AccountVault::new(app_state.accounts_dir.clone());
    let record = vault.load_record(&account_id).map_err(|error| app_error_message(language, &error))?;
    activate_account_record(&record, &app_state.codex_home)
        .map_err(|error| app_error_message(language, &error))?;
    super::spawn_refresh(app, app_state.clone());
    build_accounts_presentation(&vault, language, Some(localize(language, LocalizedText::new("Account activated", "账号已激活"))))
        .map_err(|error| app_error_message(language, &error))
}

#[tauri::command]
pub async fn rename_account(
    state: tauri::State<'_, SharedAppState>,
    account_id: String,
    display_name: String,
) -> Result<AccountsPresentation, String> {
    let app_state = state.inner().clone();
    let language = super::current_resolved_language(&app_state).await;
    let vault = AccountVault::new(app_state.accounts_dir.clone());
    vault.rename_account(&account_id, &display_name).map_err(|error| app_error_message(language, &error))?;
    build_accounts_presentation(&vault, language, Some(localize(language, LocalizedText::new("Account renamed", "账号已重命名"))))
        .map_err(|error| app_error_message(language, &error))
}

#[tauri::command]
pub async fn forget_account(
    state: tauri::State<'_, SharedAppState>,
    account_id: String,
) -> Result<AccountsPresentation, String> {
    let app_state = state.inner().clone();
    let language = super::current_resolved_language(&app_state).await;
    let vault = AccountVault::new(app_state.accounts_dir.clone());
    vault.forget_account(&account_id).map_err(|error| app_error_message(language, &error))?;
    build_accounts_presentation(&vault, language, Some(localize(language, LocalizedText::new("Account forgotten", "账号已移除"))))
        .map_err(|error| app_error_message(language, &error))
}

#[tauri::command]
pub async fn open_vault_folder(
    state: tauri::State<'_, SharedAppState>,
) -> Result<(), String> {
    let app_state = state.inner().clone();
    std::fs::create_dir_all(&app_state.accounts_dir).map_err(|error| error.to_string())?;
    open::that(&app_state.accounts_dir).map_err(|error| error.to_string())
}
```

If Rust privacy prevents `super::current_resolved_language` or
`super::spawn_refresh`, change those functions in `main.rs` to `pub(crate)`.

- [ ] **Step 7: Run command tests**

Run:

```powershell
cargo test account_commands --lib
```

Expected: PASS.

- [ ] **Step 8: Run all Rust tests**

Run:

```powershell
cargo test
```

Expected: PASS, allowing existing dead-code warnings only.

- [ ] **Step 9: Commit**

```powershell
git add WindowsTray/src-tauri/src/main.rs WindowsTray/src-tauri/src/app_state.rs WindowsTray/src-tauri/src/account_commands.rs WindowsTray/src-tauri/src/localization.rs
git commit -m "feat: expose windows account commands"
```

---

### Task 5: Tray All Accounts Menu

**Files:**
- Modify: `WindowsTray/src-tauri/src/tray.rs`
- Modify: `WindowsTray/src-tauri/src/main.rs`
- Test: `WindowsTray/src-tauri/src/tray.rs`

- [ ] **Step 1: Add tray account constants**

Modify `WindowsTray/src-tauri/src/tray.rs`:

```rust
pub const MENU_ALL_ACCOUNTS: &str = "all_accounts";
pub const MENU_ACCOUNT_PREFIX: &str = "activate_account:";
```

- [ ] **Step 2: Write failing tray menu tests**

Add tests in `tray.rs`:

```rust
#[test]
fn identifies_account_activation_menu_ids() {
    assert_eq!(
        account_id_from_menu_id("activate_account:acct-api"),
        Some("acct-api".to_string())
    );
    assert_eq!(account_id_from_menu_id("refresh_quota"), None);
}
```

- [ ] **Step 3: Implement account menu id parser**

Add to `tray.rs`:

```rust
pub fn account_id_from_menu_id(menu_id: &str) -> Option<String> {
    menu_id
        .strip_prefix(MENU_ACCOUNT_PREFIX)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}
```

- [ ] **Step 4: Extend `build_menu` signature**

Change `build_menu`, `install_tray`, and `update_tray_menu` to accept:

```rust
accounts: Option<&crate::account_commands::AccountsPresentation>
```

Add an `All Accounts` item before `Refresh Quota`:

```rust
let all_accounts_item = MenuItem::with_id(
    app,
    MENU_ALL_ACCOUNTS,
    localize(language, LocalizedText::new("All Accounts", "全部账号")),
    true,
    None::<&str>,
)?;
```

Build a submenu from account rows. If rows are empty, add disabled
`No saved accounts`. If rows exist, each row id is
`format!("{}{}", MENU_ACCOUNT_PREFIX, row.id)`.

- [ ] **Step 5: Wire account menu clicks**

Modify `handle_menu_event` in `main.rs`:

```rust
if let Some(account_id) = tray::account_id_from_menu_id(menu_id) {
    account_commands::spawn_activate_account_from_tray(app.clone(), state, account_id);
    return;
}
```

Implement `spawn_activate_account_from_tray` in `account_commands.rs` as a
fire-and-forget wrapper that loads the record, activates it, triggers refresh,
and writes any error into `TraySnapshot.last_error`.

- [ ] **Step 6: Update tray rebuild calls**

Where `tray::install_tray` and `tray::update_tray_menu` are called in
`main.rs`, build presentation from the account vault and pass it:

```rust
let vault = account_vault::AccountVault::new(state.accounts_dir.clone());
let accounts = account_commands::build_accounts_presentation(&vault, language, None).ok();
let _ = tray::update_tray_menu(app, &snapshot, language, accounts.as_ref());
```

- [ ] **Step 7: Run tray tests**

Run:

```powershell
cargo test tray --lib
```

Expected: PASS.

- [ ] **Step 8: Commit**

```powershell
git add WindowsTray/src-tauri/src/tray.rs WindowsTray/src-tauri/src/main.rs WindowsTray/src-tauri/src/account_commands.rs
git commit -m "feat: add windows all accounts tray menu"
```

---

### Task 6: Split Frontend And Add Accounts Tab

**Files:**
- Create: `WindowsTray/src/types.ts`
- Create: `WindowsTray/src/dom.ts`
- Create: `WindowsTray/src/settings-view.ts`
- Create: `WindowsTray/src/accounts-view.ts`
- Modify: `WindowsTray/src/main.ts`
- Modify: `WindowsTray/src/styles.css`
- Modify: `WindowsTray/package.json`

- [ ] **Step 1: Update typecheck script**

Modify `WindowsTray/package.json`:

```json
"typecheck": "tsc --noEmit --target ES2022 --module ESNext --moduleResolution bundler --lib DOM,ES2022 src/main.ts src/types.ts src/dom.ts src/settings-view.ts src/accounts-view.ts"
```

- [ ] **Step 2: Create shared frontend types**

Create `WindowsTray/src/types.ts`:

```ts
export type RefreshIntervalPreset =
  | "manual"
  | "oneMinute"
  | "fiveMinutes"
  | "fifteenMinutes";
export type StatusItemStyle = "meter" | "text";
export type AppLanguage = "system" | "english" | "chinese";
export type ResolvedAppLanguage = "english" | "chinese";

export type AppSettings = {
  refreshIntervalPreset: RefreshIntervalPreset;
  launchAtLoginEnabled: boolean;
  statusItemStyle: StatusItemStyle;
  appLanguage: AppLanguage;
  lastResolvedLanguage: ResolvedAppLanguage | null;
};

export type SelectOption = {
  value: string;
  label: string;
};

export type SettingsPresentation = {
  settings: AppSettings;
  resolvedLanguage: ResolvedAppLanguage;
  labels: {
    title: string;
    refreshInterval: string;
    language: string;
    trayStyle: string;
    launchAtLogin: string;
    saved: string;
  };
  refreshIntervalOptions: SelectOption[];
  languageOptions: SelectOption[];
  trayStyleOptions: SelectOption[];
  message: string | null;
};

export type AccountKind = "chatGpt" | "api";
export type AccountRowState = "active" | "available" | "needsAttention";

export type AccountRow = {
  id: string;
  displayName: string;
  kind: AccountKind;
  state: AccountRowState;
  status: string;
};

export type AccountsPresentation = {
  labels: {
    accounts: string;
    signInWithChatgpt: string;
    addApiAccount: string;
    openVaultFolder: string;
    activate: string;
    rename: string;
    forget: string;
    current: string;
    noSavedAccounts: string;
  };
  rows: AccountRow[];
  message: string | null;
};
```

- [ ] **Step 3: Create DOM helpers**

Create `WindowsTray/src/dom.ts`:

```ts
import type { SelectOption } from "./types";

export function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (character) => {
    switch (character) {
      case "&":
        return "&amp;";
      case "<":
        return "&lt;";
      case ">":
        return "&gt;";
      case '"':
        return "&quot;";
      default:
        return "&#39;";
    }
  });
}

export function optionMarkup(options: SelectOption[], selected: string): string {
  return options
    .map((option) => {
      const isSelected = option.value === selected ? " selected" : "";
      return `<option value="${escapeHtml(option.value)}"${isSelected}>${escapeHtml(option.label)}</option>`;
    })
    .join("");
}

export function byId<T extends HTMLElement>(id: string): T {
  const element = document.querySelector<T>(`#${id}`);
  if (!element) {
    throw new Error(`Missing #${id}`);
  }
  return element;
}
```

- [ ] **Step 4: Move General rendering to `settings-view.ts`**

Create `WindowsTray/src/settings-view.ts` by moving the existing General form
rendering from `main.ts` into:

```ts
import { invoke } from "@tauri-apps/api/core";
import { escapeHtml, optionMarkup } from "./dom";
import type { AppSettings, SettingsPresentation } from "./types";

export function renderGeneralSettings(
  presentation: SettingsPresentation,
  onUpdated: (next: SettingsPresentation) => void,
): string {
  const next = presentation;
  queueMicrotask(() => bindGeneralControls(next, onUpdated));
  return `
    <section class="settings-form" aria-label="${escapeHtml(next.labels.title)}">
      <label class="settings-row">
        <span>${escapeHtml(next.labels.refreshInterval)}</span>
        <select id="refreshIntervalPreset">
          ${optionMarkup(next.refreshIntervalOptions, next.settings.refreshIntervalPreset)}
        </select>
      </label>
      <label class="settings-row">
        <span>${escapeHtml(next.labels.language)}</span>
        <select id="appLanguage">
          ${optionMarkup(next.languageOptions, next.settings.appLanguage)}
        </select>
      </label>
      <label class="settings-row">
        <span>${escapeHtml(next.labels.trayStyle)}</span>
        <select id="statusItemStyle">
          ${optionMarkup(next.trayStyleOptions, next.settings.statusItemStyle)}
        </select>
      </label>
      <label class="settings-check">
        <input id="launchAtLoginEnabled" type="checkbox"${next.settings.launchAtLoginEnabled ? " checked" : ""} />
        <span>${escapeHtml(next.labels.launchAtLogin)}</span>
      </label>
    </section>
  `;
}

function readSettingsFromDom(previous: AppSettings): AppSettings {
  return {
    ...previous,
    refreshIntervalPreset: (document.querySelector<HTMLSelectElement>("#refreshIntervalPreset")?.value ?? "fiveMinutes") as AppSettings["refreshIntervalPreset"],
    appLanguage: (document.querySelector<HTMLSelectElement>("#appLanguage")?.value ?? "system") as AppSettings["appLanguage"],
    statusItemStyle: (document.querySelector<HTMLSelectElement>("#statusItemStyle")?.value ?? "meter") as AppSettings["statusItemStyle"],
    launchAtLoginEnabled: document.querySelector<HTMLInputElement>("#launchAtLoginEnabled")?.checked ?? false,
  };
}

function bindGeneralControls(
  presentation: SettingsPresentation,
  onUpdated: (next: SettingsPresentation) => void,
): void {
  for (const id of ["refreshIntervalPreset", "appLanguage", "statusItemStyle", "launchAtLoginEnabled"]) {
    document.querySelector(`#${id}`)?.addEventListener("change", async () => {
      const updated = await invoke<SettingsPresentation>("update_settings", {
        updated: readSettingsFromDom(presentation.settings),
      });
      onUpdated(updated);
    });
  }
}
```

- [ ] **Step 5: Create Accounts rendering**

Create `WindowsTray/src/accounts-view.ts`:

```ts
import { invoke } from "@tauri-apps/api/core";
import { escapeHtml } from "./dom";
import type { AccountsPresentation } from "./types";

export function renderAccounts(
  presentation: AccountsPresentation,
  onUpdated: (next: AccountsPresentation) => void,
): string {
  queueMicrotask(() => bindAccountControls(onUpdated));
  const rows = presentation.rows.length
    ? presentation.rows.map((row) => `
      <div class="account-row" data-account-id="${escapeHtml(row.id)}">
        <div>
          <strong>${escapeHtml(row.displayName)}</strong>
          <span>${escapeHtml(row.kind === "chatGpt" ? "ChatGPT" : "API")}</span>
          <small>${escapeHtml(row.status)}</small>
        </div>
        <div class="account-actions">
          <button data-action="activate" data-account-id="${escapeHtml(row.id)}">${escapeHtml(presentation.labels.activate)}</button>
          <button data-action="rename" data-account-id="${escapeHtml(row.id)}">${escapeHtml(presentation.labels.rename)}</button>
          <button data-action="forget" data-account-id="${escapeHtml(row.id)}">${escapeHtml(presentation.labels.forget)}</button>
        </div>
      </div>
    `).join("")
    : `<p class="settings-status">${escapeHtml(presentation.labels.noSavedAccounts)}</p>`;

  return `
    <section class="accounts-panel">
      <div class="accounts-toolbar">
        <button id="importChatGpt">${escapeHtml(presentation.labels.signInWithChatgpt)}</button>
        <button id="showApiForm">${escapeHtml(presentation.labels.addApiAccount)}</button>
        <button id="openVaultFolder">${escapeHtml(presentation.labels.openVaultFolder)}</button>
      </div>
      <form id="apiAccountForm" class="api-form" hidden>
        <label>Display name<input id="apiDisplayName" /></label>
        <label>API key<input id="apiKey" /></label>
        <label>Base URL<input id="apiBaseUrl" /></label>
        <label>Model<input id="apiModel" /></label>
        <label>Provider name<input id="apiProviderName" /></label>
        <button type="submit">${escapeHtml(presentation.labels.addApiAccount)}</button>
      </form>
      <div class="account-list">${rows}</div>
      <p id="accountsStatus" class="settings-status">${escapeHtml(presentation.message ?? "")}</p>
    </section>
  `;
}

function bindAccountControls(onUpdated: (next: AccountsPresentation) => void): void {
  document.querySelector("#importChatGpt")?.addEventListener("click", async () => {
    onUpdated(await invoke<AccountsPresentation>("import_current_chatgpt_account", { displayName: null }));
  });
  document.querySelector("#showApiForm")?.addEventListener("click", () => {
    const form = document.querySelector<HTMLFormElement>("#apiAccountForm");
    if (form) {
      form.hidden = !form.hidden;
    }
  });
  document.querySelector("#openVaultFolder")?.addEventListener("click", async () => {
    await invoke("open_vault_folder");
  });
  document.querySelector("#apiAccountForm")?.addEventListener("submit", async (event) => {
    event.preventDefault();
    onUpdated(await invoke<AccountsPresentation>("add_api_account", {
      input: {
        displayName: document.querySelector<HTMLInputElement>("#apiDisplayName")?.value ?? "",
        apiKey: document.querySelector<HTMLInputElement>("#apiKey")?.value ?? "",
        baseUrl: document.querySelector<HTMLInputElement>("#apiBaseUrl")?.value ?? "",
        model: document.querySelector<HTMLInputElement>("#apiModel")?.value || null,
        providerName: document.querySelector<HTMLInputElement>("#apiProviderName")?.value || null,
      },
    }));
  });
  for (const button of document.querySelectorAll<HTMLButtonElement>("[data-action]")) {
    button.addEventListener("click", async () => {
      const accountId = button.dataset.accountId ?? "";
      const action = button.dataset.action;
      if (action === "activate" && confirm("Activate this account for local Codex? This updates files in your Codex home.")) {
        onUpdated(await invoke<AccountsPresentation>("activate_account", { accountId }));
      }
      if (action === "rename") {
        const displayName = prompt("Rename account");
        if (displayName) {
          onUpdated(await invoke<AccountsPresentation>("rename_account", { accountId, displayName }));
        }
      }
      if (action === "forget" && confirm("Forget this account?")) {
        onUpdated(await invoke<AccountsPresentation>("forget_account", { accountId }));
      }
    });
  }
}
```

- [ ] **Step 6: Replace `main.ts` with tab shell**

Replace `WindowsTray/src/main.ts` with:

```ts
import { invoke } from "@tauri-apps/api/core";
import { renderAccounts } from "./accounts-view";
import { escapeHtml } from "./dom";
import { renderGeneralSettings } from "./settings-view";
import type { AccountsPresentation, SettingsPresentation } from "./types";

const app = document.querySelector<HTMLDivElement>("#app");

if (!app) {
  throw new Error("Missing #app element");
}

let settingsPresentation: SettingsPresentation | null = null;
let accountsPresentation: AccountsPresentation | null = null;
let activeTab: "general" | "accounts" = "general";

function render(): void {
  if (!settingsPresentation || !accountsPresentation) {
    return;
  }
  document.title = settingsPresentation.labels.title;
  const body =
    activeTab === "general"
      ? renderGeneralSettings(settingsPresentation, (next) => {
          settingsPresentation = next;
          render();
        })
      : renderAccounts(accountsPresentation, (next) => {
          accountsPresentation = next;
          render();
        });

  app.innerHTML = `
    <main class="settings-shell">
      <header class="settings-header">
        <h1>${escapeHtml(settingsPresentation.labels.title)}</h1>
        <nav class="settings-tabs">
          <button id="tabGeneral" class="${activeTab === "general" ? "active" : ""}">General</button>
          <button id="tabAccounts" class="${activeTab === "accounts" ? "active" : ""}">${escapeHtml(accountsPresentation.labels.accounts)}</button>
        </nav>
      </header>
      ${body}
    </main>
  `;
  document.querySelector("#tabGeneral")?.addEventListener("click", () => {
    activeTab = "general";
    render();
  });
  document.querySelector("#tabAccounts")?.addEventListener("click", () => {
    activeTab = "accounts";
    render();
  });
}

async function load(): Promise<void> {
  try {
    settingsPresentation = await invoke<SettingsPresentation>("get_settings");
    accountsPresentation = await invoke<AccountsPresentation>("get_accounts");
    render();
  } catch (error) {
    app.textContent = String(error);
  }
}

void load();
```

- [ ] **Step 7: Add compact styles**

Append to `WindowsTray/src/styles.css`:

```css
.settings-tabs {
  display: flex;
  gap: 8px;
}

.settings-tabs button.active {
  font-weight: 700;
}

.accounts-panel {
  display: grid;
  gap: 12px;
}

.accounts-toolbar,
.account-actions {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
}

.api-form {
  display: grid;
  gap: 8px;
  grid-template-columns: 1fr 1fr;
}

.api-form[hidden] {
  display: none;
}

.account-list {
  display: grid;
  gap: 8px;
}

.account-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 10px;
  border: 1px solid #d6d6d6;
  border-radius: 8px;
}

.account-row strong,
.account-row span,
.account-row small {
  display: block;
}
```

- [ ] **Step 8: Run frontend typecheck**

Run:

```powershell
corepack npm --prefix WindowsTray run typecheck
```

Expected: PASS.

- [ ] **Step 9: Commit**

```powershell
git add WindowsTray/package.json WindowsTray/src/main.ts WindowsTray/src/types.ts WindowsTray/src/dom.ts WindowsTray/src/settings-view.ts WindowsTray/src/accounts-view.ts WindowsTray/src/styles.css
git commit -m "feat: add windows accounts settings UI"
```

---

### Task 7: Documentation And Final Verification

**Files:**
- Modify: `docs/windows-mvp.md`
- Modify: `README.md`
- Modify: `README.zh-CN.md`

- [ ] **Step 1: Update Windows docs feature list**

Modify `docs/windows-mvp.md` under `## Features` to include:

```markdown
- Saves multiple ChatGPT and API accounts in a local Windows account vault.
- Imports the current local ChatGPT Codex login as a saved account.
- Adds OpenAI-compatible API accounts from the Windows settings window.
- Activates saved accounts directly into the resolved Codex home.
- Shows saved accounts in an `All Accounts` tray submenu.
```

- [ ] **Step 2: Update Windows docs exclusions**

Modify `docs/windows-mvp.md` under `## Not Included In The MVP` by removing:

```markdown
- Multiple saved accounts.
- Accounts settings beyond the General settings page.
```

Keep these exclusions:

```markdown
- Full Safe Switch orchestration.
- Rollback restore points.
- Thread/provider repair after account activation.
```

- [ ] **Step 3: Add direct activation caveat**

Add to `docs/windows-mvp.md` after `## Local Data`:

```markdown
## Account Activation

Windows account activation currently writes directly into the resolved Codex
home. It does not yet create restore points or perform the full Safe Switch
repair flow available in the macOS app. Use the confirmation prompt as the
boundary for this direct activation behavior.
```

- [ ] **Step 4: Update README Windows scope**

In `README.md`, update the Windows tray section to say:

```markdown
The Windows tray app supports current quota display, configurable refresh,
General and Accounts settings, saved ChatGPT/API accounts, direct account
activation, opening the bundled Session Manager, opening the local Codex
folder, and clean quit.
```

- [ ] **Step 5: Update Chinese README Windows scope**

In `README.zh-CN.md`, update the matching Windows section to say:

```markdown
Windows 托盘应用支持当前额度显示、可配置刷新频率、General 和 Accounts 设置、保存
ChatGPT/API 账号、直接激活账号、打开内置 Session Manager、打开本地 Codex 目录，以及干净退出。
```

- [ ] **Step 6: Run Rust tests**

Run:

```powershell
cargo test
```

Working directory:

```text
E:\learning\Codex-Quota-Viewer\WindowsTray\src-tauri
```

Expected: PASS.

- [ ] **Step 7: Run frontend typecheck**

Run:

```powershell
corepack npm --prefix WindowsTray run typecheck
```

Expected: PASS.

- [ ] **Step 8: Run Tauri build check**

Run:

```powershell
corepack npm --prefix WindowsTray run build:frontend
```

Expected: PASS and `WindowsTray/dist` created or refreshed.

- [ ] **Step 9: Check Git diff**

Run:

```powershell
git diff --check
git status --short
```

Expected: no whitespace errors, only intended files modified.

- [ ] **Step 10: Commit**

```powershell
git add docs/windows-mvp.md README.md README.zh-CN.md
git commit -m "docs: update windows account management scope"
```

---

## Final Manual Verification

Run the Windows app locally:

```powershell
corepack npm --prefix WindowsTray run dev
```

Verify:

- App starts hidden in the tray.
- `Settings...` opens a window with `General` and `Accounts`.
- `General` settings still load and save.
- `Sign in with ChatGPT` saves current Codex login when `auth.json` exists.
- `Add API Account` saves an API account.
- `Rename` updates the visible row.
- `Forget` removes the row after confirmation.
- `Activate` writes Codex home files and triggers quota refresh.
- Tray `All Accounts` shows saved accounts.
- `Open Session Manager` still opens the bundled Session Manager.
- `Open Codex Folder` still opens the resolved Codex home.
- `Quit` stops the owned Session Manager sidecar and exits.

## Self-Review

- Spec coverage: The plan covers account vault storage, current ChatGPT import,
  API account creation, activation, rename, forget, vault folder opening,
  Accounts tab, `All Accounts` tray menu, docs, and tests.
- Out of scope: Browser OAuth, Safe Switch, restore points, rollback, and repair
  are intentionally excluded.
- Type consistency: Rust account types use camelCase serde output matching the
  frontend `types.ts` definitions. Account ids are strings across the Tauri
  boundary.
