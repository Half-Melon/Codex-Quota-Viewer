use std::fs;
use std::path::Path;

use crate::account_models::{AccountPayload, VaultAccountRecord};
use crate::errors::AppError;

pub fn activate_account_record(
    record: &VaultAccountRecord,
    codex_home: &Path,
) -> Result<(), AppError> {
    fs::create_dir_all(codex_home)
        .map_err(|error| AppError::AccountActivationFailed(error.to_string()))?;

    match &record.payload {
        AccountPayload::ChatGpt { auth_json } => {
            write_json_file(&codex_home.join("auth.json"), auth_json)
        }
        AccountPayload::Api(payload) => {
            let auth_json = serde_json::json!({
                "OPENAI_API_KEY": payload.api_key,
                "type": "api"
            });
            write_json_file(&codex_home.join("auth.json"), &auth_json)?;

            let model = payload.model.as_deref().unwrap_or("gpt-5.4");
            let provider = payload.provider_name.as_deref().unwrap_or("openai");
            let config = format!(
                "model = \"{}\"\nmodel_provider = \"{}\"\n\n[model_providers.{}]\nname = \"{}\"\nbase_url = \"{}\"\nenv_key = \"OPENAI_API_KEY\"\n",
                escape_toml(model),
                escape_toml(provider),
                escape_toml(provider),
                escape_toml(provider),
                escape_toml(&payload.base_url)
            );
            write_text_file(&codex_home.join("config.toml"), &config)
        }
    }
}

fn write_json_file(path: &Path, value: &serde_json::Value) -> Result<(), AppError> {
    let data = serde_json::to_vec_pretty(value)
        .map_err(|error| AppError::AccountActivationFailed(error.to_string()))?;
    write_bytes_file(path, &data)
}

fn write_text_file(path: &Path, text: &str) -> Result<(), AppError> {
    write_bytes_file(path, text.as_bytes())
}

fn write_bytes_file(path: &Path, data: &[u8]) -> Result<(), AppError> {
    let temp = path.with_extension("tmp");
    fs::write(&temp, data).map_err(|error| AppError::AccountActivationFailed(error.to_string()))?;
    fs::rename(&temp, path)
        .map_err(|error| AppError::AccountActivationFailed(error.to_string()))
}

fn escape_toml(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account_models::{AccountId, AddApiAccountInput};

    #[test]
    fn activates_chatgpt_by_writing_auth_json() {
        let temp = tempfile::tempdir().unwrap();
        let codex_home = temp.path().join(".codex");
        let record = VaultAccountRecord::new_chatgpt(
            AccountId::new("acct-chat"),
            "Chat".to_string(),
            serde_json::json!({"account":{"email":"ada@example.com"}}),
            chrono::Utc::now(),
        );

        activate_account_record(&record, &codex_home).unwrap();

        let text = fs::read_to_string(codex_home.join("auth.json")).unwrap();
        assert!(text.contains("ada@example.com"));
    }

    #[test]
    fn activates_api_by_writing_auth_and_config() {
        let temp = tempfile::tempdir().unwrap();
        let codex_home = temp.path().join(".codex");
        let payload = AddApiAccountInput {
            display_name: "API".to_string(),
            api_key: "sk-test".to_string(),
            base_url: "https://api.openai.com/v1".to_string(),
            model: Some("gpt-5.4".to_string()),
            provider_name: Some("OpenAI".to_string()),
        }
        .validate()
        .unwrap();
        let record = VaultAccountRecord::new_api(
            AccountId::new("acct-api"),
            "API".to_string(),
            payload.payload,
            chrono::Utc::now(),
        );

        activate_account_record(&record, &codex_home).unwrap();

        let auth = fs::read_to_string(codex_home.join("auth.json")).unwrap();
        let config = fs::read_to_string(codex_home.join("config.toml")).unwrap();
        assert!(auth.contains("sk-test"));
        assert!(config.contains("https://api.openai.com/v1"));
        assert!(config.contains("gpt-5.4"));
    }
}
