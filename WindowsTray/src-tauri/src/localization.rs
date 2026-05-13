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
        AppError::CodexFolderNotFound => {
            LocalizedText::new("Codex folder not found", "未找到 Codex 文件夹")
        }
        AppError::SignInRequired => LocalizedText::new("Sign in required", "需要登录"),
        AppError::QuotaTimeout => {
            LocalizedText::new("Timed out while reading quota", "读取额度超时")
        }
        AppError::QuotaRefreshFailed(_) => {
            LocalizedText::new("Quota refresh failed", "额度刷新失败")
        }
        AppError::SessionManagerPortInUse => LocalizedText::new(
            "Session Manager port 4318 is already in use",
            "Session Manager 端口 4318 已被占用",
        ),
        AppError::SessionManagerFilesIncomplete => LocalizedText::new(
            "Bundled Session Manager files are incomplete",
            "内置 Session Manager 文件不完整",
        ),
        AppError::NodeRuntimeMissing => {
            LocalizedText::new("Bundled Node runtime is missing", "缺少内置 Node 运行时")
        }
        AppError::SessionManagerStartFailed(_) => LocalizedText::new(
            "Session Manager could not start",
            "Session Manager 无法启动",
        ),
        AppError::SettingsLoadFailed(_) => {
            LocalizedText::new("Settings could not be loaded", "设置无法加载")
        }
        AppError::SettingsSaveFailed(_) => {
            LocalizedText::new("Settings could not be saved", "设置无法保存")
        }
        AppError::LaunchAtLoginFailed(_) => {
            LocalizedText::new("Launch at login could not be updated", "登录时启动无法更新")
        }
    };
    localize(language, text)
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
        assert_eq!(
            localize(ResolvedAppLanguage::English, text.clone()),
            "Settings"
        );
        assert_eq!(localize(ResolvedAppLanguage::Chinese, text), "设置");
    }

    #[test]
    fn localizes_app_error_message() {
        let error = AppError::SettingsSaveFailed("disk full".into());

        assert_eq!(
            app_error_message(ResolvedAppLanguage::English, &error),
            "Settings could not be saved"
        );
        assert_eq!(
            app_error_message(ResolvedAppLanguage::Chinese, &error),
            "设置无法保存"
        );
    }
}
