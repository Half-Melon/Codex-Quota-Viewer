use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct AccountId(String);

impl AccountId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AccountKind {
    ChatGpt,
    Api,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountMetadata {
    pub display_name: String,
    pub kind: AccountKind,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum AccountPayload {
    #[serde(rename_all = "camelCase")]
    ChatGpt {
        auth_json: serde_json::Value,
    },
    Api(ApiAccountPayload),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApiAccountPayload {
    pub api_key: String,
    pub base_url: String,
    pub model: Option<String>,
    pub provider_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VaultAccountRecord {
    pub version: u32,
    pub id: AccountId,
    pub metadata: AccountMetadata,
    pub payload: AccountPayload,
}

impl VaultAccountRecord {
    pub fn new_chatgpt(
        id: AccountId,
        display_name: impl Into<String>,
        auth_json: serde_json::Value,
        now: DateTime<Utc>,
    ) -> Self {
        Self {
            version: 1,
            id,
            metadata: AccountMetadata {
                display_name: display_name.into(),
                kind: AccountKind::ChatGpt,
                created_at: now,
                updated_at: now,
            },
            payload: AccountPayload::ChatGpt { auth_json },
        }
    }

    pub fn new_api(
        id: AccountId,
        display_name: impl Into<String>,
        payload: ApiAccountPayload,
        now: DateTime<Utc>,
    ) -> Self {
        Self {
            version: 1,
            id,
            metadata: AccountMetadata {
                display_name: display_name.into(),
                kind: AccountKind::Api,
                created_at: now,
                updated_at: now,
            },
            payload: AccountPayload::Api(payload),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AddApiAccountInput {
    pub display_name: String,
    pub api_key: String,
    pub base_url: String,
    pub model: Option<String>,
    pub provider_name: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AccountValidationError {
    MissingDisplayName,
    MissingApiKey,
    MissingBaseUrl,
    InvalidBaseUrl,
}

impl AddApiAccountInput {
    pub fn validate(self) -> Result<ApiAccountPayload, AccountValidationError> {
        let display_name = self.display_name.trim();
        if display_name.is_empty() {
            return Err(AccountValidationError::MissingDisplayName);
        }

        let api_key = self.api_key.trim();
        if api_key.is_empty() {
            return Err(AccountValidationError::MissingApiKey);
        }

        let base_url = self.base_url.trim();
        if base_url.is_empty() {
            return Err(AccountValidationError::MissingBaseUrl);
        }
        if !base_url.starts_with("http://") && !base_url.starts_with("https://") {
            return Err(AccountValidationError::InvalidBaseUrl);
        }

        Ok(ApiAccountPayload {
            api_key: api_key.to_string(),
            base_url: base_url.trim_end_matches('/').to_string(),
            model: trim_optional(self.model),
            provider_name: trim_optional(self.provider_name),
        })
    }
}

fn trim_optional(value: Option<String>) -> Option<String> {
    value.and_then(|value| {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AccountRowState {
    Active,
    Available,
    NeedsAttention,
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use serde_json::json;

    #[test]
    fn serializes_chatgpt_record_with_camel_case_fields() {
        let now = Utc.with_ymd_and_hms(2026, 5, 14, 8, 30, 0).unwrap();
        let record = VaultAccountRecord::new_chatgpt(
            AccountId::new("chatgpt-primary"),
            "ChatGPT Primary",
            json!({ "token": "secret" }),
            now,
        );

        let serialized = serde_json::to_string(&record).unwrap();

        assert!(serialized.contains("\"displayName\""));
        assert!(serialized.contains("\"type\":\"chatGpt\""));
        assert!(serialized.contains("\"authJson\""));
    }

    #[test]
    fn validates_api_account_input() {
        let payload = AddApiAccountInput {
            display_name: " OpenAI ".to_string(),
            api_key: " sk-test ".to_string(),
            base_url: " https://api.openai.com/v1/ ".to_string(),
            model: Some(" gpt-5 ".to_string()),
            provider_name: Some(" OpenAI ".to_string()),
        }
        .validate()
        .unwrap();

        assert_eq!(payload.api_key, "sk-test");
        assert_eq!(payload.base_url, "https://api.openai.com/v1");
        assert_eq!(payload.model, Some("gpt-5".to_string()));
        assert_eq!(payload.provider_name, Some("OpenAI".to_string()));
    }

    #[test]
    fn rejects_blank_api_key() {
        let result = AddApiAccountInput {
            display_name: "OpenAI".to_string(),
            api_key: " ".to_string(),
            base_url: "https://api.openai.com/v1".to_string(),
            model: None,
            provider_name: None,
        }
        .validate();

        assert_eq!(result, Err(AccountValidationError::MissingApiKey));
    }

    #[test]
    fn rejects_non_url_base_url() {
        let result = AddApiAccountInput {
            display_name: "OpenAI".to_string(),
            api_key: "sk-test".to_string(),
            base_url: "api.openai.com/v1".to_string(),
            model: None,
            provider_name: None,
        }
        .validate();

        assert_eq!(result, Err(AccountValidationError::InvalidBaseUrl));
    }
}
