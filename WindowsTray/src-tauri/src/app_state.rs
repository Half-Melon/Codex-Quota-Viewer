use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use tauri::async_runtime::Mutex;

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
