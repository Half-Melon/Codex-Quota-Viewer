# Windows Settings Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Windows General settings layer that persists settings, opens from the tray, controls automatic refresh, localizes app UI, and supports launch at login.

**Architecture:** Keep the Windows app tray-first. Rust owns settings persistence, localization, launch-at-login side effects, timer scheduling, and Tauri commands; the TypeScript frontend is a small settings form that reflects Rust presentations and sends updates.

**Tech Stack:** Tauri 2, Rust 2021, Tokio, Serde JSON, Windows HKCU Run registry via `reg.exe`, TypeScript, Vite.

---

## File Structure

- Create: `WindowsTray/src-tauri/src/settings.rs` - settings enums, defaults, JSON store, interval conversion, settings presentation.
- Create: `WindowsTray/src-tauri/src/localization.rs` - language resolution and localized strings for tray and settings UI.
- Create: `WindowsTray/src-tauri/src/launch_at_login.rs` - launch-at-login trait, transaction helper, and Windows HKCU Run implementation.
- Create: `WindowsTray/src-tauri/src/scheduler.rs` - automatic quota refresh timer lifecycle.
- Modify: `WindowsTray/src-tauri/src/app_state.rs` - store settings, settings path, load issue, scheduler handle, refresh guard.
- Modify: `WindowsTray/src-tauri/src/errors.rs` - settings and launch-at-login user-facing errors.
- Modify: `WindowsTray/src-tauri/src/tray.rs` - localized labels and `Settings...` menu item.
- Modify: `WindowsTray/src-tauri/src/main.rs` - load settings, install scheduler, add settings window event and Tauri commands.
- Modify: `WindowsTray/src/main.ts` - render settings form and call Tauri commands.
- Create: `WindowsTray/src/styles.css` - compact native-feeling settings form styles.
- Modify: `WindowsTray/index.html` - load stylesheet.
- Modify: `WindowsTray/src-tauri/tauri.conf.json` - tune hidden settings window title and size.
- Modify: `docs/windows-mvp.md` - document new Windows settings capability.
- Modify: `README.md` - update Windows MVP scope from pure MVP to settings-capable tray app.

---

### Task 1: Add Settings Model And Store

**Files:**
- Create: `WindowsTray/src-tauri/src/settings.rs`
- Modify: `WindowsTray/src-tauri/src/errors.rs`
- Modify: `WindowsTray/src-tauri/src/main.rs`

- [ ] **Step 1: Add settings error variants**

In `WindowsTray/src-tauri/src/errors.rs`, extend `AppError`:

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
}
```

Update `user_message()` with:

```rust
Self::SettingsLoadFailed(_) => "Settings could not be loaded",
Self::SettingsSaveFailed(_) => "Settings could not be saved",
Self::LaunchAtLoginFailed(_) => "Launch at login could not be updated",
```

Update `diagnostics()` with:

```rust
Self::QuotaRefreshFailed(message)
| Self::SessionManagerStartFailed(message)
| Self::SettingsLoadFailed(message)
| Self::SettingsSaveFailed(message)
| Self::LaunchAtLoginFailed(message) => Some(message),
```

- [ ] **Step 2: Create failing settings tests**

Create `WindowsTray/src-tauri/src/settings.rs` with the public types and tests first:

```rust
use std::fs;
use std::path::Path;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::errors::AppError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RefreshIntervalPreset {
    Manual,
    OneMinute,
    FiveMinutes,
    FifteenMinutes,
}

