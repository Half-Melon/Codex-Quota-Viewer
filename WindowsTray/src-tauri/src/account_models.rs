use chrono::{DateTime, Utc};
use reqwest::Url;
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ValidatedApiAccountInput {
    pub display_name: String,
    pub payload: ApiAccountPayload,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AccountValidationError {
    MissingDisplayName,
    MissingApiKey,
    MissingBaseUrl,
    InvalidBaseUrl,
}

impl AddApiAccountInput {
    pub fn validate(self) -> Result<ValidatedApiAccountInput, AccountValidationError> {
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
        let base_url = normalize_base_url(base_url)?;

        Ok(ValidatedApiAccountInput {
            display_name: display_name.to_string(),
            payload: ApiAccountPayload {
                api_key: api_key.to_string(),
                base_url,
                model: trim_optional(self.model),
                provider_name: trim_optional(self.provider_name),
            },
        })
    }
}

fn normalize_base_url(base_url: &str) -> Result<String, AccountValidationError> {
    let parsed = Url::parse(base_url).map_err(|_| AccountValidationError::InvalidBaseUrl)?;
    if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none() {
        return Err(AccountValidationError::InvalidBaseUrl);
    }

    Ok(parsed.as_str().trim_end_matches('/').to_string())
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

        let value = serde_json::to_value(&record).unwrap();

        assert_eq!(
            value,
            json!({
                "version": 1,
                "id": "chatgpt-primary",
                "metadata": {
                    "displayName": "ChatGPT Primary",
                    "kind": "chatGpt",
                    "createdAt": "2026-05-14T08:30:00Z",
                    "updatedAt": "2026-05-14T08:30:00Z"
                },
                "payload": {
                    "type": "chatGpt",
                    "authJson": {
                        "token": "secret"
                    }
                }
            })
        );

        let deserialized: VaultAccountRecord = serde_json::from_value(value).unwrap();
        assert_eq!(deserialized, record);
    }

    #[test]
    fn serializes_api_record_with_camel_case_fields() {
        let now = Utc.with_ymd_and_hms(2026, 5, 14, 8, 30, 0).unwrap();
        let payload = ApiAccountPayload {
            api_key: "sk-test".to_string(),
            base_url: "https://api.openai.com/v1".to_string(),
            model: Some("gpt-5".to_string()),
            provider_name: Some("OpenAI".to_string()),
        };
        let record =
            VaultAccountRecord::new_api(AccountId::new("api-openai"), "OpenAI", payload, now);

        let value = serde_json::to_value(&record).unwrap();

        assert_eq!(
            value,
            json!({
                "version": 1,
                "id": "api-openai",
                "metadata": {
                    "displayName": "OpenAI",
                    "kind": "api",
                    "createdAt": "2026-05-14T08:30:00Z",
                    "updatedAt": "2026-05-14T08:30:00Z"
                },
                "payload": {
                    "type": "api",
                    "apiKey": "sk-test",
                    "baseUrl": "https://api.openai.com/v1",
                    "model": "gpt-5",
                    "providerName": "OpenAI"
                }
            })
        );

        let deserialized: VaultAccountRecord = serde_json::from_value(value).unwrap();
        assert_eq!(deserialized, record);
    }

    #[test]
    fn validates_api_account_input() {
        let validated = AddApiAccountInput {
            display_name: " OpenAI ".to_string(),
            api_key: " sk-test ".to_string(),
            base_url: " https://api.openai.com/v1/ ".to_string(),
            model: Some(" gpt-5 ".to_string()),
            provider_name: Some(" OpenAI ".to_string()),
        }
        .validate()
        .unwrap();

        let payload = validated.payload;
        assert_eq!(validated.display_name, "OpenAI");
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
        for base_url in [
            "api.openai.com/v1",
            "https://",
            "https:///",
            "file:///tmp/key",
        ] {
            let result = AddApiAccountInput {
                display_name: "OpenAI".to_string(),
                api_key: "sk-test".to_string(),
                base_url: base_url.to_string(),
                model: None,
                provider_name: None,
            }
            .validate();

            assert_eq!(result, Err(AccountValidationError::InvalidBaseUrl));
        }
    }
}
