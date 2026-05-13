use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::errors::AppError;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountSummary {
    pub id: Option<String>,
    pub email: Option<String>,
    pub account_type: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QuotaWindow {
    pub label: String,
    pub remaining_percent: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QuotaSnapshot {
    pub account: AccountSummary,
    pub windows: Vec<QuotaWindow>,
    pub fetched_at: DateTime<Utc>,
}

pub fn parse_snapshot_from_rpc_values(
    account_value: serde_json::Value,
    rate_limits_value: serde_json::Value,
) -> Result<QuotaSnapshot, AppError> {
    let account_node = account_value
        .get("account")
        .cloned()
        .ok_or_else(|| AppError::QuotaRefreshFailed("account/read missing account".to_string()))?;

    if account_node.is_null() {
        return Err(AppError::SignInRequired);
    }

    let account = AccountSummary {
        id: account_node
            .get("id")
            .and_then(|value| value.as_str())
            .map(str::to_string),
        email: account_node
            .get("email")
            .and_then(|value| value.as_str())
            .map(str::to_string),
        account_type: account_node
            .get("type")
            .and_then(|value| value.as_str())
            .unwrap_or("unknown")
            .to_string(),
    };

    let rate_limits_node = rate_limits_value
        .get("rateLimits")
        .ok_or_else(|| AppError::QuotaRefreshFailed("rateLimits missing".to_string()))?;

    let windows = if let Some(windows_node) = rate_limits_node
        .get("windows")
        .and_then(|value| value.as_array())
    {
        parse_flat_windows(windows_node)
    } else {
        parse_primary_secondary_windows(rate_limits_node)
    };

    Ok(QuotaSnapshot {
        account,
        windows,
        fetched_at: Utc::now(),
    })
}

pub async fn fetch_current_quota(
    codex_home: &Path,
    timeout_duration: Duration,
) -> Result<QuotaSnapshot, AppError> {
    if !codex_home.exists() {
        return Err(AppError::CodexFolderNotFound);
    }

    let codex_home = codex_home.to_path_buf();
    tokio::task::spawn_blocking(move || fetch_current_quota_blocking(codex_home, timeout_duration))
        .await
        .map_err(|error| AppError::QuotaRefreshFailed(error.to_string()))?
}

fn parse_flat_windows(windows_node: &[serde_json::Value]) -> Vec<QuotaWindow> {
    windows_node
        .iter()
        .filter_map(|window| {
            let label = window.get("label")?.as_str()?.to_string();
            let remaining_percent = window.get("remainingPercent")?.as_f64()?;
            Some(QuotaWindow {
                label,
                remaining_percent,
            })
        })
        .collect()
}

fn parse_primary_secondary_windows(rate_limits_node: &serde_json::Value) -> Vec<QuotaWindow> {
    ["primary", "secondary"]
        .iter()
        .filter_map(|key| rate_limits_node.get(key))
        .filter(|window| !window.is_null())
        .filter_map(|window| {
            let used_percent = window.get("usedPercent")?.as_f64()?;
            let remaining_percent = (100.0 - used_percent).clamp(0.0, 100.0);
            Some(QuotaWindow {
                label: quota_window_label(
                    window
                        .get("windowDurationMins")
                        .and_then(|value| value.as_i64()),
                ),
                remaining_percent,
            })
        })
        .collect()
}

fn quota_window_label(duration_mins: Option<i64>) -> String {
    let Some(duration_mins) = duration_mins.filter(|value| *value > 0) else {
        return "quota".to_string();
    };

    if duration_mins % 10_080 == 0 {
        format!("{}w", duration_mins / 10_080)
    } else if duration_mins % 1_440 == 0 {
        format!("{}d", duration_mins / 1_440)
    } else if duration_mins % 60 == 0 {
        format!("{}h", duration_mins / 60)
    } else {
        format!("{duration_mins}m")
    }
}

fn fetch_current_quota_blocking(
    codex_home: PathBuf,
    timeout_duration: Duration,
) -> Result<QuotaSnapshot, AppError> {
    let deadline = Instant::now() + timeout_duration;
    let mut child = codex_command(&codex_home)?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| AppError::QuotaRefreshFailed("codex stdin unavailable".to_string()))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| AppError::QuotaRefreshFailed("codex stdout unavailable".to_string()))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| AppError::QuotaRefreshFailed("codex stderr unavailable".to_string()))?;

    let (line_sender, line_receiver) = mpsc::channel();
    let stdout_thread = thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            if line_sender.send(line).is_err() {
                break;
            }
        }
    });

    let stderr_thread = thread::spawn(move || {
        let mut stderr_text = String::new();
        let mut reader = BufReader::new(stderr);
        let _ = reader.read_to_string(&mut stderr_text);
        stderr_text
    });

    let result = read_quota_from_rpc(&mut stdin, &line_receiver, deadline);
    let _ = child.kill();
    let _ = child.wait();
    let _ = stdout_thread.join();
    let stderr_text = stderr_thread.join().unwrap_or_default();

    match result {
        Err(AppError::QuotaRefreshFailed(message)) if !stderr_text.trim().is_empty() => {
            Err(AppError::QuotaRefreshFailed(format!(
                "{message}: {}",
                stderr_text.trim()
            )))
        }
        other => other,
    }
}

