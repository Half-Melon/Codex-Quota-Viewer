use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use tauri::async_runtime::Mutex;

use crate::errors::AppError;
use crate::quota::QuotaSnapshot;
use crate::scheduler::RefreshScheduler;
use crate::session_manager::SessionManager;
use crate::settings::AppSettings;

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
    pub settings_path: PathBuf,
    pub settings: Mutex<AppSettings>,
    pub settings_load_issue: Mutex<Option<String>>,
    pub tray_snapshot: Mutex<TraySnapshot>,
    pub session_manager: Mutex<SessionManager>,
    pub refresh_scheduler: Mutex<RefreshScheduler>,
    pub refresh_in_progress: Mutex<bool>,
    pub quota_timeout: Duration,
}

pub type SharedAppState = Arc<AppState>;
