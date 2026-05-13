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
    let launch_changed = previous.launch_at_login_enabled != updated.launch_at_login_enabled;

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

fn quoted_run_value(exe_path: &str) -> String {
    format!("\"{}\"", exe_path.replace('"', "\\\""))
}

impl LaunchAtLoginManager for WindowsRunKeyLaunchAtLogin {
    fn sync(&mut self, enabled: bool) -> Result<(), AppError> {
        let run_value = quoted_run_value(&self.exe_path);
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
                    &run_value,
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
    fn quotes_run_value_for_paths_with_spaces() {
        assert_eq!(
            quoted_run_value(r"C:\Program Files\Codex Quota Viewer\app.exe"),
            r#""C:\Program Files\Codex Quota Viewer\app.exe""#
        );
    }

    #[test]
    fn saves_without_side_effect_when_launch_setting_unchanged() {
        let previous = AppSettings::default();
        let updated = AppSettings {
            app_language: crate::settings::AppLanguage::Chinese,
            ..previous.clone()
        };
        let mut manager = FakeLaunchManager::default();

        let result =
            apply_settings_transaction(previous, updated.clone(), &mut manager, |_| Ok(()))
                .unwrap();

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

        let result =
            apply_settings_transaction(previous, updated.clone(), &mut manager, |_| Ok(()))
                .unwrap();

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