impl RefreshIntervalPreset {
    pub fn interval(self) -> Option<Duration> {
        match self {
            Self::Manual => None,
            Self::OneMinute => Some(Duration::from_secs(60)),
            Self::FiveMinutes => Some(Duration::from_secs(300)),
            Self::FifteenMinutes => Some(Duration::from_secs(900)),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StatusItemStyle {
    Meter,
    Text,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AppLanguage {
    System,
    English,
    Chinese,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ResolvedAppLanguage {
    English,
    Chinese,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    pub refresh_interval_preset: RefreshIntervalPreset,
    pub launch_at_login_enabled: bool,
    pub status_item_style: StatusItemStyle,
    pub app_language: AppLanguage,
    pub last_resolved_language: Option<ResolvedAppLanguage>,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            refresh_interval_preset: RefreshIntervalPreset::FiveMinutes,
            launch_at_login_enabled: false,
            status_item_style: StatusItemStyle::Meter,
            app_language: AppLanguage::System,
            last_resolved_language: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingsLoadResult {
    pub settings: AppSettings,
    pub issue: Option<String>,
}

pub fn load_settings(_settings_path: &Path) -> SettingsLoadResult {
    SettingsLoadResult {
        settings: AppSettings::default(),
        issue: None,
    }
}

pub fn save_settings(_settings_path: &Path, _settings: &AppSettings) -> Result<(), AppError> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_file_uses_defaults_without_issue() {
        let temp = tempfile::tempdir().unwrap();
        let result = load_settings(&temp.path().join("settings.json"));

        assert_eq!(result.settings, AppSettings::default());
        assert_eq!(result.issue, None);
    }

    #[test]
    fn decodes_missing_fields_with_defaults() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("settings.json");
        fs::write(&path, r#"{"refreshIntervalPreset":"manual"}"#).unwrap();

        let result = load_settings(&path);

        assert_eq!(result.settings.refresh_interval_preset, RefreshIntervalPreset::Manual);
        assert_eq!(result.settings.launch_at_login_enabled, false);
        assert_eq!(result.settings.status_item_style, StatusItemStyle::Meter);
        assert_eq!(result.settings.app_language, AppLanguage::System);
        assert_eq!(result.issue, None);
    }

    #[test]
    fn corrupted_file_uses_defaults_with_issue() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("settings.json");
        fs::write(&path, "{not-json").unwrap();

        let result = load_settings(&path);

        assert_eq!(result.settings, AppSettings::default());
        assert!(result.issue.unwrap().contains("settings.json"));
    }

    #[test]
    fn saves_and_reloads_settings() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("nested").join("settings.json");
        let settings = AppSettings {
            refresh_interval_preset: RefreshIntervalPreset::OneMinute,
            launch_at_login_enabled: true,
            status_item_style: StatusItemStyle::Text,
            app_language: AppLanguage::Chinese,
            last_resolved_language: Some(ResolvedAppLanguage::Chinese),
        };

        save_settings(&path, &settings).unwrap();
        let result = load_settings(&path);

        assert_eq!(result.settings, settings);
        assert_eq!(result.issue, None);
    }

    #[test]
    fn converts_refresh_intervals() {
        assert_eq!(RefreshIntervalPreset::Manual.interval(), None);
        assert_eq!(RefreshIntervalPreset::OneMinute.interval(), Some(Duration::from_secs(60)));
        assert_eq!(RefreshIntervalPreset::FiveMinutes.interval(), Some(Duration::from_secs(300)));
        assert_eq!(RefreshIntervalPreset::FifteenMinutes.interval(), Some(Duration::from_secs(900)));
    }
}
```

- [ ] **Step 3: Run failing settings tests**

Run:

```powershell
Set-Location WindowsTray\src-tauri
cargo test settings
```

Expected: `missing_file_uses_defaults_without_issue` and `converts_refresh_intervals` pass; decode, corrupted-file, and save/reload tests fail because the initial implementation always uses defaults and does not write to disk.

- [ ] **Step 4: Implement settings load/save**

Replace the two initial functions in `settings.rs`:

```rust
pub fn load_settings(settings_path: &Path) -> SettingsLoadResult {
    if !settings_path.exists() {
        return SettingsLoadResult {
            settings: AppSettings::default(),
            issue: None,
        };
    }

    match fs::read_to_string(settings_path)
        .map_err(|error| error.to_string())
        .and_then(|text| serde_json::from_str::<AppSettings>(&text).map_err(|error| error.to_string()))
    {
        Ok(settings) => SettingsLoadResult {
            settings,
            issue: None,
        },
        Err(message) => SettingsLoadResult {
            settings: AppSettings::default(),
            issue: Some(format!(
                "Settings file is corrupted: {} ({message})",
                settings_path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or("settings.json")
            )),
        },
    }
}

pub fn save_settings(settings_path: &Path, settings: &AppSettings) -> Result<(), AppError> {
    if let Some(parent) = settings_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| AppError::SettingsSaveFailed(error.to_string()))?;
    }

    let data = serde_json::to_vec_pretty(settings)
        .map_err(|error| AppError::SettingsSaveFailed(error.to_string()))?;
    fs::write(settings_path, data)
        .map_err(|error| AppError::SettingsSaveFailed(error.to_string()))
}
```

- [ ] **Step 5: Wire the module**

In `WindowsTray/src-tauri/src/main.rs`, add:

```rust
mod settings;
```

- [ ] **Step 6: Run settings tests**

Run:

```powershell
Set-Location WindowsTray\src-tauri
cargo test settings
```

Expected: all `settings` tests pass.

- [ ] **Step 7: Commit**

```powershell
git add WindowsTray/src-tauri/src/errors.rs WindowsTray/src-tauri/src/settings.rs WindowsTray/src-tauri/src/main.rs
git commit -m "feat: add windows settings store"
```

---

### Task 2: Add Localization And Settings Presentation

**Files:**
- Create: `WindowsTray/src-tauri/src/localization.rs`
- Modify: `WindowsTray/src-tauri/src/settings.rs`
- Modify: `WindowsTray/src-tauri/src/main.rs`

- [ ] **Step 1: Create failing localization tests**

Create `WindowsTray/src-tauri/src/localization.rs`:

```rust
use crate::errors::AppError;
use crate::settings::{AppLanguage, ResolvedAppLanguage};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalizedText {
    pub en: &'static str,
    pub zh: &'static str,
}

impl LocalizedText {
    pub const fn new(en: &'static str, zh: &'static str) -> Self {
        Self { en, zh }
    }
}

pub fn resolve_language(
    configured: AppLanguage,
    _system_languages: &[String],
) -> ResolvedAppLanguage {
    match configured {
        AppLanguage::Chinese => ResolvedAppLanguage::Chinese,
        _ => ResolvedAppLanguage::English,
    }
}

pub fn localize(_language: ResolvedAppLanguage, text: LocalizedText) -> String {
    text.en.to_string()
}

pub fn app_error_message(_language: ResolvedAppLanguage, error: &AppError) -> String {
    error.user_message().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_language_wins() {
        assert_eq!(
            resolve_language(AppLanguage::Chinese, &[String::from("en-US")]),
            ResolvedAppLanguage::Chinese
        );
        assert_eq!(
            resolve_language(AppLanguage::English, &[String::from("zh-Hans")]),
            ResolvedAppLanguage::English
        );
    }

    #[test]
    fn system_language_detects_chinese_prefix() {
        assert_eq!(
            resolve_language(AppLanguage::System, &[String::from("zh-Hans-CN")]),
            ResolvedAppLanguage::Chinese
        );
    }

    #[test]
    fn system_language_falls_back_to_english() {
        assert_eq!(
            resolve_language(AppLanguage::System, &[String::from("fr-FR")]),
            ResolvedAppLanguage::English
        );
    }

    #[test]
    fn localizes_text() {
        let text = LocalizedText::new("Settings", "设置");
        assert_eq!(localize(ResolvedAppLanguage::English, text.clone()), "Settings");
        assert_eq!(localize(ResolvedAppLanguage::Chinese, text), "设置");
    }
}
```

- [ ] **Step 2: Run failing localization tests**

Run:

```powershell
Set-Location WindowsTray\src-tauri
cargo test localization
```

Expected: explicit English/Chinese language tests pass; system Chinese detection and Chinese text localization tests fail.

- [ ] **Step 3: Implement localization**

Replace the three functions in `localization.rs`:

```rust
pub fn resolve_language(
    configured: AppLanguage,
    system_languages: &[String],
) -> ResolvedAppLanguage {
    match configured {
        AppLanguage::English => ResolvedAppLanguage::English,
        AppLanguage::Chinese => ResolvedAppLanguage::Chinese,
        AppLanguage::System => {
            if system_languages
                .iter()
                .any(|language| language.to_ascii_lowercase().starts_with("zh"))
            {
                ResolvedAppLanguage::Chinese
            } else {
                ResolvedAppLanguage::English
            }
        }
    }
}

pub fn localize(language: ResolvedAppLanguage, text: LocalizedText) -> String {
    match language {
        ResolvedAppLanguage::English => text.en.to_string(),
        ResolvedAppLanguage::Chinese => text.zh.to_string(),
    }
}

pub fn app_error_message(language: ResolvedAppLanguage, error: &AppError) -> String {
    let text = match error {
        AppError::CodexFolderNotFound => LocalizedText::new("Codex folder not found", "未找到 Codex 文件夹"),
        AppError::SignInRequired => LocalizedText::new("Sign in required", "需要登录"),
        AppError::QuotaTimeout => LocalizedText::new("Timed out while reading quota", "读取额度超时"),
        AppError::QuotaRefreshFailed(_) => LocalizedText::new("Quota refresh failed", "额度刷新失败"),
        AppError::SessionManagerPortInUse => LocalizedText::new(
            "Session Manager port 4318 is already in use",
            "Session Manager 端口 4318 已被占用",
        ),
        AppError::SessionManagerFilesIncomplete => LocalizedText::new(
            "Bundled Session Manager files are incomplete",
            "内置 Session Manager 文件不完整",
        ),
        AppError::NodeRuntimeMissing => LocalizedText::new(
            "Bundled Node runtime is missing",
            "缺少内置 Node 运行时",
        ),
        AppError::SessionManagerStartFailed(_) => LocalizedText::new(
            "Session Manager could not start",
            "Session Manager 无法启动",
        ),
        AppError::SettingsLoadFailed(_) => LocalizedText::new(
            "Settings could not be loaded",
            "设置无法加载",
        ),
        AppError::SettingsSaveFailed(_) => LocalizedText::new(
            "Settings could not be saved",
            "设置无法保存",
        ),
        AppError::LaunchAtLoginFailed(_) => LocalizedText::new(
            "Launch at login could not be updated",
            "登录时启动无法更新",
        ),
    };
    localize(language, text)
}
```

- [ ] **Step 4: Add settings presentation types**

Append to `settings.rs`:

```rust
use crate::localization::{localize, LocalizedText};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SelectOption {
    pub value: String,
    pub label: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsLabels {
    pub title: String,
    pub refresh_interval: String,
    pub language: String,
    pub tray_style: String,
    pub launch_at_login: String,
    pub saved: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsPresentation {
    pub settings: AppSettings,
    pub resolved_language: ResolvedAppLanguage,
    pub labels: SettingsLabels,
    pub refresh_interval_options: Vec<SelectOption>,
    pub language_options: Vec<SelectOption>,
    pub tray_style_options: Vec<SelectOption>,
    pub message: Option<String>,
}

pub fn settings_presentation(
    settings: AppSettings,
    resolved_language: ResolvedAppLanguage,
    message: Option<String>,
) -> SettingsPresentation {
    SettingsPresentation {
        settings,
        resolved_language,
        labels: SettingsLabels {
            title: localize(resolved_language, LocalizedText::new("Settings", "设置")),
            refresh_interval: localize(resolved_language, LocalizedText::new("Refresh interval", "刷新频率")),
            language: localize(resolved_language, LocalizedText::new("Language", "语言")),
            tray_style: localize(resolved_language, LocalizedText::new("Tray style", "托盘样式")),
            launch_at_login: localize(resolved_language, LocalizedText::new("Launch at login", "登录时启动")),
            saved: localize(resolved_language, LocalizedText::new("Saved", "已保存")),
        },
        refresh_interval_options: vec![
            SelectOption { value: "manual".into(), label: localize(resolved_language, LocalizedText::new("Manual", "手动")) },
            SelectOption { value: "oneMinute".into(), label: localize(resolved_language, LocalizedText::new("1 minute", "1 分钟")) },
            SelectOption { value: "fiveMinutes".into(), label: localize(resolved_language, LocalizedText::new("5 minutes", "5 分钟")) },
            SelectOption { value: "fifteenMinutes".into(), label: localize(resolved_language, LocalizedText::new("15 minutes", "15 分钟")) },
        ],
        language_options: vec![
            SelectOption { value: "system".into(), label: localize(resolved_language, LocalizedText::new("Follow System", "跟随系统")) },
            SelectOption { value: "english".into(), label: localize(resolved_language, LocalizedText::new("English", "英文")) },
            SelectOption { value: "chinese".into(), label: localize(resolved_language, LocalizedText::new("Chinese", "中文")) },
        ],
        tray_style_options: vec![
            SelectOption { value: "meter".into(), label: localize(resolved_language, LocalizedText::new("Meter", "仪表")) },
            SelectOption { value: "text".into(), label: localize(resolved_language, LocalizedText::new("Text", "文字")) },
        ],
        message,
    }
}
```

- [ ] **Step 5: Wire the localization module**

In `main.rs`, add:

```rust
mod localization;
```

- [ ] **Step 6: Run tests**

Run:

```powershell
Set-Location WindowsTray\src-tauri
cargo test localization settings
```

Expected: all localization and settings tests pass.

- [ ] **Step 7: Commit**

```powershell
git add WindowsTray/src-tauri/src/localization.rs WindowsTray/src-tauri/src/settings.rs WindowsTray/src-tauri/src/main.rs
git commit -m "feat: localize windows settings"
```

---

### Task 3: Add Launch-At-Login Transaction Support

**Files:**
- Create: `WindowsTray/src-tauri/src/launch_at_login.rs`
- Modify: `WindowsTray/src-tauri/src/main.rs`

- [ ] **Step 1: Create failing transaction tests**

Create `WindowsTray/src-tauri/src/launch_at_login.rs`:

```rust
use std::process::Command;

use crate::errors::AppError;
use crate::settings::AppSettings;

pub trait LaunchAtLoginManager {
    fn sync(&mut self, enabled: bool) -> Result<(), AppError>;
}

pub fn apply_settings_transaction<M, S>(
    previous: AppSettings,
    updated: AppSettings,
    manager: &mut M,
    save_settings: S,
) -> Result<AppSettings, AppError>
where
    M: LaunchAtLoginManager,
    S: FnOnce(&AppSettings) -> Result<(), AppError>,
{
    let _ = previous;
    let _ = manager;
    let _ = save_settings;
    Ok(updated)
}

pub struct WindowsRunKeyLaunchAtLogin {
    app_name: String,
    exe_path: String,
}

impl WindowsRunKeyLaunchAtLogin {
    pub fn new(app_name: impl Into<String>, exe_path: impl Into<String>) -> Self {
        Self {
            app_name: app_name.into(),
            exe_path: exe_path.into(),
        }
    }
}

impl LaunchAtLoginManager for WindowsRunKeyLaunchAtLogin {
    fn sync(&mut self, enabled: bool) -> Result<(), AppError> {
        let status = if enabled {
            Command::new("reg")
                .args([
                    "add",
                    r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run",
                    "/v",
                    &self.app_name,
                    "/t",
                    "REG_SZ",
                    "/d",
                    &self.exe_path,
                    "/f",
                ])
                .status()
        } else {
            Command::new("reg")
                .args([
                    "delete",
                    r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run",
                    "/v",
                    &self.app_name,
                    "/f",
                ])
                .status()
        }
        .map_err(|error| AppError::LaunchAtLoginFailed(error.to_string()))?;

        if status.success() {
            Ok(())
        } else {
            Err(AppError::LaunchAtLoginFailed(format!(
                "reg.exe exited with status {status}"
            )))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct FakeLaunchManager {
        calls: Vec<bool>,
        fail_on: Option<bool>,
    }

    impl LaunchAtLoginManager for FakeLaunchManager {
        fn sync(&mut self, enabled: bool) -> Result<(), AppError> {
            self.calls.push(enabled);
            if self.fail_on == Some(enabled) {
                return Err(AppError::LaunchAtLoginFailed("boom".into()));
            }
            Ok(())
        }
    }

    #[test]
    fn saves_without_side_effect_when_launch_setting_unchanged() {
        let previous = AppSettings::default();
        let updated = AppSettings {
            app_language: crate::settings::AppLanguage::Chinese,
            ..previous.clone()
        };
        let mut manager = FakeLaunchManager::default();

        let result = apply_settings_transaction(previous, updated.clone(), &mut manager, |_| Ok(())).unwrap();

        assert_eq!(result, updated);
        assert!(manager.calls.is_empty());
    }

    #[test]
    fn syncs_launch_before_saving_when_changed() {
        let previous = AppSettings::default();
        let updated = AppSettings {
            launch_at_login_enabled: true,
            ..previous.clone()
        };
        let mut manager = FakeLaunchManager::default();

        let result = apply_settings_transaction(previous, updated.clone(), &mut manager, |_| Ok(())).unwrap();

        assert_eq!(result, updated);
        assert_eq!(manager.calls, vec![true]);
    }

    #[test]
    fn does_not_save_when_launch_sync_fails() {
        let previous = AppSettings::default();
        let updated = AppSettings {
            launch_at_login_enabled: true,
            ..previous.clone()
        };
        let mut manager = FakeLaunchManager {
            fail_on: Some(true),
            ..FakeLaunchManager::default()
        };
        let mut saved = false;

        let error = apply_settings_transaction(previous, updated, &mut manager, |_| {
            saved = true;
            Ok(())
        })
        .unwrap_err();

        assert_eq!(error.user_message(), "Launch at login could not be updated");
        assert!(!saved);
        assert_eq!(manager.calls, vec![true]);
    }

    #[test]
    fn restores_previous_launch_state_when_save_fails() {
        let previous = AppSettings::default();
        let updated = AppSettings {
            launch_at_login_enabled: true,
            ..previous.clone()
        };
        let mut manager = FakeLaunchManager::default();

        let error = apply_settings_transaction(previous, updated, &mut manager, |_| {
            Err(AppError::SettingsSaveFailed("disk".into()))
        })
        .unwrap_err();

        assert_eq!(error.user_message(), "Settings could not be saved");
        assert_eq!(manager.calls, vec![true, false]);
    }
}
```

- [ ] **Step 2: Run failing launch tests**

Run:

```powershell
Set-Location WindowsTray\src-tauri
cargo test launch_at_login
```

Expected: the unchanged-setting test passes; launch side-effect and rollback tests fail because the initial implementation returns `updated` without syncing or saving.

- [ ] **Step 3: Implement settings transaction**

Replace `apply_settings_transaction`:

```rust
pub fn apply_settings_transaction<M, S>(
    previous: AppSettings,
    updated: AppSettings,
    manager: &mut M,
    save_settings: S,
) -> Result<AppSettings, AppError>
where
    M: LaunchAtLoginManager,
    S: FnOnce(&AppSettings) -> Result<(), AppError>,
{
    let launch_changed =
        previous.launch_at_login_enabled != updated.launch_at_login_enabled;

    if launch_changed {
        manager.sync(updated.launch_at_login_enabled)?;
    }

    match save_settings(&updated) {
        Ok(()) => Ok(updated),
        Err(error) => {
            if launch_changed {
                let _ = manager.sync(previous.launch_at_login_enabled);
            }
            Err(error)
        }
    }
}
```

- [ ] **Step 4: Wire the module**

In `main.rs`, add:

```rust
mod launch_at_login;
```

- [ ] **Step 5: Run launch tests**

Run:

```powershell
Set-Location WindowsTray\src-tauri
cargo test launch_at_login
```

Expected: all launch-at-login transaction tests pass.

- [ ] **Step 6: Commit**

```powershell
git add WindowsTray/src-tauri/src/launch_at_login.rs WindowsTray/src-tauri/src/main.rs
git commit -m "feat: add windows launch settings transaction"
```

---

### Task 4: Add Refresh Scheduler And Shared Settings State

**Files:**
- Create: `WindowsTray/src-tauri/src/scheduler.rs`
- Modify: `WindowsTray/src-tauri/src/app_state.rs`
- Modify: `WindowsTray/src-tauri/src/main.rs`

- [ ] **Step 1: Create scheduler helper tests**

Create `WindowsTray/src-tauri/src/scheduler.rs`:

```rust
use tauri::async_runtime::JoinHandle;

use crate::settings::RefreshIntervalPreset;

#[derive(Default)]
pub struct RefreshScheduler {
    handle: Option<JoinHandle<()>>,
}

impl RefreshScheduler {
    pub fn new() -> Self {
        Self { handle: None }
    }

    pub fn is_running(&self) -> bool {
        self.handle.is_some()
    }

    pub fn stop(&mut self) {
        if let Some(handle) = self.handle.take() {
            handle.abort();
        }
    }

    pub fn replace_with(&mut self, handle: Option<JoinHandle<()>>) {
        self.stop();
        self.handle = handle;
    }
}

pub fn should_schedule_refresh(preset: RefreshIntervalPreset) -> bool {
    preset.interval().is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manual_does_not_schedule() {
        assert!(!should_schedule_refresh(RefreshIntervalPreset::Manual));
    }

    #[test]
    fn timed_presets_schedule() {
        assert!(should_schedule_refresh(RefreshIntervalPreset::OneMinute));
        assert!(should_schedule_refresh(RefreshIntervalPreset::FiveMinutes));
        assert!(should_schedule_refresh(RefreshIntervalPreset::FifteenMinutes));
    }
}
```

- [ ] **Step 2: Run scheduler tests**

Run:

```powershell
Set-Location WindowsTray\src-tauri
cargo test scheduler
```

Expected: scheduler tests pass.

- [ ] **Step 3: Extend app state**

In `app_state.rs`, add imports:

```rust
use crate::scheduler::RefreshScheduler;
use crate::settings::AppSettings;
```

Extend `TraySnapshot`:

```rust
pub struct TraySnapshot {
    pub quota: Option<QuotaSnapshot>,
    pub is_refreshing: bool,
    pub last_error: Option<AppError>,
}
```

Extend `AppState`:

```rust
pub struct AppState {
    pub codex_home: PathBuf,
    pub settings_path: PathBuf,
    pub settings: Mutex<AppSettings>,
    pub settings_load_issue: Mutex<Option<String>>,
    pub tray_snapshot: Mutex<TraySnapshot>,
    pub session_manager: Mutex<SessionManager>,
    pub refresh_scheduler: Mutex<RefreshScheduler>,
    pub refresh_in_progress: Mutex<bool>,
    pub quota_timeout: Duration,
}
```

- [ ] **Step 4: Add refresh scheduler functions**

In `main.rs`, add imports:

```rust
use settings::{load_settings, AppSettings};
use scheduler::RefreshScheduler;
```

Add helper functions below `handle_menu_event`:

```rust
fn start_refresh_scheduler(app: AppHandle, state: SharedAppState, settings: AppSettings) {
    tauri::async_runtime::spawn(async move {
        let interval = settings.refresh_interval_preset.interval();
        let handle = interval.map(|duration| {
            let app = app.clone();
            let state = state.clone();
            tauri::async_runtime::spawn(async move {
                let mut ticker = tokio::time::interval(duration);
                loop {
                    ticker.tick().await;
                    ticker.tick().await;
                    spawn_refresh(app.clone(), state.clone());
                }
            })
        });

        let mut scheduler = state.refresh_scheduler.lock().await;
        scheduler.replace_with(handle);
    });
}

fn restart_refresh_scheduler(app: AppHandle, state: SharedAppState, settings: AppSettings) {
    start_refresh_scheduler(app, state, settings);
}
```

In `spawn_refresh`, add a guard at the top of the async task:

```rust
{
    let mut in_progress = state.refresh_in_progress.lock().await;
    if *in_progress {
        return;
    }
    *in_progress = true;
}
```

Before the async task exits after `update_tray_menu`, add:

```rust
{
    let mut in_progress = state.refresh_in_progress.lock().await;
    *in_progress = false;
}
```

- [ ] **Step 5: Load settings during setup**

In `main.rs` setup, before constructing `AppState`, add:

```rust
let settings_path = app_data_dir.join("settings.json");
let settings_result = load_settings(&settings_path);
let settings = settings_result.settings.clone();
```

Update the `AppState` construction:

```rust
let state: SharedAppState = Arc::new(AppState {
    codex_home,
    settings_path,
    settings: tauri::async_runtime::Mutex::new(settings.clone()),
    settings_load_issue: tauri::async_runtime::Mutex::new(settings_result.issue),
    tray_snapshot: tauri::async_runtime::Mutex::new(TraySnapshot::loading()),
    session_manager: tauri::async_runtime::Mutex::new(SessionManager::new(session_paths)),
    refresh_scheduler: tauri::async_runtime::Mutex::new(RefreshScheduler::new()),
    refresh_in_progress: tauri::async_runtime::Mutex::new(false),
    quota_timeout: Duration::from_secs(10),
});
```

After the initial `spawn_refresh(app_handle.clone(), state.clone());`, add:

```rust
start_refresh_scheduler(app_handle, state, settings);
```

- [ ] **Step 6: Run Rust tests**

Run:

```powershell
Set-Location WindowsTray\src-tauri
cargo test settings scheduler tray
```

Expected: tests pass.

- [ ] **Step 7: Commit**

```powershell
git add WindowsTray/src-tauri/src/app_state.rs WindowsTray/src-tauri/src/main.rs WindowsTray/src-tauri/src/scheduler.rs
git commit -m "feat: schedule windows quota refresh"
```

---

### Task 5: Localize Tray Menu And Add Settings Window Event

**Files:**
- Modify: `WindowsTray/src-tauri/src/tray.rs`
- Modify: `WindowsTray/src-tauri/src/main.rs`

- [ ] **Step 1: Update tray constants and signatures**

In `tray.rs`, add:

```rust
use crate::localization::{app_error_message, localize, LocalizedText};
use crate::settings::ResolvedAppLanguage;

pub const MENU_SETTINGS: &str = "settings";
```

Change signatures:

```rust
pub fn build_menu(
    app: &AppHandle,
    snapshot: &TraySnapshot,
    language: ResolvedAppLanguage,
) -> tauri::Result<Menu<tauri::Wry>>

pub fn quota_label(snapshot: &TraySnapshot, language: ResolvedAppLanguage) -> String

pub fn install_tray(
    app: &AppHandle,
    snapshot: &TraySnapshot,
    language: ResolvedAppLanguage,
) -> tauri::Result<()>

pub fn update_tray_menu(
    app: &AppHandle,
    snapshot: &TraySnapshot,
    language: ResolvedAppLanguage,
) -> tauri::Result<()>
```

- [ ] **Step 2: Localize tray labels**

In `build_menu`, replace literal labels:

```rust
let title = if snapshot.is_refreshing {
    localize(language, LocalizedText::new("Refreshing quota...", "正在刷新额度..."))
} else if let Some(quota) = &snapshot.quota {
    quota
        .account
        .email
        .clone()
        .or_else(|| quota.account.id.clone())
        .unwrap_or_else(|| localize(language, LocalizedText::new("Current Codex account", "当前 Codex 账号")))
} else if let Some(error) = &snapshot.last_error {
    app_error_message(language, error)
} else {
    "Codex Quota Viewer".to_string()
};

let refresh_item = MenuItem::with_id(
    app,
    MENU_REFRESH,
    localize(language, LocalizedText::new("Refresh Quota", "刷新额度")),
    true,
    None::<&str>,
)?;
let settings_item = MenuItem::with_id(
    app,
    MENU_SETTINGS,
    localize(language, LocalizedText::new("Settings...", "设置...")),
    true,
    None::<&str>,
)?;
let open_manager_item = MenuItem::with_id(
    app,
    MENU_OPEN_SESSION_MANAGER,
    localize(language, LocalizedText::new("Open Session Manager", "打开 Session Manager")),
    true,
    None::<&str>,
)?;
let open_folder_item = MenuItem::with_id(
    app,
    MENU_OPEN_CODEX_FOLDER,
    localize(language, LocalizedText::new("Open Codex Folder", "打开 Codex 文件夹")),
    true,
    None::<&str>,
)?;
let quit_item = MenuItem::with_id(
    app,
    MENU_QUIT,
    localize(language, LocalizedText::new("Quit", "退出")),
    true,
    None::<&str>,
)?;
```

Include `&settings_item` between refresh and open manager in `Menu::with_items`.

In `quota_label`, replace error and loading literals:

```rust
if windows.is_empty() {
    localize(language, LocalizedText::new("Quota unavailable", "额度不可用"))
} else {
    windows
}
```

```rust
app_error_message(language, error)
```

```rust
localize(language, LocalizedText::new("Quota loading", "正在读取额度"))
```

- [ ] **Step 3: Add async tray update helper in main**

In `main.rs`, import:

```rust
use localization::resolve_language;
use tray::{MENU_OPEN_CODEX_FOLDER, MENU_OPEN_SESSION_MANAGER, MENU_QUIT, MENU_REFRESH, MENU_SETTINGS};
```

Add:

```rust
async fn current_resolved_language(state: &SharedAppState) -> settings::ResolvedAppLanguage {
    let settings = state.settings.lock().await;
    resolve_language(settings.app_language, &system_language_hints())
}

fn system_language_hints() -> Vec<String> {
    std::env::var("LANG")
        .ok()
        .into_iter()
        .chain(std::env::var("LANGUAGE").ok())
        .collect()
}

async fn update_tray_from_state(app: &AppHandle, state: &SharedAppState) {
    let snapshot = state.tray_snapshot.lock().await.clone();
    let language = current_resolved_language(state).await;
    let _ = tray::update_tray_menu(app, &snapshot, language);
}
```

Replace existing `tray::update_tray_menu(&app, &snapshot)` calls with:

```rust
let language = current_resolved_language(&state).await;
let _ = tray::update_tray_menu(&app, &snapshot, language);
```

In setup, resolve language before installing the tray:

```rust
let resolved_language = resolve_language(settings.app_language, &system_language_hints());
tray::install_tray(&app_handle, &TraySnapshot::loading(), resolved_language)?;
```

- [ ] **Step 4: Show settings window from tray**

In `handle_menu_event`, add:

```rust
MENU_SETTINGS => show_settings_window(app),
```

Add:

```rust
fn show_settings_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
    }
}
```

- [ ] **Step 5: Update tray tests**

In `tray.rs` tests, update the assertion call:

```rust
assert_eq!(
    quota_label(&snapshot, ResolvedAppLanguage::English),
    "5h: 42%   1w: 88%"
);
```

Add a loading localization test:

```rust
#[test]
fn localizes_loading_label() {
    let snapshot = TraySnapshot::loading();

    assert_eq!(
        quota_label(&snapshot, ResolvedAppLanguage::Chinese),
        "正在读取额度"
    );
}
```

- [ ] **Step 6: Run tests**

Run:

```powershell
Set-Location WindowsTray\src-tauri
cargo test tray localization
```

Expected: tray and localization tests pass.

- [ ] **Step 7: Commit**

```powershell
git add WindowsTray/src-tauri/src/tray.rs WindowsTray/src-tauri/src/main.rs
git commit -m "feat: add localized windows settings tray entry"
```

---

### Task 6: Add Tauri Settings Commands

**Files:**
- Modify: `WindowsTray/src-tauri/src/main.rs`
- Modify: `WindowsTray/src-tauri/src/settings.rs`

- [ ] **Step 1: Add command tests for presentation builder**

Append to `settings.rs` tests:

```rust
#[test]
fn builds_chinese_settings_presentation() {
    let presentation = settings_presentation(
        AppSettings {
            app_language: AppLanguage::Chinese,
            last_resolved_language: Some(ResolvedAppLanguage::Chinese),
            ..AppSettings::default()
        },
        ResolvedAppLanguage::Chinese,
        Some("已保存".to_string()),
    );

    assert_eq!(presentation.labels.title, "设置");
    assert_eq!(presentation.language_options[2].value, "chinese");
    assert_eq!(presentation.message.as_deref(), Some("已保存"));
}
```

- [ ] **Step 2: Run presentation test**

Run:

```powershell
Set-Location WindowsTray\src-tauri
cargo test builds_chinese_settings_presentation
```

Expected: test passes if Task 2 presentation code is present.

- [ ] **Step 3: Add Tauri commands**

In `main.rs`, add imports:

```rust
use launch_at_login::{apply_settings_transaction, WindowsRunKeyLaunchAtLogin};
use settings::{save_settings, settings_presentation, SettingsPresentation};
```

Add commands above `main()`:

```rust
#[tauri::command]
async fn get_settings(state: tauri::State<'_, SharedAppState>) -> Result<SettingsPresentation, String> {
    let settings = state.settings.lock().await.clone();
    let issue = state.settings_load_issue.lock().await.clone();
    let resolved = resolve_language(settings.app_language, &system_language_hints());
    Ok(settings_presentation(settings, resolved, issue))
}

#[tauri::command]
async fn update_settings(
    app: AppHandle,
    state: tauri::State<'_, SharedAppState>,
    updated: AppSettings,
) -> Result<SettingsPresentation, String> {
    let previous = state.settings.lock().await.clone();
    let settings_path = state.settings_path.clone();
    let exe_path = std::env::current_exe()
        .map_err(|error| format!("Could not resolve current executable: {error}"))?
        .to_string_lossy()
        .to_string();
    let mut launch_manager = WindowsRunKeyLaunchAtLogin::new("Codex Quota Viewer", exe_path);

    let saved = apply_settings_transaction(
        previous,
        updated,
        &mut launch_manager,
        |settings| save_settings(&settings_path, settings),
    )
    .map_err(|error| error.user_message().to_string())?;

    {
        let mut current = state.settings.lock().await;
        *current = saved.clone();
    }
    {
        let mut issue = state.settings_load_issue.lock().await;
        *issue = None;
    }

    restart_refresh_scheduler(app.clone(), state.inner().clone(), saved.clone());
    update_tray_from_state(&app, state.inner()).await;

    let resolved = resolve_language(saved.app_language, &system_language_hints());
    Ok(settings_presentation(
        saved,
        resolved,
        Some(localization::localize(
            resolved,
            localization::LocalizedText::new("Saved", "已保存"),
        )),
    ))
}
```

Add the invoke handler to the builder:

```rust
.invoke_handler(tauri::generate_handler![get_settings, update_settings])
```

Place it before `.setup(...)`.

- [ ] **Step 4: Run Rust tests**

Run:

```powershell
Set-Location WindowsTray\src-tauri
cargo test settings launch_at_login localization tray scheduler
```

Expected: tests pass.

- [ ] **Step 5: Commit**

```powershell
git add WindowsTray/src-tauri/src/main.rs WindowsTray/src-tauri/src/settings.rs
git commit -m "feat: expose windows settings commands"
```

---

### Task 7: Build The Settings Window UI

**Files:**
- Modify: `WindowsTray/src/main.ts`
- Create: `WindowsTray/src/styles.css`
- Modify: `WindowsTray/index.html`
- Modify: `WindowsTray/src-tauri/tauri.conf.json`

- [ ] **Step 1: Update HTML and window config**

In `WindowsTray/index.html`, add the stylesheet:

```html
<link rel="stylesheet" href="/src/styles.css" />
```

In `tauri.conf.json`, update the window:

```json
{
  "title": "Codex Quota Viewer Settings",
  "width": 520,
  "height": 340,
  "visible": false,
  "resizable": false
}
```

- [ ] **Step 2: Replace frontend TypeScript**

Replace `WindowsTray/src/main.ts`:

```ts
import { invoke } from "@tauri-apps/api/core";

type RefreshIntervalPreset = "manual" | "oneMinute" | "fiveMinutes" | "fifteenMinutes";
type StatusItemStyle = "meter" | "text";
type AppLanguage = "system" | "english" | "chinese";
type ResolvedAppLanguage = "english" | "chinese";

type AppSettings = {
  refreshIntervalPreset: RefreshIntervalPreset;
  launchAtLoginEnabled: boolean;
  statusItemStyle: StatusItemStyle;
  appLanguage: AppLanguage;
  lastResolvedLanguage: ResolvedAppLanguage | null;
};

type SelectOption = {
  value: string;
  label: string;
};

type SettingsPresentation = {
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

const app = document.querySelector<HTMLDivElement>("#app");

if (!app) {
  throw new Error("Missing #app element");
}

let presentation: SettingsPresentation | null = null;

function optionMarkup(options: SelectOption[], selected: string): string {
  return options
    .map((option) => {
      const isSelected = option.value === selected ? " selected" : "";
      return `<option value="${option.value}"${isSelected}>${option.label}</option>`;
    })
    .join("");
}

function render(next: SettingsPresentation): void {
  presentation = next;
  document.title = next.labels.title;
  app.innerHTML = `
    <main class="settings-shell">
      <header class="settings-header">
        <h1>${next.labels.title}</h1>
      </header>
      <section class="settings-form" aria-label="${next.labels.title}">
        <label class="settings-row">
          <span>${next.labels.refreshInterval}</span>
          <select id="refreshIntervalPreset">
            ${optionMarkup(next.refreshIntervalOptions, next.settings.refreshIntervalPreset)}
          </select>
        </label>
        <label class="settings-row">
          <span>${next.labels.language}</span>
          <select id="appLanguage">
            ${optionMarkup(next.languageOptions, next.settings.appLanguage)}
          </select>
        </label>
        <label class="settings-row">
          <span>${next.labels.trayStyle}</span>
          <select id="statusItemStyle">
            ${optionMarkup(next.trayStyleOptions, next.settings.statusItemStyle)}
          </select>
        </label>
        <label class="settings-check">
          <input id="launchAtLoginEnabled" type="checkbox"${next.settings.launchAtLoginEnabled ? " checked" : ""} />
          <span>${next.labels.launchAtLogin}</span>
        </label>
      </section>
      <p id="status" class="settings-status">${next.message ?? ""}</p>
    </main>
  `;

  bindControls();
}

function readSettingsFromDom(): AppSettings {
  if (!presentation) {
    throw new Error("Settings presentation has not loaded");
  }
  return {
    ...presentation.settings,
    refreshIntervalPreset: (document.querySelector<HTMLSelectElement>("#refreshIntervalPreset")?.value ?? "fiveMinutes") as RefreshIntervalPreset,
    appLanguage: (document.querySelector<HTMLSelectElement>("#appLanguage")?.value ?? "system") as AppLanguage,
    statusItemStyle: (document.querySelector<HTMLSelectElement>("#statusItemStyle")?.value ?? "meter") as StatusItemStyle,
    launchAtLoginEnabled: document.querySelector<HTMLInputElement>("#launchAtLoginEnabled")?.checked ?? false,
  };
}

function bindControls(): void {
  for (const id of ["refreshIntervalPreset", "appLanguage", "statusItemStyle", "launchAtLoginEnabled"]) {
    document.querySelector(`#${id}`)?.addEventListener("change", async () => {
      const status = document.querySelector<HTMLParagraphElement>("#status");
      if (status) {
        status.textContent = "";
      }
      try {
        const updated = await invoke<SettingsPresentation>("update_settings", {
          updated: readSettingsFromDom(),
        });
        render(updated);
      } catch (error) {
        if (status) {
          status.textContent = String(error);
        }
      }
    });
  }
}

async function load(): Promise<void> {
  try {
    render(await invoke<SettingsPresentation>("get_settings"));
  } catch (error) {
    app.textContent = String(error);
  }
}

void load();
```

- [ ] **Step 3: Add CSS**

Create `WindowsTray/src/styles.css`:

```css
:root {
  color-scheme: light dark;
  font-family: "Segoe UI", system-ui, sans-serif;
  color: CanvasText;
  background: Canvas;
}

* {
  box-sizing: border-box;
}

body {
  margin: 0;
  min-width: 360px;
}

.settings-shell {
  padding: 22px 24px;
}

.settings-header {
  margin-bottom: 18px;
}

h1 {
  margin: 0;
  font-size: 20px;
  font-weight: 600;
  letter-spacing: 0;
}

.settings-form {
  display: grid;
  gap: 14px;
}

.settings-row {
  display: grid;
  grid-template-columns: 150px minmax(180px, 1fr);
  align-items: center;
  gap: 14px;
  font-size: 13px;
}

.settings-row span,
.settings-check span {
  line-height: 1.35;
}

select {
  width: 100%;
  min-height: 30px;
  padding: 3px 8px;
  font: inherit;
}

.settings-check {
  display: flex;
  align-items: center;
  gap: 9px;
  min-height: 30px;
  font-size: 13px;
}

.settings-check input {
  width: 16px;
  height: 16px;
  margin: 0;
}

.settings-status {
  min-height: 18px;
  margin: 18px 0 0;
  color: GrayText;
  font-size: 12px;
  line-height: 1.4;
}
```

- [ ] **Step 4: Run frontend typecheck**

Run:

```powershell
Set-Location WindowsTray
corepack npm run typecheck
```

Expected: TypeScript exits with code `0`.

- [ ] **Step 5: Run frontend build**

Run:

```powershell
Set-Location WindowsTray
corepack npm run build:frontend
```

Expected: Vite produces `WindowsTray/dist`.

- [ ] **Step 6: Commit**

```powershell
git add WindowsTray/src/main.ts WindowsTray/src/styles.css WindowsTray/index.html WindowsTray/src-tauri/tauri.conf.json
git commit -m "feat: add windows settings window"
```

---

### Task 8: Update Documentation And Verify

**Files:**
- Modify: `README.md`
- Modify: `docs/windows-mvp.md`

- [ ] **Step 1: Update Windows docs**

In `docs/windows-mvp.md`, update the feature list:

```markdown
- Opens a General settings window from the tray.
- Persists refresh interval, language, tray style, and launch-at-login settings.
- Supports automatic quota refresh when the refresh interval is not `Manual`.
```

Update `Not Included In The MVP` by removing `Full settings UI` and replacing it with:

```markdown
- Accounts settings beyond the General settings page.
```

- [ ] **Step 2: Update README Windows section**

In `README.md` under `Windows tray MVP`, revise the scope sentence to:

```markdown
The repository now includes a Tauri-based Windows tray app. It focuses on
showing the current active Codex account quota, configurable refresh behavior,
a small General settings window, opening the bundled Session Manager, opening
the local Codex folder, and quitting cleanly.
```

- [ ] **Step 3: Run Rust tests**

Run:

```powershell
Set-Location WindowsTray\src-tauri
cargo test
```

Expected: all Rust tests pass.

- [ ] **Step 4: Run frontend typecheck**

Run:

```powershell
Set-Location WindowsTray
corepack npm run typecheck
```

Expected: TypeScript exits with code `0`.

- [ ] **Step 5: Run frontend build**

Run:

```powershell
Set-Location WindowsTray
corepack npm run build:frontend
```

Expected: Vite produces `WindowsTray/dist`.

- [ ] **Step 6: Run Tauri build**

Run:

```powershell
Set-Location WindowsTray
corepack npm run build
```

Expected: Tauri builds the Windows tray app and installer artifacts.

- [ ] **Step 7: Manual verification**

Verify on Windows:

```text
1. Launching the app shows no main window.
2. Tray icon appears.
3. Tray menu has Settings..., Refresh Quota, Open Session Manager, Open Codex Folder, Quit.
4. Settings... opens and focuses the settings window.
5. Changing Refresh interval to Manual stops automatic refresh.
6. Changing Refresh interval to 1 minute starts automatic refresh.
7. Changing Language to Chinese updates the settings window and tray labels.
8. Changing Language to English updates the settings window and tray labels.
9. Launch at login checkbox persists when Windows accepts the registry update.
10. Quit exits the tray app and still stops only the owned Session Manager sidecar.
```

- [ ] **Step 8: Commit docs and verification fixes**

If verification required no code fixes:

```powershell
git add README.md docs/windows-mvp.md
git commit -m "docs: update windows settings scope"
```

If verification required code fixes, include the touched files:

```powershell
git add README.md docs/windows-mvp.md WindowsTray
git commit -m "fix: verify windows settings alignment"
```

---

## Self-Review Notes

- Spec coverage: Tasks cover settings persistence, General settings window, localization, configurable refresh, launch at login, tray display style contract, docs, and verification.
- Scope check: Account vaults, ChatGPT sign-in, API account creation, safe switching, rollback, and Session Manager language bridging remain out of this plan.
- Type consistency: `AppSettings`, `RefreshIntervalPreset`, `StatusItemStyle`, `AppLanguage`, and `ResolvedAppLanguage` use serde camelCase so Rust fields map to frontend names.
- Risk note: The refresh scheduler code should be checked carefully during execution because timer lifecycle bugs are easier to see in running behavior than in unit tests.