fn codex_command(codex_home: &Path) -> Result<Child, AppError> {
    Command::new("codex")
        .args(["-s", "read-only", "-a", "untrusted", "app-server"])
        .env("CODEX_HOME", codex_home)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| AppError::QuotaRefreshFailed(error.to_string()))
}

fn read_quota_from_rpc(
    stdin: &mut ChildStdin,
    line_receiver: &mpsc::Receiver<std::io::Result<String>>,
    deadline: Instant,
) -> Result<QuotaSnapshot, AppError> {
    send_rpc_line(
        stdin,
        "1",
        "initialize",
        serde_json::json!({
            "clientInfo": {
                "name": "codex-quota-viewer-windows-tray",
                "version": env!("CARGO_PKG_VERSION")
            },
            "protocolVersion": 2
        }),
    )?;
    read_rpc_response(line_receiver, "1", deadline)?;

    send_rpc_line(stdin, "2", "account/read", serde_json::json!({}))?;
    let account = read_rpc_response(line_receiver, "2", deadline)?;

    if account
        .get("account")
        .and_then(|value| value.get("type"))
        .and_then(|value| value.as_str())
        == Some("apiKey")
    {
        return parse_snapshot_from_rpc_values(
            account,
            serde_json::json!({ "rateLimits": { "windows": [] } }),
        );
    }

    send_rpc_line(
        stdin,
        "3",
        "account/rateLimits/read",
        serde_json::json!({}),
    )?;
    let rate_limits = read_rpc_response(line_receiver, "3", deadline)?;

    parse_snapshot_from_rpc_values(account, rate_limits)
}

fn send_rpc_line(
    stdin: &mut ChildStdin,
    id: &str,
    method: &str,
    params: serde_json::Value,
) -> Result<(), AppError> {
    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": params
    });
    let mut line = serde_json::to_vec(&body)
        .map_err(|error| AppError::QuotaRefreshFailed(error.to_string()))?;
    line.push(b'\n');
    stdin
        .write_all(&line)
        .map_err(|error| AppError::QuotaRefreshFailed(error.to_string()))
}

fn read_rpc_response(
    line_receiver: &mpsc::Receiver<std::io::Result<String>>,
    request_id: &str,
    deadline: Instant,
) -> Result<serde_json::Value, AppError> {
    loop {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or(AppError::QuotaTimeout)?;
        let line = line_receiver
            .recv_timeout(remaining)
            .map_err(|error| match error {
                mpsc::RecvTimeoutError::Timeout => AppError::QuotaTimeout,
                mpsc::RecvTimeoutError::Disconnected => AppError::QuotaRefreshFailed(
                    "codex app-server exited before quota was read".to_string(),
                ),
            })?
            .map_err(|error| AppError::QuotaRefreshFailed(error.to_string()))?;

        if line.trim().is_empty() {
            continue;
        }

        let message: serde_json::Value = serde_json::from_str(&line)
            .map_err(|error| AppError::QuotaRefreshFailed(error.to_string()))?;

        if let Some(error) = message.get("error") {
            let code = error
                .get("code")
                .and_then(|value| value.as_i64())
                .unwrap_or_default();
            if code == -32600 {
                return Err(AppError::SignInRequired);
            }
            return Err(AppError::QuotaRefreshFailed(error.to_string()));
        }

        if message.get("id").and_then(|value| value.as_str()) == Some(request_id) {
            return message
                .get("result")
                .cloned()
                .ok_or_else(|| AppError::QuotaRefreshFailed(format!("{request_id} missing result")));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_five_hour_and_weekly_windows() {
        let snapshot = parse_snapshot_from_rpc_values(
            json!({
                "account": {
                    "id": "acct_123",
                    "email": "ada@example.com",
                    "type": "chatgpt"
                }
            }),
            json!({
                "rateLimits": {
                    "windows": [
                        { "label": "5h", "remainingPercent": 42.5 },
                        { "label": "1w", "remainingPercent": 88.0 }
                    ]
                }
            }),
        )
        .unwrap();

        assert_eq!(snapshot.account.email.as_deref(), Some("ada@example.com"));
        assert_eq!(snapshot.windows[0].label, "5h");
        assert_eq!(snapshot.windows[0].remaining_percent, 42.5);
        assert_eq!(snapshot.windows[1].label, "1w");
    }

    #[test]
    fn parses_primary_and_secondary_windows() {
        let snapshot = parse_snapshot_from_rpc_values(
            json!({
                "account": {
                    "email": "ada@example.com",
                    "type": "chatgpt"
                }
            }),
            json!({
                "rateLimits": {
                    "primary": { "usedPercent": 57.5, "windowDurationMins": 300 },
                    "secondary": { "usedPercent": 12.0, "windowDurationMins": 10080 }
                }
            }),
        )
        .unwrap();

        assert_eq!(snapshot.windows[0].label, "5h");
        assert_eq!(snapshot.windows[0].remaining_percent, 42.5);
        assert_eq!(snapshot.windows[1].label, "1w");
        assert_eq!(snapshot.windows[1].remaining_percent, 88.0);
    }

    #[test]
    fn reports_sign_in_required_when_account_is_null() {
        let error = parse_snapshot_from_rpc_values(
            json!({ "account": null }),
            json!({ "rateLimits": { "windows": [] } }),
        )
        .unwrap_err();

        assert_eq!(error, AppError::SignInRequired);
    }
}
