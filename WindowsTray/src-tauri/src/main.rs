#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod codex_home;
mod errors;
mod quota;
mod session_manager;

fn main() {
    tauri::Builder::default()
        .setup(|_app| Ok(()))
        .run(tauri::generate_context!())
        .expect("failed to run Codex Quota Viewer Windows tray app");
}
