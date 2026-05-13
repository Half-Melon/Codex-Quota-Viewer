use std::fs;
use std::path::Path;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::errors::AppError;
use crate::localization::{localize, LocalizedText};

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
            refresh_interval: localize(
                resolved_language,
                LocalizedText::new("Refresh interval", "刷新频率"),
            ),
            language: localize(resolved_language, LocalizedText::new("Language", "语言")),
            tray_style: localize(
                resolved_language,
                LocalizedText::new("Tray style", "托盘样式"),
            ),
            launch_at_login: localize(
                resolved_language,
                LocalizedText::new("Launch at login", "登录时启动"),
            ),
            saved: localize(resolved_language, LocalizedText::new("Saved", "已保存")),
        },
        refresh_interval_options: vec![
            SelectOption {
                value: "manual".into(),
                label: localize(resolved_language, LocalizedText::new("Manual", "手动")),
            },
            SelectOption {
                value: "oneMinute".into(),
                label: localize(resolved_language, LocalizedText::new("1 minute", "1 分钟")),
            },
            SelectOption {
                value: "fiveMinutes".into(),
                label: localize(resolved_language, LocalizedText::new("5 minutes", "5 分钟")),
            },
            SelectOption {
                value: "fifteenMinutes".into(),
                label: localize(
                    resolved_language,
                    LocalizedText::new("15 minutes", "15 分钟"),
                ),
            },
        ],
        language_options: vec![
            SelectOption {
                value: "system".into(),
                label: localize(
                    resolved_language,
                    LocalizedText::new("Follow System", "跟随系统"),
                ),
            },
            SelectOption {
                value: "english".into(),
                label: localize(resolved_language, LocalizedText::new("English", "英文")),
            },
            SelectOption {
                value: "chinese".into(),
                label: localize(resolved_language, LocalizedText::new("Chinese", "中文")),
            },
        ],
        tray_style_options: vec![
            SelectOption {
                value: "meter".into(),
                label: localize(resolved_language, LocalizedText::new("Meter", "仪表")),
            },
            SelectOption {
                value: "text".into(),
                label: localize(resolved_language, LocalizedText::new("Text", "文字")),
            },
        ],
        message,
    }
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

    #[test]
    fn builds_english_settings_presentation() {
        let presentation =
            settings_presentation(AppSettings::default(), ResolvedAppLanguage::English, None);

        assert_eq!(presentation.labels.title, "Settings");
        assert_eq!(presentation.labels.saved, "Saved");
        assert_eq!(presentation.refresh_interval_options[0].value, "manual");
        assert_eq!(presentation.refresh_interval_options[0].label, "Manual");
        assert_eq!(presentation.language_options[0].value, "system");
        assert_eq!(presentation.tray_style_options[1].value, "text");
        assert_eq!(presentation.message, None);
    }

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
        assert_eq!(presentation.labels.refresh_interval, "刷新频率");
        assert_eq!(presentation.language_options[2].value, "chinese");
        assert_eq!(presentation.language_options[2].label, "中文");
        assert_eq!(presentation.message.as_deref(), Some("已保存"));
    }
}
