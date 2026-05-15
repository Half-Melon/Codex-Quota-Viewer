use serde::Serialize;

use crate::account_activation::activate_account_record;
use crate::account_models::{AccountKind, AccountRowState, AddApiAccountInput};
use crate::account_vault::AccountVault;
use crate::app_state::SharedAppState;
use crate::errors::AppError;
use crate::localization::{app_error_message, localize, LocalizedText};
use crate::settings::ResolvedAppLanguage;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountRow {
    pub id: String,
    pub display_name: String,
    pub kind: AccountKind,
    pub state: AccountRowState,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountLabels {
    pub accounts: String,
    pub sign_in_with_chatgpt: String,
    pub add_api_account: String,
    pub open_vault_folder: String,
    pub activate: String,
    pub rename: String,
    pub forget: String,
    pub current: String,
    pub no_saved_accounts: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountsPresentation {
    pub labels: AccountLabels,
    pub rows: Vec<AccountRow>,
    pub message: Option<String>,
}

pub fn build_accounts_presentation(
    vault: &AccountVault,
    language: ResolvedAppLanguage,
    message: Option<String>,
) -> Result<AccountsPresentation, AppError> {
    let listed = vault.list_accounts()?;
    let rows = listed
        .records
        .into_iter()
        .map(|record| AccountRow {
            id: record.id.as_str().to_string(),
            display_name: record.metadata.display_name,
            kind: record.metadata.kind,
            state: AccountRowState::Available,
            status: localize(
                language,
                LocalizedText::new("Available", "\u{53ef}\u{7528}"),
            ),
        })
        .collect();

    Ok(AccountsPresentation {
        labels: AccountLabels {
            accounts: localize(language, LocalizedText::new("Accounts", "\u{8d26}\u{53f7}")),
            sign_in_with_chatgpt: localize(
                language,
                LocalizedText::new("Sign in with ChatGPT", "\u{4f7f}\u{7528} ChatGPT \u{767b}\u{5f55}"),
            ),
            add_api_account: localize(
                language,
                LocalizedText::new("Add API Account", "\u{6dfb}\u{52a0} API \u{8d26}\u{53f7}"),
            ),
            open_vault_folder: localize(
                language,
                LocalizedText::new("Open Vault Folder", "\u{6253}\u{5f00}\u{8d26}\u{53f7}\u{4ed3}\u{6587}\u{4ef6}\u{5939}"),
            ),
            activate: localize(
                language,
                LocalizedText::new("Activate", "\u{6fc0}\u{6d3b}"),
            ),
            rename: localize(language, LocalizedText::new("Rename", "\u{91cd}\u{547d}\u{540d}")),
            forget: localize(language, LocalizedText::new("Forget", "\u{79fb}\u{9664}")),
            current: localize(language, LocalizedText::new("Current", "\u{5f53}\u{524d}")),
            no_saved_accounts: localize(
                language,
                LocalizedText::new("No saved accounts", "\u{6682}\u{65e0}\u{5df2}\u{4fdd}\u{5b58}\u{8d26}\u{53f7}"),
            ),
        },
        rows,
        message: message.or(listed.issue),
    })
}

#[tauri::command]
pub async fn get_accounts(
    state: tauri::State<'_, SharedAppState>,
) -> Result<AccountsPresentation, String> {
    let app_state = state.inner().clone();
    let language = super::current_resolved_language(&app_state).await;
    let vault = AccountVault::new(app_state.accounts_dir.clone());
    build_accounts_presentation(&vault, language, None)
        .map_err(|error| app_error_message(language, &error))
}

#[tauri::command]
pub async fn import_current_chatgpt_account(
    state: tauri::State<'_, SharedAppState>,
    display_name: Option<String>,
) -> Result<AccountsPresentation, String> {
    let app_state = state.inner().clone();
    let language = super::current_resolved_language(&app_state).await;
    let vault = AccountVault::new(app_state.accounts_dir.clone());
    vault
        .import_current_chatgpt_account(&app_state.codex_home, display_name)
        .map_err(|error| app_error_message(language, &error))?;
    build_accounts_presentation(
        &vault,
        language,
        Some(localize(
            language,
            LocalizedText::new("Account saved", "\u{8d26}\u{53f7}\u{5df2}\u{4fdd}\u{5b58}"),
        )),
    )
    .map_err(|error| app_error_message(language, &error))
}

#[tauri::command]
pub async fn add_api_account(
    state: tauri::State<'_, SharedAppState>,
    input: AddApiAccountInput,
) -> Result<AccountsPresentation, String> {
    let app_state = state.inner().clone();
    let language = super::current_resolved_language(&app_state).await;
    let vault = AccountVault::new(app_state.accounts_dir.clone());
    vault
        .add_api_account(input)
        .map_err(|error| app_error_message(language, &error))?;
    build_accounts_presentation(
        &vault,
        language,
        Some(localize(
            language,
            LocalizedText::new("Account saved", "\u{8d26}\u{53f7}\u{5df2}\u{4fdd}\u{5b58}"),
        )),
    )
    .map_err(|error| app_error_message(language, &error))
}

#[tauri::command]
pub async fn activate_account(
    app: tauri::AppHandle,
    state: tauri::State<'_, SharedAppState>,
    account_id: String,
) -> Result<AccountsPresentation, String> {
    let app_state = state.inner().clone();
    let language = super::current_resolved_language(&app_state).await;
    let vault = AccountVault::new(app_state.accounts_dir.clone());
    let record = vault
        .load_record(&account_id)
        .map_err(|error| app_error_message(language, &error))?;
    activate_account_record(&record, &app_state.codex_home)
        .map_err(|error| app_error_message(language, &error))?;
    super::spawn_refresh(app, app_state.clone());
    build_accounts_presentation(
        &vault,
        language,
        Some(localize(
            language,
            LocalizedText::new("Account activated", "\u{8d26}\u{53f7}\u{5df2}\u{6fc0}\u{6d3b}"),
        )),
    )
    .map_err(|error| app_error_message(language, &error))
}

#[tauri::command]
pub async fn rename_account(
    state: tauri::State<'_, SharedAppState>,
    account_id: String,
    display_name: String,
) -> Result<AccountsPresentation, String> {
    let app_state = state.inner().clone();
    let language = super::current_resolved_language(&app_state).await;
    let vault = AccountVault::new(app_state.accounts_dir.clone());
    vault
        .rename_account(&account_id, &display_name)
        .map_err(|error| app_error_message(language, &error))?;
    build_accounts_presentation(
        &vault,
        language,
        Some(localize(
            language,
            LocalizedText::new("Account renamed", "\u{8d26}\u{53f7}\u{5df2}\u{91cd}\u{547d}\u{540d}"),
        )),
    )
    .map_err(|error| app_error_message(language, &error))
}

#[tauri::command]
pub async fn forget_account(
    state: tauri::State<'_, SharedAppState>,
    account_id: String,
) -> Result<AccountsPresentation, String> {
    let app_state = state.inner().clone();
    let language = super::current_resolved_language(&app_state).await;
    let vault = AccountVault::new(app_state.accounts_dir.clone());
    vault
        .forget_account(&account_id)
        .map_err(|error| app_error_message(language, &error))?;
    build_accounts_presentation(
        &vault,
        language,
        Some(localize(
            language,
            LocalizedText::new("Account forgotten", "\u{8d26}\u{53f7}\u{5df2}\u{79fb}\u{9664}"),
        )),
    )
    .map_err(|error| app_error_message(language, &error))
}

#[tauri::command]
pub async fn open_vault_folder(
    state: tauri::State<'_, SharedAppState>,
) -> Result<(), String> {
    let app_state = state.inner().clone();
    std::fs::create_dir_all(&app_state.accounts_dir).map_err(|error| error.to_string())?;
    open::that(&app_state.accounts_dir).map_err(|error| error.to_string())
}

pub fn spawn_activate_account_from_tray(
    app: tauri::AppHandle,
    state: SharedAppState,
    account_id: String,
) {
    tauri::async_runtime::spawn(async move {
        let language = super::current_resolved_language(&state).await;
        let vault = AccountVault::new(state.accounts_dir.clone());
        let result = async {
            let record = vault
                .load_record(&account_id)
                .map_err(|error| app_error_message(language, &error))?;
            activate_account_record(&record, &state.codex_home)
                .map_err(|error| app_error_message(language, &error))?;
            Ok::<(), String>(())
        }
        .await;

        if let Err(error) = result {
            let mut snapshot = state.tray_snapshot.lock().await;
            snapshot.last_error = Some(crate::errors::AppError::AccountActivationFailed(error));
            drop(snapshot);
            let _ = super::update_tray_from_state(&app, &state).await;
        } else {
            super::spawn_refresh(app.clone(), state.clone());
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account_models::AddApiAccountInput;
    use crate::account_vault::AccountVault;

    #[test]
    fn builds_empty_accounts_presentation() {
        let temp = tempfile::tempdir().unwrap();
        let vault = AccountVault::new(temp.path().join("Accounts"));

        let presentation =
            build_accounts_presentation(&vault, ResolvedAppLanguage::English, None).unwrap();

        assert_eq!(presentation.rows.len(), 0);
        assert_eq!(presentation.labels.accounts, "Accounts");
        assert_eq!(presentation.labels.no_saved_accounts, "No saved accounts");
    }

    #[test]
    fn maps_api_record_to_available_row() {
        let temp = tempfile::tempdir().unwrap();
        let vault = AccountVault::new(temp.path().join("Accounts"));
        vault
            .add_api_account(AddApiAccountInput {
                display_name: "Work API".to_string(),
                api_key: "sk-test".to_string(),
                base_url: "https://api.openai.com/v1".to_string(),
                model: None,
                provider_name: None,
            })
            .unwrap();

        let presentation = build_accounts_presentation(
            &vault,
            ResolvedAppLanguage::English,
            Some("Saved".to_string()),
        )
        .unwrap();

        assert_eq!(presentation.rows[0].display_name, "Work API");
        assert_eq!(presentation.rows[0].kind, AccountKind::Api);
        assert_eq!(presentation.rows[0].state, AccountRowState::Available);
        assert_eq!(presentation.message.as_deref(), Some("Saved"));
    }
}
