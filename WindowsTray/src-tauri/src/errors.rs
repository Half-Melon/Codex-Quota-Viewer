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
    SettingsLoadFailed(String),
    SettingsSaveFailed(String),
    LaunchAtLoginFailed(String),
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
            Self::SettingsLoadFailed(_) => "Settings could not be loaded",
            Self::SettingsSaveFailed(_) => "Settings could not be saved",
            Self::LaunchAtLoginFailed(_) => "Launch at login could not be updated",
        }
    }

    pub fn diagnostics(&self) -> Option<&str> {
        match self {
            Self::QuotaRefreshFailed(message)
            | Self::SessionManagerStartFailed(message)
            | Self::SettingsLoadFailed(message)
            | Self::SettingsSaveFailed(message)
            | Self::LaunchAtLoginFailed(message) => Some(message),
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
