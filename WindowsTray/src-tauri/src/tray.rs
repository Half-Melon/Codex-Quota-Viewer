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

    let title_item = MenuItem::with_id(app, "status_title", title, false, None::<&str>)?;
    let quota_item = MenuItem::with_id(app, "quota", quota_label(snapshot), false, None::<&str>)?;
    let refresh_item = MenuItem::with_id(app, MENU_REFRESH, "Refresh Quota", true, None::<&str>)?;
    let open_manager_item = MenuItem::with_id(
        app,
        MENU_OPEN_SESSION_MANAGER,
        "Open Session Manager",
        true,
        None::<&str>,
    )?;
    let open_folder_item = MenuItem::with_id(
        app,
        MENU_OPEN_CODEX_FOLDER,
        "Open Codex Folder",
        true,
        None::<&str>,
    )?;
    let quit_item = MenuItem::with_id(app, MENU_QUIT, "Quit", true, None::<&str>)?;
    let separator_a = PredefinedMenuItem::separator(app)?;
    let separator_b = PredefinedMenuItem::separator(app)?;

    Menu::with_items(
        app,
        &[
            &title_item,
            &quota_item,
            &separator_a,
            &refresh_item,
            &open_manager_item,
            &open_folder_item,
            &separator_b,
            &quit_item,
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
    let mut builder = TrayIconBuilder::with_id("main")
        .tooltip("Codex Quota Viewer")
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| {
            crate::handle_menu_event(app, event.id.as_ref());
        });

    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }

    builder.build(app)?;
    Ok(())
}

pub fn update_tray_menu(app: &AppHandle, snapshot: &TraySnapshot) -> tauri::Result<()> {
    let menu = build_menu(app, snapshot)?;
    if let Some(tray) = app.tray_by_id("main") {
        tray.set_menu(Some(menu))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

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
