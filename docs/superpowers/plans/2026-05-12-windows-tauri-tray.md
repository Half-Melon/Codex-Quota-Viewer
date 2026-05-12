# Windows Tauri Tray MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Windows Tauri tray MVP that shows current Codex quota, refreshes it, opens the bundled Session Manager, opens the local Codex folder, and quits cleanly.

**Architecture:** Add a new `WindowsTray/` Tauri app beside the existing Swift macOS app. Rust owns tray state, Codex RPC, Windows path resolution, and Session Manager process lifecycle; the minimal TypeScript frontend exists only to satisfy Tauri and does not become a primary UI.

**Tech Stack:** Tauri 2, Rust 2021, Tokio, Serde, Reqwest, Node sidecar for `Vendor/CodexMM`, PowerShell build scripts.

---

## File Structure

- Create: `WindowsTray/package.json` - npm scripts for Tauri development and build.
- Create: `WindowsTray/index.html` - minimal Tauri frontend entry.
- Create: `WindowsTray/src/main.ts` - minimal frontend bootstrap.
- Create: `WindowsTray/src-tauri/Cargo.toml` - Rust dependencies and Tauri tray feature.
- Create: `WindowsTray/src-tauri/tauri.conf.json` - Windows app metadata, resources, sidecar config, hidden window behavior.
- Create: `WindowsTray/src-tauri/src/main.rs` - app entry, shared state, tray setup, async command dispatch.
- Create: `WindowsTray/src-tauri/src/app_state.rs` - in-memory tray/quota/session state.
- Create: `WindowsTray/src-tauri/src/codex_home.rs` - Windows Codex home resolution.
- Create: `WindowsTray/src-tauri/src/errors.rs` - stable user-facing error categories.
- Create: `WindowsTray/src-tauri/src/quota.rs` - Codex app-server JSON-RPC quota fetcher and display formatting.
- Create: `WindowsTray/src-tauri/src/session_manager.rs` - health check, bundled Node process startup, browser opening, owned process shutdown.
- Create: `WindowsTray/src-tauri/src/tray.rs` - tray menu construction and event handling.
- Create: `WindowsTray/src-tauri/icons/icon.ico` - Windows tray/app icon copied or generated from existing assets.
- Create: `scripts/build-session-manager-windows.ps1` - build `Vendor/CodexMM` for Windows packaging.
- Create: `scripts/build-windows-tray.ps1` - stage resources, verify Node runtime, run Tauri build.
- Modify: `.gitignore` - ignore generated Windows tray build resources and downloaded runtimes.
- Modify: `README.md` - document Windows MVP scope and build instructions.

---

### Task 1: Scaffold The Windows Tauri App

**Files:**
- Create: `WindowsTray/package.json`
- Create: `WindowsTray/index.html`
- Create: `WindowsTray/src/main.ts`
- Create: `WindowsTray/src-tauri/Cargo.toml`
- Create: `WindowsTray/src-tauri/tauri.conf.json`
- Create: `WindowsTray/src-tauri/src/main.rs`
- Create: `WindowsTray/src-tauri/icons/icon.ico`
- Modify: `.gitignore`

- [ ] **Step 1: Create the npm package file**

Create `WindowsTray/package.json` with:

```json
{
  "name": "codex-quota-viewer-windows-tray",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "tauri dev",
    "build": "tauri build",
    "typecheck": "tsc --noEmit"
  },
  "devDependencies": {
    "@tauri-apps/cli": "^2.0.0",
    "typescript": "^5.9.2",
    "vite": "^8.0.3"
  },
  "dependencies": {
    "@tauri-apps/api": "^2.0.0"
  }
}
```

- [ ] **Step 2: Create the minimal frontend files**

Create `WindowsTray/index.html` with:

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Codex Quota Viewer</title>
  </head>
  <body>
    <div id="app"></div>
    <script type="module" src="/src/main.ts"></script>
  </body>
</html>
```

Create `WindowsTray/src/main.ts` with:

```ts
document.querySelector<HTMLDivElement>("#app")!.textContent =
  "Codex Quota Viewer is running in the Windows system tray.";
```

- [ ] **Step 3: Create the Rust manifest**

Create `WindowsTray/src-tauri/Cargo.toml` with:

```toml
[package]
name = "codex-quota-viewer-windows-tray"
version = "0.1.0"
description = "Windows tray MVP for Codex Quota Viewer"
edition = "2021"

[lib]
name = "codex_quota_viewer_windows_tray"
crate-type = ["staticlib", "cdylib", "rlib"]

[build-dependencies]
tauri-build = { version = "2", features = [] }

