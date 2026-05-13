#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::Arc;
use std::time::Duration;

use tauri::{AppHandle, Manager};

mod app_state;
mod codex_home;
mod errors;
mod quota;
mod session_manager;
mod tray;

use app_state::{AppState, SharedAppState, TraySnapshot};
use codex_home::resolve_codex_home;
use quota::fetch_current_quota;
use session_manager::{SessionManager, SessionManagerPaths};
use tray::{MENU_OPEN_CODEX_FOLDER, MENU_OPEN_SESSION_MANAGER, MENU_QUIT, MENU_REFRESH};

fn main() {
    tauri::Builder::default()
        .setup(|app| {
            let app_handle = app.handle().clone();
            let codex_home = resolve_codex_home()
                .unwrap_or_else(|_| std::path::PathBuf::from(r"C:\.codex-missing"));
            let resource_dir = app.path().resource_dir()?;
            let app_data_dir = app.path().app_data_dir()?;
            let session_paths = SessionManagerPaths {
                node_exe: resource_dir.join("NodeRuntime").join("node.exe"),
                server_entry: resource_dir
                    .join("SessionManager")
                    .join("dist")
                    .join("server")
                    .join("index.js"),
                app_dir: resource_dir.join("SessionManager"),
                codex_home: codex_home.clone(),
                manager_home: app_data_dir.join("SessionManager"),
            };

            let state: SharedAppState = Arc::new(AppState {
                codex_home,
                tray_snapshot: tauri::async_runtime::Mutex::new(TraySnapshot::loading()),
                session_manager: tauri::async_runtime::Mutex::new(SessionManager::new(
                    session_paths,
                )),
                quota_timeout: Duration::from_secs(10),
            });

            app.manage(state.clone());
            tray::install_tray(&app_handle, &TraySnapshot::loading())?;
            spawn_refresh(app_handle, state);
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("failed to run Codex Quota Viewer Windows tray app");
}

pub(crate) fn handle_menu_event(app: &AppHandle, menu_id: &str) {
    let state = app.state::<SharedAppState>().inner().clone();
    match menu_id {
        MENU_REFRESH => spawn_refresh(app.clone(), state),
        MENU_OPEN_SESSION_MANAGER => spawn_open_session_manager(app.clone(), state),
        MENU_OPEN_CODEX_FOLDER => {
            let codex_home = state.codex_home.clone();
            let _ = open::that(codex_home);
        }
        MENU_QUIT => spawn_quit(app.clone(), state),
        _ => {}
    }
}

fn spawn_refresh(app: AppHandle, state: SharedAppState) {
    tauri::async_runtime::spawn(async move {
        {
            let mut snapshot = state.tray_snapshot.lock().await;
            snapshot.is_refreshing = true;
            let _ = tray::update_tray_menu(&app, &snapshot);
        }

        let result = fetch_current_quota(&state.codex_home, state.quota_timeout).await;
        let mut snapshot = state.tray_snapshot.lock().await;
        snapshot.is_refreshing = false;
        match result {
            Ok(quota) => {
                snapshot.quota = Some(quota);
                snapshot.last_error = None;
            }
            Err(error) => {
                snapshot.last_error = Some(error);
            }
        }
        let _ = tray::update_tray_menu(&app, &snapshot);
    });
}

fn spawn_open_session_manager(app: AppHandle, state: SharedAppState) {
    tauri::async_runtime::spawn(async move {
        let result = {
            let mut manager = state.session_manager.lock().await;
            manager.open_in_browser().await
        };
        if let Err(error) = result {
            let mut snapshot = state.tray_snapshot.lock().await;
            snapshot.last_error = Some(error);
            let _ = tray::update_tray_menu(&app, &snapshot);
        }
    });
}

fn spawn_quit(app: AppHandle, state: SharedAppState) {
    tauri::async_runtime::spawn(async move {
        {
            let mut manager = state.session_manager.lock().await;
            manager.stop_owned_process().await;
        }
        app.exit(0);
    });
}
