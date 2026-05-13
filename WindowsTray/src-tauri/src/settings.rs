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
#[serde(default, rename_all = "camelCase")]
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

pub fn load_settings(settings_path: &Path) -> SettingsLoadResult {
    if !settings_path.exists() {
        return SettingsLoadResult {
            settings: AppSettings::default(),
            issue: None,
        };
    }

    match fs::read_to_string(settings_path)
        .map_err(|error| error.to_string())
        .and_then(|text| {
            serde_json::from_str::<AppSettings>(&text).map_err(|error| error.to_string())
        }) {
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
    fs::write(settings_path, data).map_err(|error| AppError::SettingsSaveFailed(error.to_string()))
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

        assert_eq!(
            result.settings.refresh_interval_preset,
            RefreshIntervalPreset::Manual
        );
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
        assert_eq!(
            RefreshIntervalPreset::OneMinute.interval(),
            Some(Duration::from_secs(60))
        );
        assert_eq!(
            RefreshIntervalPreset::FiveMinutes.interval(),
            Some(Duration::from_secs(300))
        );
        assert_eq!(
            RefreshIntervalPreset::FifteenMinutes.interval(),
            Some(Duration::from_secs(900))
        );
    }
}
