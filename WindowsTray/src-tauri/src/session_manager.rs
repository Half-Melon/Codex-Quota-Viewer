use std::path::PathBuf;
use std::process::Stdio;
use std::time::{Duration, Instant};

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
        let start = Instant::now();
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_port_conflict() {
        let error = classify_startup_diagnostics(
            "Error: listen EADDRINUSE: address already in use 127.0.0.1:4318",
        );
        assert_eq!(error, AppError::SessionManagerPortInUse);
    }

    #[test]
    fn classifies_missing_module_as_incomplete_bundle() {
        let error =
            classify_startup_diagnostics("Error: Cannot find module './dist/server/index.js'");
        assert_eq!(error, AppError::SessionManagerFilesIncomplete);
    }

    #[test]
    fn preserves_tail_of_unknown_startup_diagnostics() {
        let diagnostics = format!("{}tail", "x".repeat(1300));

        let error = classify_startup_diagnostics(&diagnostics);

        assert_eq!(
            error,
            AppError::SessionManagerStartFailed(format!("{}tail", "x".repeat(1196)))
        );
    }
}
