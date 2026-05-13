use tauri::async_runtime::JoinHandle;

use crate::settings::RefreshIntervalPreset;

#[derive(Default)]
pub struct RefreshScheduler {
    handle: Option<JoinHandle<()>>,
}

impl RefreshScheduler {
    pub fn new() -> Self {
        Self { handle: None }
    }

    pub fn is_running(&self) -> bool {
        self.handle.is_some()
    }

    pub fn stop(&mut self) {
        if let Some(handle) = self.handle.take() {
            handle.abort();
        }
    }

    pub fn replace_with(&mut self, handle: Option<JoinHandle<()>>) {
        self.stop();
        self.handle = handle;
    }
}

pub fn should_schedule_refresh(preset: RefreshIntervalPreset) -> bool {
    preset.interval().is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manual_does_not_schedule() {
        assert!(!should_schedule_refresh(RefreshIntervalPreset::Manual));
    }

    #[test]
    fn timed_presets_schedule() {
        assert!(should_schedule_refresh(RefreshIntervalPreset::OneMinute));
        assert!(should_schedule_refresh(RefreshIntervalPreset::FiveMinutes));
        assert!(should_schedule_refresh(
            RefreshIntervalPreset::FifteenMinutes
        ));
    }
}
