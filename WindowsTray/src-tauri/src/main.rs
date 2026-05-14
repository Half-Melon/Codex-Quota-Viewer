#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::Arc;
use std::time::Duration;

use tauri::{AppHandle, Manager};

mod account_models;
mod account_vault;
mod app_state;
mod codex_home;
mod errors;
mod launch_at_login;
mod localization;
mod quota;
mod scheduler;
mod session_manager;
mod settings;
mod tray;

use app_state::{AppState, SharedAppState, TraySnapshot};
use codex_home::resolve_codex_home;
use errors::AppError;
use launch_at_login::{apply_settings_transaction, WindowsRunKeyLaunchAtLogin};
use localization::{app_error_message, localize, resolve_language, LocalizedText};
use quota::fetch_current_quota;
use scheduler::RefreshScheduler;
use session_manager::{SessionManager, SessionManagerPaths};
use settings::{
    load_settings, save_settings, settings_presentation, AppSettings, SettingsPresentation,
};
use tray::{
    MENU_OPEN_CODEX_FOLDER, MENU_OPEN_SESSION_MANAGER, MENU_QUIT, MENU_REFRESH, MENU_SETTINGS,
};

#[tauri::command]
async fn get_settings(
    state: tauri::State<'_, SharedAppState>,
) -> Result<SettingsPresentation, String> {
    let app_state = state.inner().clone();
    let mut settings = app_state.settings.lock().await.clone();
    let issue = app_state.settings_load_issue.lock().await.clone();
    let resolved = resolve_language(settings.app_language, &system_language_hints());
    settings.last_resolved_language = Some(resolved);

    Ok(settings_presentation(settings, resolved, issue))
}

#[tauri::command]
async fn update_settings(
    app: AppHandle,
    state: tauri::State<'_, SharedAppState>,
    mut updated: AppSettings,
) -> Result<SettingsPresentation, String> {
    let app_state = state.inner().clone();
    let previous = app_state.settings.lock().await.clone();
    let resolved = resolve_language(updated.app_language, &system_language_hints());
    updated.last_resolved_language = Some(resolved);

    let settings_path = app_state.settings_path.clone();
    let launch_changed = previous.launch_at_login_enabled != updated.launch_at_login_enabled;
    let exe_path = if launch_changed {
        std::env::current_exe()
            .map_err(|error| AppError::LaunchAtLoginFailed(error.to_string()))
            .map_err(|error| app_error_message(resolved, &error))?
            .to_string_lossy()
            .to_string()
    } else {
        String::new()
    };
    let mut launch_manager = WindowsRunKeyLaunchAtLogin::new("Codex Quota Viewer", exe_path);

    let saved = apply_settings_transaction(previous, updated, &mut launch_manager, |settings| {
        save_settings(&settings_path, settings)
    })
    .map_err(|error| app_error_message(resolved, &error))?;

    {
        let mut current = app_state.settings.lock().await;
        *current = saved.clone();
    }
    {
        let mut issue = app_state.settings_load_issue.lock().await;
        *issue = None;
    }

    restart_refresh_scheduler(app.clone(), app_state.clone(), saved.clone());
    update_tray_from_state(&app, &app_state).await;

    Ok(settings_presentation(
        saved,
        resolved,
        Some(localize(
            resolved,
            LocalizedText::new("Saved", "\u{5df2}\u{4fdd}\u{5b58}"),
        )),
    ))
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![get_settings, update_settings])
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
            let settings_path = app_data_dir.join("settings.json");
            let settings_result = load_settings(&settings_path);
            let settings = settings_result.settings.clone();

            let state: SharedAppState = Arc::new(AppState {
                codex_home,
                settings_path,
                settings: tauri::async_runtime::Mutex::new(settings.clone()),
                settings_load_issue: tauri::async_runtime::Mutex::new(settings_result.issue),
                tray_snapshot: tauri::async_runtime::Mutex::new(TraySnapshot::loading()),
                session_manager: tauri::async_runtime::Mutex::new(SessionManager::new(
                    session_paths,
                )),
                refresh_scheduler: tauri::async_runtime::Mutex::new(RefreshScheduler::new()),
                refresh_in_progress: tauri::async_runtime::Mutex::new(false),
                quota_timeout: Duration::from_secs(10),
            });

            app.manage(state.clone());
            let resolved_language =
                resolve_language(settings.app_language, &system_language_hints());
            tray::install_tray(&app_handle, &TraySnapshot::loading(), resolved_language)?;
            spawn_refresh(app_handle.clone(), state.clone());
            start_refresh_scheduler(app_handle, state, settings);
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("failed to run Codex Quota Viewer Windows tray app");
}

pub(crate) fn handle_menu_event(app: &AppHandle, menu_id: &str) {
    let state = app.state::<SharedAppState>().inner().clone();
    match menu_id {
        MENU_REFRESH => spawn_refresh(app.clone(), state),
        MENU_SETTINGS => show_settings_window(app),
        MENU_OPEN_SESSION_MANAGER => spawn_open_session_manager(app.clone(), state),
        MENU_OPEN_CODEX_FOLDER => {
            let codex_home = state.codex_home.clone();
            let _ = open::that(codex_home);
        }
        MENU_QUIT => spawn_quit(app.clone(), state),
        _ => {}
    }
}

fn start_refresh_scheduler(app: AppHandle, state: SharedAppState, settings: AppSettings) {
    tauri::async_runtime::spawn(async move {
        let handle = settings.refresh_interval_preset.interval().map(|duration| {
            let app = app.clone();
            let state = state.clone();
            tauri::async_runtime::spawn(async move {
                let mut ticker = tokio::time::interval(duration);
                ticker.tick().await;
                loop {
                    ticker.tick().await;
                    spawn_refresh(app.clone(), state.clone());
                }
            })
        });

        let mut scheduler = state.refresh_scheduler.lock().await;
        scheduler.replace_with(handle);
    });
}

fn restart_refresh_scheduler(app: AppHandle, state: SharedAppState, settings: AppSettings) {
    start_refresh_scheduler(app, state, settings);
}

async fn current_resolved_language(state: &SharedAppState) -> settings::ResolvedAppLanguage {
    let settings = state.settings.lock().await;
    resolve_language(settings.app_language, &system_language_hints())
}

fn system_language_hints() -> Vec<String> {
    std::env::var("LANG")
        .ok()
        .into_iter()
        .chain(std::env::var("LANGUAGE").ok())
        .collect()
}

async fn update_tray_from_state(app: &AppHandle, state: &SharedAppState) {
    let snapshot = state.tray_snapshot.lock().await.clone();
    let language = current_resolved_language(state).await;
    let _ = tray::update_tray_menu(app, &snapshot, language);
}

fn spawn_refresh(app: AppHandle, state: SharedAppState) {
    tauri::async_runtime::spawn(async move {
        {
            let mut in_progress = state.refresh_in_progress.lock().await;
            if *in_progress {
                return;
            }
            *in_progress = true;
        }

        {
            let mut snapshot = state.tray_snapshot.lock().await;
            snapshot.is_refreshing = true;
        }
        update_tray_from_state(&app, &state).await;

        let result = fetch_current_quota(&state.codex_home, state.quota_timeout).await;
        {
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
        }
        update_tray_from_state(&app, &state).await;

        {
            let mut in_progress = state.refresh_in_progress.lock().await;
            *in_progress = false;
        }
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
            drop(snapshot);
            update_tray_from_state(&app, &state).await;
        }
    });
}

fn show_settings_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
    }
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
