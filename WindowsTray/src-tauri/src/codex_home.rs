use std::path::{Path, PathBuf};

use crate::errors::AppError;

pub fn resolve_codex_home() -> Result<PathBuf, AppError> {
    resolve_codex_home_from_env(&|key| std::env::var(key).ok())
}

pub fn resolve_codex_home_from_env(env: &dyn Fn(&str) -> Option<String>) -> Result<PathBuf, AppError> {
    if let Some(explicit) = env("CODEX_HOME").filter(|value| !value.trim().is_empty()) {
        return Ok(PathBuf::from(explicit));
    }

    let user_profile = env("USERPROFILE")
        .filter(|value| !value.trim().is_empty())
        .ok_or(AppError::CodexFolderNotFound)?;

    Ok(Path::new(&user_profile).join(".codex"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn env_from(values: HashMap<&str, &str>) -> impl Fn(&str) -> Option<String> {
        move |key| values.get(key).map(|value| value.to_string())
    }

    #[test]
    fn uses_explicit_codex_home_when_present() {
        let mut values = HashMap::new();
        values.insert("CODEX_HOME", r"C:\CodexHome");
        values.insert("USERPROFILE", r"C:\Users\Ada");

        let home = resolve_codex_home_from_env(&env_from(values)).unwrap();

        assert_eq!(home, Path::new(r"C:\CodexHome"));
    }

    #[test]
    fn falls_back_to_userprofile_dot_codex() {
        let mut values = HashMap::new();
        values.insert("USERPROFILE", r"C:\Users\Ada");

        let home = resolve_codex_home_from_env(&env_from(values)).unwrap();

        assert_eq!(home, Path::new(r"C:\Users\Ada\.codex"));
    }

    #[test]
    fn reports_missing_userprofile() {
        let values = HashMap::new();

        let error = resolve_codex_home_from_env(&env_from(values)).unwrap_err();

        assert_eq!(error.user_message(), "Codex folder not found");
    }
}