[dependencies]
anyhow = "1"
chrono = { version = "0.4", features = ["serde"] }
open = "5"
reqwest = { version = "0.12", default-features = false, features = ["json", "rustls-tls"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tauri = { version = "2", features = ["tray-icon"] }
tokio = { version = "1", features = ["macros", "process", "rt-multi-thread", "time"] }

[dev-dependencies]
tempfile = "3"
wiremock = "0.6"
```

- [ ] **Step 4: Create the Tauri configuration**

Create `WindowsTray/src-tauri/tauri.conf.json` with:

```json
{
  "$schema": "https://schema.tauri.app/config/2",
  "productName": "Codex Quota Viewer",
  "version": "0.1.0",
  "identifier": "com.halfmelon.codexquotaviewer.windows",
  "build": {
    "beforeDevCommand": "",
    "beforeBuildCommand": "",
    "devUrl": "http://localhost:1420",
    "frontendDist": "../dist"
  },
  "app": {
    "windows": [
      {
        "title": "Codex Quota Viewer",
        "width": 480,
        "height": 240,
        "visible": false
      }
    ],
    "security": {
      "csp": null
    }
  },
  "bundle": {
    "active": true,
    "targets": ["msi", "nsis"],
    "icon": ["icons/icon.ico"],
    "resources": {
      "resources/session-manager": "SessionManager",
      "resources/node-runtime": "NodeRuntime"
    }
  }
}
```

- [ ] **Step 5: Create the first Rust entry point**

Create `WindowsTray/src-tauri/src/main.rs` with:

```rust
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    tauri::Builder::default()
        .setup(|_app| Ok(()))
        .run(tauri::generate_context!())
        .expect("failed to run Codex Quota Viewer Windows tray app");
}
```

- [ ] **Step 6: Add ignore rules for generated Windows artifacts**

Append these lines to `.gitignore`:

```gitignore
WindowsTray/node_modules/
WindowsTray/dist/
WindowsTray/src-tauri/target/
WindowsTray/src-tauri/resources/
WindowsTray/src-tauri/NodeRuntime/
WindowsTray/src-tauri/SessionManager/
```

- [ ] **Step 7: Add a temporary icon**

Create `WindowsTray/src-tauri/icons/icon.ico` by converting the existing app icon asset or using a simple generated Windows `.ico`. Keep this file committed because Tauri requires an icon at build time.

- [ ] **Step 8: Verify scaffold**

Run:

```powershell
Set-Location WindowsTray
corepack npm install
corepack npm run typecheck
```

Expected: npm installs dependencies and TypeScript exits with code `0`.

- [ ] **Step 9: Commit scaffold**

```powershell
git add .gitignore WindowsTray
git commit -m "feat: scaffold windows tauri tray app"
```

---

### Task 2: Add Codex Home Resolution And Error Categories

**Files:**
- Create: `WindowsTray/src-tauri/src/errors.rs`
- Create: `WindowsTray/src-tauri/src/codex_home.rs`
- Modify: `WindowsTray/src-tauri/src/main.rs`

- [ ] **Step 1: Write failing tests for Codex home resolution**

Create `WindowsTray/src-tauri/src/codex_home.rs` with the tests first:

```rust
use std::path::{Path, PathBuf};

pub fn resolve_codex_home_from_env(_env: &dyn Fn(&str) -> Option<String>) -> Result<PathBuf, crate::errors::AppError> {
    unreachable!("implemented in Step 3");
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn env_from(values: HashMap<&str, &str>) -> impl Fn(&str) -> Option<String> {
        move |key| values.get(key).map(|value| value.to_string())
    }

    #[test]
    fn uses_explicit_codex_home_when_present() {
        let mut values = HashMap::new();
        values.insert("CODEX_HOME", r"C:\CodexHome");
        values.insert("USERPROFILE", r"C:\Users\Ada");

        let home = resolve_codex_home_from_env(&env_from(values)).unwrap();

        assert_eq!(home, Path::new(r"C:\CodexHome"));
    }

    #[test]
    fn falls_back_to_userprofile_dot_codex() {
        let mut values = HashMap::new();
        values.insert("USERPROFILE", r"C:\Users\Ada");

        let home = resolve_codex_home_from_env(&env_from(values)).unwrap();

        assert_eq!(home, Path::new(r"C:\Users\Ada\.codex"));
    }

    #[test]
    fn reports_missing_userprofile() {
        let values = HashMap::new();

        let error = resolve_codex_home_from_env(&env_from(values)).unwrap_err();

        assert_eq!(error.user_message(), "Codex folder not found");
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```powershell
Set-Location WindowsTray\src-tauri
cargo test codex_home
```

Expected: compile fails because `crate::errors::AppError` does not exist.

- [ ] **Step 3: Add stable app errors**

Create `WindowsTray/src-tauri/src/errors.rs`:

```rust
use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AppError {
    CodexFolderNotFound,
    SignInRequired,
    QuotaTimeout,
    QuotaRefreshFailed(String),
    SessionManagerPortInUse,
    SessionManagerFilesIncomplete,
    NodeRuntimeMissing,
    SessionManagerStartFailed(String),
}

impl AppError {
    pub fn user_message(&self) -> &'static str {
        match self {
            Self::CodexFolderNotFound => "Codex folder not found",
            Self::SignInRequired => "Sign in required",
            Self::QuotaTimeout => "Timed out while reading quota",
            Self::QuotaRefreshFailed(_) => "Quota refresh failed",
            Self::SessionManagerPortInUse => "Session Manager port 4318 is already in use",
            Self::SessionManagerFilesIncomplete => "Bundled Session Manager files are incomplete",
            Self::NodeRuntimeMissing => "Bundled Node runtime is missing",
            Self::SessionManagerStartFailed(_) => "Session Manager could not start",
        }
    }

    pub fn diagnostics(&self) -> Option<&str> {
        match self {
            Self::QuotaRefreshFailed(message) | Self::SessionManagerStartFailed(message) => Some(message),
            _ => None,
        }
    }
}

impl fmt::Display for AppError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.user_message())
    }
}

impl std::error::Error for AppError {}
```

- [ ] **Step 4: Implement Codex home resolution**

Replace the initial failing implementation in `WindowsTray/src-tauri/src/codex_home.rs`:

```rust
use std::path::{Path, PathBuf};

use crate::errors::AppError;

pub fn resolve_codex_home() -> Result<PathBuf, AppError> {
    resolve_codex_home_from_env(&|key| std::env::var(key).ok())
}

pub fn resolve_codex_home_from_env(env: &dyn Fn(&str) -> Option<String>) -> Result<PathBuf, AppError> {
    if let Some(explicit) = env("CODEX_HOME").filter(|value| !value.trim().is_empty()) {
        return Ok(PathBuf::from(explicit));
    }

    let user_profile = env("USERPROFILE")
        .filter(|value| !value.trim().is_empty())
        .ok_or(AppError::CodexFolderNotFound)?;

    Ok(Path::new(&user_profile).join(".codex"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn env_from(values: HashMap<&str, &str>) -> impl Fn(&str) -> Option<String> {
        move |key| values.get(key).map(|value| value.to_string())
    }

    #[test]
    fn uses_explicit_codex_home_when_present() {
        let mut values = HashMap::new();
        values.insert("CODEX_HOME", r"C:\CodexHome");
        values.insert("USERPROFILE", r"C:\Users\Ada");

        let home = resolve_codex_home_from_env(&env_from(values)).unwrap();

        assert_eq!(home, Path::new(r"C:\CodexHome"));
    }

    #[test]
    fn falls_back_to_userprofile_dot_codex() {
        let mut values = HashMap::new();
        values.insert("USERPROFILE", r"C:\Users\Ada");

        let home = resolve_codex_home_from_env(&env_from(values)).unwrap();

        assert_eq!(home, Path::new(r"C:\Users\Ada\.codex"));
    }

    #[test]
    fn reports_missing_userprofile() {
        let values = HashMap::new();

        let error = resolve_codex_home_from_env(&env_from(values)).unwrap_err();

        assert_eq!(error.user_message(), "Codex folder not found");
    }
}
```

- [ ] **Step 5: Wire modules into the entry point**

Update `WindowsTray/src-tauri/src/main.rs`:

```rust
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod codex_home;
mod errors;

fn main() {
    tauri::Builder::default()
        .setup(|_app| Ok(()))
        .run(tauri::generate_context!())
        .expect("failed to run Codex Quota Viewer Windows tray app");
}
```

- [ ] **Step 6: Run tests**

Run:

```powershell
Set-Location WindowsTray\src-tauri
cargo test codex_home errors
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```powershell
git add WindowsTray/src-tauri/src/main.rs WindowsTray/src-tauri/src/errors.rs WindowsTray/src-tauri/src/codex_home.rs
git commit -m "feat: resolve windows codex home"
```

---

### Task 3: Implement Current Account Quota Fetching

**Files:**
- Create: `WindowsTray/src-tauri/src/quota.rs`
- Modify: `WindowsTray/src-tauri/src/main.rs`

- [ ] **Step 1: Write failing quota parsing tests**

Create `WindowsTray/src-tauri/src/quota.rs` with:

```rust
use std::path::Path;
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::errors::AppError;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountSummary {
    pub id: Option<String>,
    pub email: Option<String>,
    pub account_type: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QuotaWindow {
    pub label: String,
    pub remaining_percent: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QuotaSnapshot {
    pub account: AccountSummary,
    pub windows: Vec<QuotaWindow>,
    pub fetched_at: DateTime<Utc>,
}

pub fn parse_snapshot_from_rpc_values(_account: serde_json::Value, _rate_limits: serde_json::Value) -> Result<QuotaSnapshot, AppError> {
    unreachable!("implemented in Step 3");
}

pub async fn fetch_current_quota(_codex_home: &Path, _timeout: Duration) -> Result<QuotaSnapshot, AppError> {
    unreachable!("implemented in Step 5");
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_five_hour_and_weekly_windows() {
        let snapshot = parse_snapshot_from_rpc_values(
            json!({
                "account": {
                    "id": "acct_123",
                    "email": "ada@example.com",
                    "type": "chatgpt"
                }
            }),
            json!({
                "rateLimits": {
                    "windows": [
                        { "label": "5h", "remainingPercent": 42.5 },
                        { "label": "1w", "remainingPercent": 88.0 }
                    ]
                }
            }),
        ).unwrap();

        assert_eq!(snapshot.account.email.as_deref(), Some("ada@example.com"));
        assert_eq!(snapshot.windows[0].label, "5h");
        assert_eq!(snapshot.windows[0].remaining_percent, 42.5);
        assert_eq!(snapshot.windows[1].label, "1w");
    }

    #[test]
    fn reports_sign_in_required_when_account_is_null() {
        let error = parse_snapshot_from_rpc_values(
            json!({ "account": null }),
            json!({ "rateLimits": { "windows": [] } }),
        ).unwrap_err();

        assert_eq!(error, AppError::SignInRequired);
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```powershell
Set-Location WindowsTray\src-tauri
cargo test quota
```

Expected: tests fail because `parse_snapshot_from_rpc_values` has not been implemented yet.

- [ ] **Step 3: Implement quota parsing**

Replace `parse_snapshot_from_rpc_values` in `WindowsTray/src-tauri/src/quota.rs`:

```rust
pub fn parse_snapshot_from_rpc_values(
    account_value: serde_json::Value,
    rate_limits_value: serde_json::Value,
) -> Result<QuotaSnapshot, AppError> {
    let account_node = account_value
        .get("account")
        .cloned()
        .ok_or_else(|| AppError::QuotaRefreshFailed("account/read missing account".to_string()))?;

    if account_node.is_null() {
        return Err(AppError::SignInRequired);
    }

    let account = AccountSummary {
        id: account_node.get("id").and_then(|value| value.as_str()).map(str::to_string),
        email: account_node.get("email").and_then(|value| value.as_str()).map(str::to_string),
        account_type: account_node
            .get("type")
            .and_then(|value| value.as_str())
            .unwrap_or("unknown")
            .to_string(),
    };

    let windows_node = rate_limits_value
        .get("rateLimits")
        .and_then(|value| value.get("windows"))
        .and_then(|value| value.as_array())
        .ok_or_else(|| AppError::QuotaRefreshFailed("rateLimits windows missing".to_string()))?;

    let windows = windows_node
        .iter()
        .filter_map(|window| {
            let label = window.get("label")?.as_str()?.to_string();
            let remaining_percent = window.get("remainingPercent")?.as_f64()?;
            Some(QuotaWindow {
                label,
                remaining_percent,
            })
        })
        .collect();

    Ok(QuotaSnapshot {
        account,
        windows,
        fetched_at: Utc::now(),
    })
}
```

- [ ] **Step 4: Add process JSON-RPC helpers**

Add below the parser in `WindowsTray/src-tauri/src/quota.rs`:

```rust
use std::process::Stdio;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::time::timeout;

fn codex_command() -> Command {
    let mut command = Command::new("codex");
    command.args(["-s", "read-only", "-a", "untrusted", "app-server"]);
    command
}

async fn send_rpc_line(
    stdin: &mut tokio::process::ChildStdin,
    id: &str,
    method: &str,
) -> Result<(), AppError> {
    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": {}
    });
    let mut line = serde_json::to_vec(&body)
        .map_err(|error| AppError::QuotaRefreshFailed(error.to_string()))?;
    line.push(b'\n');
    stdin
        .write_all(&line)
        .await
        .map_err(|error| AppError::QuotaRefreshFailed(error.to_string()))
}
```

- [ ] **Step 5: Implement current quota fetching**

Replace `fetch_current_quota` in `WindowsTray/src-tauri/src/quota.rs`:

```rust
pub async fn fetch_current_quota(codex_home: &Path, timeout_duration: Duration) -> Result<QuotaSnapshot, AppError> {
    if !codex_home.exists() {
        return Err(AppError::CodexFolderNotFound);
    }

    let mut command = codex_command();
    command.env("CODEX_HOME", codex_home);
    command.stdin(Stdio::piped());
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());

    let mut child = command
        .spawn()
        .map_err(|error| AppError::QuotaRefreshFailed(error.to_string()))?;

    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| AppError::QuotaRefreshFailed("codex stdin unavailable".to_string()))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| AppError::QuotaRefreshFailed("codex stdout unavailable".to_string()))?;

    let read_task = async {
        send_rpc_line(&mut stdin, "1", "initialize").await?;
        send_rpc_line(&mut stdin, "2", "account/read").await?;
        send_rpc_line(&mut stdin, "3", "account/rateLimits/read").await?;

        let mut account: Option<serde_json::Value> = None;
        let mut rate_limits: Option<serde_json::Value> = None;
        let mut lines = BufReader::new(stdout).lines();

        while let Some(line) = lines
            .next_line()
            .await
            .map_err(|error| AppError::QuotaRefreshFailed(error.to_string()))?
        {
            let message: serde_json::Value = serde_json::from_str(&line)
                .map_err(|error| AppError::QuotaRefreshFailed(error.to_string()))?;

            if let Some(error) = message.get("error") {
                let code = error.get("code").and_then(|value| value.as_i64()).unwrap_or_default();
                if code == -32600 {
                    return Err(AppError::SignInRequired);
                }
                return Err(AppError::QuotaRefreshFailed(error.to_string()));
            }

            match message.get("id").and_then(|value| value.as_str()) {
                Some("2") => account = message.get("result").cloned(),
                Some("3") => rate_limits = message.get("result").cloned(),
                _ => {}
            }

            if let (Some(account), Some(rate_limits)) = (account.clone(), rate_limits.clone()) {
                return parse_snapshot_from_rpc_values(account, rate_limits);
            }
        }

        Err(AppError::QuotaRefreshFailed("codex app-server exited before quota was read".to_string()))
    };

    let result = timeout(timeout_duration, read_task)
        .await
        .map_err(|_| AppError::QuotaTimeout)?;

    if let Err(error) = child.kill().await {
        let _ = error;
    }

    result
}
```

- [ ] **Step 6: Wire module into main**

Update `WindowsTray/src-tauri/src/main.rs`:

```rust
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod codex_home;
mod errors;
mod quota;

fn main() {
    tauri::Builder::default()
        .setup(|_app| Ok(()))
        .run(tauri::generate_context!())
        .expect("failed to run Codex Quota Viewer Windows tray app");
}
```

- [ ] **Step 7: Run tests**

Run:

```powershell
Set-Location WindowsTray\src-tauri
cargo test quota
```

Expected: parser tests pass. Process-dependent behavior is covered by manual Windows verification in Task 8.

- [ ] **Step 8: Commit**

```powershell
git add WindowsTray/src-tauri/src/main.rs WindowsTray/src-tauri/src/quota.rs
git commit -m "feat: fetch current codex quota on windows"
```

---

### Task 4: Add Session Manager Health Check And Sidecar Lifecycle

**Files:**
- Create: `WindowsTray/src-tauri/src/session_manager.rs`
- Modify: `WindowsTray/src-tauri/src/main.rs`

- [ ] **Step 1: Write failing health classification tests**

Create `WindowsTray/src-tauri/src/session_manager.rs` with:

```rust
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use crate::errors::AppError;

#[derive(Debug, Clone)]
pub struct SessionManagerPaths {
    pub node_exe: PathBuf,
    pub server_entry: PathBuf,
    pub app_dir: PathBuf,
}

pub struct SessionManager {
    paths: SessionManagerPaths,
    owned_child: Option<tokio::process::Child>,
}

impl SessionManager {
    pub fn new(paths: SessionManagerPaths) -> Self {
        Self {
            paths,
            owned_child: None,
        }
    }
}

pub fn classify_startup_diagnostics(_text: &str) -> AppError {
    unreachable!("implemented in Step 3");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_port_conflict() {
        let error = classify_startup_diagnostics("Error: listen EADDRINUSE: address already in use 127.0.0.1:4318");
        assert_eq!(error, AppError::SessionManagerPortInUse);
    }

    #[test]
    fn classifies_missing_module_as_incomplete_bundle() {
        let error = classify_startup_diagnostics("Error: Cannot find module './dist/server/index.js'");
        assert_eq!(error, AppError::SessionManagerFilesIncomplete);
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```powershell
Set-Location WindowsTray\src-tauri
cargo test session_manager
```

Expected: tests fail because `classify_startup_diagnostics` has not been implemented yet.

- [ ] **Step 3: Implement diagnostic classification**

Replace the initial failing implementation in `WindowsTray/src-tauri/src/session_manager.rs`:

```rust
pub fn classify_startup_diagnostics(text: &str) -> AppError {
    let lowered = text.to_ascii_lowercase();
    if lowered.contains("eaddrinuse") || lowered.contains("address already in use") {
        return AppError::SessionManagerPortInUse;
    }
    if lowered.contains("cannot find module") || lowered.contains("module not found") {
        return AppError::SessionManagerFilesIncomplete;
    }
    AppError::SessionManagerStartFailed(tail_diagnostics(text, 1200))
}

fn tail_diagnostics(text: &str, max_chars: usize) -> String {
    let chars: Vec<char> = text.chars().collect();
    let start = chars.len().saturating_sub(max_chars);
    chars[start..].iter().collect()
}
```

- [ ] **Step 4: Add health check and startup**

Add these methods to `impl SessionManager`:

```rust
impl SessionManager {
    pub async fn is_healthy(&self) -> bool {
        reqwest::get("http://127.0.0.1:4318/api/health")
            .await
            .map(|response| response.status().is_success())
            .unwrap_or(false)
    }

    pub async fn ensure_running(&mut self) -> Result<bool, AppError> {
        if self.is_healthy().await {
            return Ok(false);
        }

        self.start_owned_process()?;
        self.wait_until_healthy(Duration::from_secs(10)).await?;
        Ok(true)
    }

    fn start_owned_process(&mut self) -> Result<(), AppError> {
        if !self.paths.node_exe.exists() {
            return Err(AppError::NodeRuntimeMissing);
        }
        if !self.paths.server_entry.exists() {
            return Err(AppError::SessionManagerFilesIncomplete);
        }

        let mut command = tokio::process::Command::new(&self.paths.node_exe);
        command.arg(&self.paths.server_entry);
        command.current_dir(&self.paths.app_dir);
        command.env("PORT", "4318");
        command.stdin(Stdio::null());
        command.stdout(Stdio::piped());
        command.stderr(Stdio::piped());

        let child = command
            .spawn()
            .map_err(|error| classify_startup_diagnostics(&error.to_string()))?;

        self.owned_child = Some(child);
        Ok(())
    }

    async fn wait_until_healthy(&self, timeout_duration: Duration) -> Result<(), AppError> {
        let start = std::time::Instant::now();
        while start.elapsed() < timeout_duration {
            if self.is_healthy().await {
                return Ok(());
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        Err(AppError::SessionManagerStartFailed(
            "Timed out while waiting for the session manager to start.".to_string(),
        ))
    }

    pub async fn open_in_browser(&mut self) -> Result<bool, AppError> {
        let started = self.ensure_running().await?;
        open::that("http://127.0.0.1:4318")
            .map_err(|error| AppError::SessionManagerStartFailed(error.to_string()))?;
        Ok(started)
    }

    pub async fn stop_owned_process(&mut self) {
        if let Some(child) = self.owned_child.as_mut() {
            let _ = child.kill().await;
        }
        self.owned_child = None;
    }
}
```

- [ ] **Step 5: Wire module into main**

Update `WindowsTray/src-tauri/src/main.rs`:

```rust
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod codex_home;
mod errors;
mod quota;
mod session_manager;

fn main() {
    tauri::Builder::default()
        .setup(|_app| Ok(()))
        .run(tauri::generate_context!())
        .expect("failed to run Codex Quota Viewer Windows tray app");
}
```

- [ ] **Step 6: Run tests**

Run:

```powershell
Set-Location WindowsTray\src-tauri
cargo test session_manager
```

Expected: diagnostic tests pass.

- [ ] **Step 7: Commit**

```powershell
git add WindowsTray/src-tauri/src/main.rs WindowsTray/src-tauri/src/session_manager.rs
git commit -m "feat: manage bundled session manager on windows"
```

---

### Task 5: Add Tray State And Menu Actions

**Files:**
- Create: `WindowsTray/src-tauri/src/app_state.rs`
- Create: `WindowsTray/src-tauri/src/tray.rs`
- Modify: `WindowsTray/src-tauri/src/main.rs`

- [ ] **Step 1: Create app state**

Create `WindowsTray/src-tauri/src/app_state.rs`:

```rust
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::Mutex;

use crate::errors::AppError;
use crate::quota::QuotaSnapshot;
use crate::session_manager::SessionManager;

#[derive(Debug, Clone)]
pub struct TraySnapshot {
    pub quota: Option<QuotaSnapshot>,
    pub is_refreshing: bool,
    pub last_error: Option<AppError>,
}

impl TraySnapshot {
    pub fn loading() -> Self {
        Self {
            quota: None,
            is_refreshing: true,
            last_error: None,
        }
    }
}

pub struct AppState {
    pub codex_home: PathBuf,
    pub tray_snapshot: Mutex<TraySnapshot>,
    pub session_manager: Mutex<SessionManager>,
    pub quota_timeout: Duration,
}

pub type SharedAppState = Arc<AppState>;
```

- [ ] **Step 2: Create tray menu builder**

Create `WindowsTray/src-tauri/src/tray.rs`:

```rust
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager};

use crate::app_state::TraySnapshot;

pub const MENU_REFRESH: &str = "refresh_quota";
pub const MENU_OPEN_SESSION_MANAGER: &str = "open_session_manager";
pub const MENU_OPEN_CODEX_FOLDER: &str = "open_codex_folder";
pub const MENU_QUIT: &str = "quit";

pub fn build_menu(app: &AppHandle, snapshot: &TraySnapshot) -> tauri::Result<Menu<tauri::Wry>> {
    let title = if snapshot.is_refreshing {
        "Refreshing quota...".to_string()
    } else if let Some(quota) = &snapshot.quota {
        quota
            .account
            .email
            .clone()
            .or_else(|| quota.account.id.clone())
            .unwrap_or_else(|| "Current Codex account".to_string())
    } else if let Some(error) = &snapshot.last_error {
        error.user_message().to_string()
    } else {
        "Codex Quota Viewer".to_string()
    };

    let title_i = MenuItem::with_id(app, "status_title", title, false, None::<&str>)?;
    let quota_i = MenuItem::with_id(app, "quota", quota_label(snapshot), false, None::<&str>)?;
    let refresh_i = MenuItem::with_id(app, MENU_REFRESH, "Refresh Quota", true, None::<&str>)?;
    let open_manager_i = MenuItem::with_id(app, MENU_OPEN_SESSION_MANAGER, "Open Session Manager", true, None::<&str>)?;
    let open_folder_i = MenuItem::with_id(app, MENU_OPEN_CODEX_FOLDER, "Open Codex Folder", true, None::<&str>)?;
    let quit_i = MenuItem::with_id(app, MENU_QUIT, "Quit", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;

    Menu::with_items(
        app,
        &[
            &title_i,
            &quota_i,
            &separator,
            &refresh_i,
            &open_manager_i,
            &open_folder_i,
            &separator,
            &quit_i,
        ],
    )
}

pub fn quota_label(snapshot: &TraySnapshot) -> String {
    if let Some(quota) = &snapshot.quota {
        let windows = quota
            .windows
            .iter()
            .map(|window| format!("{}: {:.0}%", window.label, window.remaining_percent))
            .collect::<Vec<_>>()
            .join("   ");
        if windows.is_empty() {
            "Quota unavailable".to_string()
        } else {
            windows
        }
    } else if let Some(error) = &snapshot.last_error {
        error.user_message().to_string()
    } else {
        "Quota loading".to_string()
    }
}

pub fn install_tray(app: &AppHandle, snapshot: &TraySnapshot) -> tauri::Result<()> {
    let menu = build_menu(app, snapshot)?;
    TrayIconBuilder::with_id("main")
        .tooltip("Codex Quota Viewer")
        .menu(&menu)
        .show_menu_on_left_click(true)
        .icon(app.default_window_icon().unwrap().clone())
        .build(app)?;
    Ok(())
}

pub fn update_tray_menu(app: &AppHandle, snapshot: &TraySnapshot) -> tauri::Result<()> {
    let menu = build_menu(app, snapshot)?;
    if let Some(tray) = app.tray_by_id("main") {
        tray.set_menu(Some(menu))?;
    }
    Ok(())
}
```

- [ ] **Step 3: Write tray formatting tests**

Append to `WindowsTray/src-tauri/src/tray.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    use crate::app_state::TraySnapshot;
    use crate::quota::{AccountSummary, QuotaSnapshot, QuotaWindow};

    #[test]
    fn formats_quota_windows() {
        let snapshot = TraySnapshot {
            quota: Some(QuotaSnapshot {
                account: AccountSummary {
                    id: Some("acct".to_string()),
                    email: Some("ada@example.com".to_string()),
                    account_type: "chatgpt".to_string(),
                },
                windows: vec![
                    QuotaWindow {
                        label: "5h".to_string(),
                        remaining_percent: 42.4,
                    },
                    QuotaWindow {
                        label: "1w".to_string(),
                        remaining_percent: 88.0,
                    },
                ],
                fetched_at: Utc::now(),
            }),
            is_refreshing: false,
            last_error: None,
        };

        assert_eq!(quota_label(&snapshot), "5h: 42%   1w: 88%");
    }
}
```

- [ ] **Step 4: Wire app state and menu events**

Replace `WindowsTray/src-tauri/src/main.rs` with:

```rust
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::Arc;
use std::time::Duration;

use tauri::{AppHandle, Manager};

mod app_state;
mod codex_home;
mod errors;
mod quota;
mod session_manager;
mod tray;

use app_state::{AppState, SharedAppState, TraySnapshot};
use codex_home::resolve_codex_home;
use quota::fetch_current_quota;
use session_manager::{SessionManager, SessionManagerPaths};
use tray::{MENU_OPEN_CODEX_FOLDER, MENU_OPEN_SESSION_MANAGER, MENU_QUIT, MENU_REFRESH};

fn main() {
    tauri::Builder::default()
        .setup(|app| {
            let app_handle = app.handle().clone();
            let codex_home = resolve_codex_home().unwrap_or_else(|_| std::path::PathBuf::from(r"C:\.codex-missing"));
            let resource_dir = app.path().resource_dir()?;
            let session_paths = SessionManagerPaths {
                node_exe: resource_dir.join("NodeRuntime").join("node.exe"),
                server_entry: resource_dir.join("SessionManager").join("dist").join("server").join("index.js"),
                app_dir: resource_dir.join("SessionManager"),
            };

            let state: SharedAppState = Arc::new(AppState {
                codex_home,
                tray_snapshot: tokio::sync::Mutex::new(TraySnapshot::loading()),
                session_manager: tokio::sync::Mutex::new(SessionManager::new(session_paths)),
                quota_timeout: Duration::from_secs(10),
            });

            app.manage(state.clone());
            tray::install_tray(&app_handle, &TraySnapshot::loading())?;
            spawn_refresh(app_handle.clone(), state);
            Ok(())
        })
        .on_menu_event(|app, event| {
            let id = event.id().as_ref();
            let state = app.state::<SharedAppState>().inner().clone();
            match id {
                MENU_REFRESH => spawn_refresh(app.clone(), state),
                MENU_OPEN_SESSION_MANAGER => spawn_open_session_manager(app.clone(), state),
                MENU_OPEN_CODEX_FOLDER => {
                    let codex_home = state.codex_home.clone();
                    let _ = open::that(codex_home);
                }
                MENU_QUIT => {
                    spawn_quit(app.clone(), state);
                }
                _ => {}
            }
        })
        .run(tauri::generate_context!())
        .expect("failed to run Codex Quota Viewer Windows tray app");
}

fn spawn_refresh(app: AppHandle, state: SharedAppState) {
    tauri::async_runtime::spawn(async move {
        {
            let mut snapshot = state.tray_snapshot.lock().await;
            snapshot.is_refreshing = true;
            let _ = tray::update_tray_menu(&app, &snapshot);
        }

        let result = fetch_current_quota(&state.codex_home, state.quota_timeout).await;
        let mut snapshot = state.tray_snapshot.lock().await;
        snapshot.is_refreshing = false;
        match result {
            Ok(quota) => {
                snapshot.quota = Some(quota);
                snapshot.last_error = None;
            }
            Err(error) => {
                snapshot.last_error = Some(error);
            }
        }
        let _ = tray::update_tray_menu(&app, &snapshot);
    });
}

fn spawn_open_session_manager(app: AppHandle, state: SharedAppState) {
    tauri::async_runtime::spawn(async move {
        let result = {
            let mut manager = state.session_manager.lock().await;
            manager.open_in_browser().await
        };
        if let Err(error) = result {
            let mut snapshot = state.tray_snapshot.lock().await;
            snapshot.last_error = Some(error);
            let _ = tray::update_tray_menu(&app, &snapshot);
        }
    });
}

fn spawn_quit(app: AppHandle, state: SharedAppState) {
    tauri::async_runtime::spawn(async move {
        {
            let mut manager = state.session_manager.lock().await;
            manager.stop_owned_process().await;
        }
        app.exit(0);
    });
}
```

- [ ] **Step 5: Run tests**

Run:

```powershell
Set-Location WindowsTray\src-tauri
cargo test
```

Expected: all non-GUI Rust tests pass.

- [ ] **Step 6: Commit**

```powershell
git add WindowsTray/src-tauri/src
git commit -m "feat: add windows tray menu actions"
```

---

### Task 6: Add Windows Build Scripts

**Files:**
- Create: `scripts/build-session-manager-windows.ps1`
- Create: `scripts/build-windows-tray.ps1`
- Modify: `.gitignore`

- [ ] **Step 1: Create Session Manager build script**

Create `scripts/build-session-manager-windows.ps1`:

```powershell
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$sessionManagerRoot = Join-Path $repoRoot "Vendor\CodexMM"
$targetRoot = Join-Path $repoRoot "WindowsTray\src-tauri\SessionManager"

Push-Location $sessionManagerRoot
try {
  corepack npm install
  corepack npm run build
}
finally {
  Pop-Location
}

if (Test-Path $targetRoot) {
  Remove-Item -LiteralPath $targetRoot -Recurse -Force
}

New-Item -ItemType Directory -Force $targetRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $sessionManagerRoot "dist") -Destination $targetRoot -Recurse
Copy-Item -LiteralPath (Join-Path $sessionManagerRoot "package.json") -Destination $targetRoot

Write-Host "Session Manager staged at $targetRoot"
```

- [ ] **Step 2: Create Windows tray build script**

Create `scripts/build-windows-tray.ps1`:

```powershell
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$windowsTrayRoot = Join-Path $repoRoot "WindowsTray"
$nodeRuntimeRoot = Join-Path $windowsTrayRoot "src-tauri\NodeRuntime"
$nodeExe = Join-Path $nodeRuntimeRoot "node.exe"

& (Join-Path $PSScriptRoot "build-session-manager-windows.ps1")

if (!(Test-Path $nodeExe)) {
  throw "Bundled Windows Node runtime is missing at $nodeExe. Place node.exe and its runtime files under WindowsTray\src-tauri\NodeRuntime before building."
}

Push-Location $windowsTrayRoot
try {
  corepack npm install
  corepack npm run build
}
finally {
  Pop-Location
}
```

- [ ] **Step 3: Extend ignore rules**

Confirm `.gitignore` contains:

```gitignore
WindowsTray/src-tauri/NodeRuntime/
WindowsTray/src-tauri/SessionManager/
```

- [ ] **Step 4: Run script syntax checks**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-session-manager-windows.ps1
```

Expected: builds and stages `Vendor/CodexMM/dist` into `WindowsTray/src-tauri/SessionManager`. If dependencies are missing, `corepack npm install` handles them.

- [ ] **Step 5: Commit**

```powershell
git add .gitignore scripts/build-session-manager-windows.ps1 scripts/build-windows-tray.ps1
git commit -m "build: add windows tray packaging scripts"
```

---

### Task 7: Document Windows MVP

**Files:**
- Modify: `README.md`
- Create: `docs/windows-mvp.md`

- [ ] **Step 1: Add dedicated Windows MVP documentation**

Create `docs/windows-mvp.md`:

```markdown
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
```

- [ ] **Step 2: Link the Windows doc from README**

Add this section to `README.md` after `## Build From Source`:

```markdown
## Windows MVP

This repository also contains a Windows tray MVP design and implementation path.
The Windows version is a Tauri-based system tray app that focuses on current
quota display, manual refresh, opening the bundled Session Manager, opening the
local Codex folder, and clean quit behavior.

See [docs/windows-mvp.md](docs/windows-mvp.md) for scope and build notes.
```

- [ ] **Step 3: Commit**

```powershell
git add README.md docs/windows-mvp.md
git commit -m "docs: describe windows tray mvp"
```

---

### Task 8: Verify MVP On Windows

**Files:**
- Modify only files needed to fix defects found during verification.

- [ ] **Step 1: Run Rust tests**

Run:

```powershell
Set-Location WindowsTray\src-tauri
cargo test
```

Expected: all tests pass.

- [ ] **Step 2: Run frontend checks**

Run:

```powershell
Set-Location WindowsTray
corepack npm run typecheck
```

Expected: TypeScript exits with code `0`.

- [ ] **Step 3: Build the Session Manager**

Run:

```powershell
Set-Location ..
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-session-manager-windows.ps1
```

Expected: `WindowsTray/src-tauri/SessionManager/dist/server/index.js` exists.

- [ ] **Step 4: Verify Node runtime staging**

Run:

```powershell
Test-Path WindowsTray\src-tauri\NodeRuntime\node.exe
```

Expected: `True`. If it is `False`, place the approved Windows Node runtime there and repeat this step.

- [ ] **Step 5: Build Windows tray package**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-windows-tray.ps1
```

Expected: Tauri produces Windows installer artifacts under `WindowsTray/src-tauri/target/release/bundle`.

- [ ] **Step 6: Manual tray verification**

Run the built app and verify:

```text
1. App starts without a visible primary window.
2. A tray icon appears in the Windows notification area.
3. Tray menu shows current account or a stable sign-in/error message.
4. Refresh Quota updates the quota rows without freezing the menu.
5. Open Session Manager starts or reuses http://127.0.0.1:4318 and opens the default browser.
6. Open Codex Folder opens the local Codex folder.
7. Quit exits the tray app.
8. Quit stops the owned Session Manager process.
9. Quit does not stop a Session Manager process that was already running before this app opened.
```

- [ ] **Step 7: Commit verification fixes**

If verification required code changes:

```powershell
git add WindowsTray scripts README.md docs
git commit -m "fix: complete windows tray mvp verification"
```

If verification required no code changes, record the commands and outcomes in the final handoff.

---

## Self-Review Notes

- Spec coverage: the plan covers independent Tauri app creation, tray menu, quota refresh, Session Manager sidecar, Node runtime expectation, build scripts, tests, and Windows documentation.
- Non-goals preserved: account vaults, safe switching, rollback, launch at login, and macOS Swift migration are not implemented in these tasks.
- Type consistency: `AppError`, `QuotaSnapshot`, `TraySnapshot`, `SessionManager`, and menu IDs are introduced before use.
- Test coverage: parser/path/diagnostic/unit-format tests are specified before implementation; GUI behavior is covered by manual Windows verification.
