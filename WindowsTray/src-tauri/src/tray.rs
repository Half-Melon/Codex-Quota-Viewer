use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::AppHandle;

use crate::app_state::TraySnapshot;
use crate::localization::{app_error_message, localize, LocalizedText};
use crate::settings::ResolvedAppLanguage;

pub const MENU_REFRESH: &str = "refresh_quota";
pub const MENU_SETTINGS: &str = "settings";
pub const MENU_OPEN_SESSION_MANAGER: &str = "open_session_manager";
pub const MENU_OPEN_CODEX_FOLDER: &str = "open_codex_folder";
pub const MENU_QUIT: &str = "quit";

pub fn build_menu(
    app: &AppHandle,
    snapshot: &TraySnapshot,
    language: ResolvedAppLanguage,
) -> tauri::Result<Menu<tauri::Wry>> {
    let title = if snapshot.is_refreshing {
        localize(
            language,
            LocalizedText::new(
                "Refreshing quota...",
                "\u{6b63}\u{5728}\u{5237}\u{65b0}\u{989d}\u{5ea6}...",
            ),
        )
    } else if let Some(quota) = &snapshot.quota {
        quota
            .account
            .email
            .clone()
            .or_else(|| quota.account.id.clone())
            .unwrap_or_else(|| {
                localize(
                    language,
                    LocalizedText::new(
                        "Current Codex account",
                        "\u{5f53}\u{524d} Codex \u{8d26}\u{53f7}",
                    ),
                )
            })
    } else if let Some(error) = &snapshot.last_error {
        app_error_message(language, error)
    } else {
        "Codex Quota Viewer".to_string()
    };

    let title_item = MenuItem::with_id(app, "status_title", title, false, None::<&str>)?;
    let quota_item = MenuItem::with_id(
        app,
        "quota",
        quota_label(snapshot, language),
        false,
        None::<&str>,
    )?;
    let refresh_item = MenuItem::with_id(
        app,
        MENU_REFRESH,
        localize(
            language,
            LocalizedText::new("Refresh Quota", "\u{5237}\u{65b0}\u{989d}\u{5ea6}"),
        ),
        true,
        None::<&str>,
    )?;
    let settings_item = MenuItem::with_id(
        app,
        MENU_SETTINGS,
        localize(
            language,
            LocalizedText::new("Settings...", "\u{8bbe}\u{7f6e}..."),
        ),
        true,
        None::<&str>,
    )?;
    let open_manager_item = MenuItem::with_id(
        app,
        MENU_OPEN_SESSION_MANAGER,
        localize(
            language,
            LocalizedText::new("Open Session Manager", "\u{6253}\u{5f00} Session Manager"),
        ),
        true,
        None::<&str>,
    )?;
    let open_folder_item = MenuItem::with_id(
        app,
        MENU_OPEN_CODEX_FOLDER,
        localize(
            language,
            LocalizedText::new(
                "Open Codex Folder",
                "\u{6253}\u{5f00} Codex \u{6587}\u{4ef6}\u{5939}",
            ),
        ),
        true,
        None::<&str>,
    )?;
    let quit_item = MenuItem::with_id(
        app,
        MENU_QUIT,
        localize(language, LocalizedText::new("Quit", "\u{9000}\u{51fa}")),
        true,
        None::<&str>,
    )?;
    let separator_a = PredefinedMenuItem::separator(app)?;
    let separator_b = PredefinedMenuItem::separator(app)?;

    Menu::with_items(
        app,
        &[
            &title_item,
            &quota_item,
            &separator_a,
            &refresh_item,
            &settings_item,
            &open_manager_item,
            &open_folder_item,
            &separator_b,
            &quit_item,
        ],
    )
}

pub fn quota_label(snapshot: &TraySnapshot, language: ResolvedAppLanguage) -> String {
    if let Some(quota) = &snapshot.quota {
        let windows = quota
            .windows
            .iter()
            .map(|window| format!("{}: {:.0}%", window.label, window.remaining_percent))
            .collect::<Vec<_>>()
            .join("   ");
        if windows.is_empty() {
            localize(
                language,
                LocalizedText::new(
                    "Quota unavailable",
                    "\u{989d}\u{5ea6}\u{4e0d}\u{53ef}\u{7528}",
                ),
            )
        } else {
            windows
        }
    } else if let Some(error) = &snapshot.last_error {
        app_error_message(language, error)
    } else {
        localize(
            language,
            LocalizedText::new(
                "Quota loading",
                "\u{6b63}\u{5728}\u{8bfb}\u{53d6}\u{989d}\u{5ea6}",
            ),
        )
    }
}

pub fn install_tray(
    app: &AppHandle,
    snapshot: &TraySnapshot,
    language: ResolvedAppLanguage,
) -> tauri::Result<()> {
    let menu = build_menu(app, snapshot, language)?;
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

pub fn update_tray_menu(
    app: &AppHandle,
    snapshot: &TraySnapshot,
    language: ResolvedAppLanguage,
) -> tauri::Result<()> {
    let menu = build_menu(app, snapshot, language)?;
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

        assert_eq!(
            quota_label(&snapshot, ResolvedAppLanguage::English),
            "5h: 42%   1w: 88%"
        );
    }

    #[test]
    fn localizes_loading_label() {
        let snapshot = TraySnapshot::loading();

        assert_eq!(
            quota_label(&snapshot, ResolvedAppLanguage::Chinese),
            "\u{6b63}\u{5728}\u{8bfb}\u{53d6}\u{989d}\u{5ea6}"
        );
    }
}
