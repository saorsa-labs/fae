//! Production host command handler for the embedded Fae runtime.

use crate::config::SpeechConfig;
use crate::error::{Result, SpeechError};
use crate::host::channel::{DeviceTarget, DeviceTransferHandler};
use crate::onboarding::OnboardingPhase;
use crate::permissions::PermissionKind;
use std::path::PathBuf;
use std::sync::Mutex;
use tracing::info;

/// Production device transfer handler that persists permission grants and
/// onboarding state to `config.toml`.
///
/// Commands that require deeper pipeline integration (text injection, gate
/// control, scheduler CRUD) are logged and acknowledged; channel-based
/// forwarding to the `PipelineCoordinator` will be wired in a future phase.
pub struct FaeDeviceTransferHandler {
    config: Mutex<SpeechConfig>,
    config_path: PathBuf,
}

impl std::fmt::Debug for FaeDeviceTransferHandler {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FaeDeviceTransferHandler")
            .field("config_path", &self.config_path)
            .finish()
    }
}

impl FaeDeviceTransferHandler {
    /// Create a handler that reads/writes config at the given path.
    pub fn new(config: SpeechConfig, config_path: PathBuf) -> Self {
        Self {
            config: Mutex::new(config),
            config_path,
        }
    }

    /// Create a handler using the default config path.
    pub fn from_default_path() -> Result<Self> {
        let path = SpeechConfig::default_config_path();
        let config = if path.is_file() {
            SpeechConfig::from_file(&path)?
        } else {
            SpeechConfig::default()
        };
        Ok(Self::new(config, path))
    }

    /// Save the current config to disk.
    fn save_config(&self) -> Result<()> {
        let guard = self.lock_config()?;
        guard.save_to_file(&self.config_path)
    }

    /// Acquire a lock on the mutable config, mapping a poisoned mutex to a
    /// `SpeechError::Config`.
    fn lock_config(&self) -> Result<std::sync::MutexGuard<'_, SpeechConfig>> {
        self.config
            .lock()
            .map_err(|e| SpeechError::Config(format!("config lock poisoned: {e}")))
    }

    /// Parse a capability string to a `PermissionKind`.
    fn parse_permission(capability: &str) -> Result<PermissionKind> {
        capability.parse::<PermissionKind>().map_err(|_| {
            SpeechError::Pipeline(format!(
                "unknown capability `{capability}`; expected one of: {}",
                PermissionKind::all()
                    .iter()
                    .map(|k| k.to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            ))
        })
    }
}

impl DeviceTransferHandler for FaeDeviceTransferHandler {
    fn request_move(&self, target: DeviceTarget) -> Result<()> {
        info!(target = target.as_str(), "device.move requested");
        Ok(())
    }

    fn request_go_home(&self) -> Result<()> {
        info!("device.go_home requested");
        Ok(())
    }

    fn request_orb_palette_set(&self, palette: &str) -> Result<()> {
        info!(palette, "orb.palette.set requested");
        Ok(())
    }

    fn request_orb_palette_clear(&self) -> Result<()> {
        info!("orb.palette.clear requested");
        Ok(())
    }

    fn request_orb_feeling_set(&self, feeling: &str) -> Result<()> {
        info!(feeling, "orb.feeling.set requested");
        Ok(())
    }

    fn request_orb_urgency_set(&self, urgency: f32) -> Result<()> {
        info!(urgency, "orb.urgency.set requested");
        Ok(())
    }

    fn request_orb_flash(&self, flash_type: &str) -> Result<()> {
        info!(flash_type, "orb.flash requested");
        Ok(())
    }

    fn request_capability(
        &self,
        capability: &str,
        reason: &str,
        scope: Option<&str>,
    ) -> Result<()> {
        info!(capability, reason, ?scope, "capability.request received");
        // Validate the capability is known (fail early on typos).
        let _kind = Self::parse_permission(capability)?;
        Ok(())
    }

    fn grant_capability(&self, capability: &str, scope: Option<&str>) -> Result<()> {
        let kind = Self::parse_permission(capability)?;
        info!(%kind, ?scope, "capability.grant — persisting");

        let mut guard = self.lock_config()?;
        guard.permissions.grant(kind);
        drop(guard);

        self.save_config()?;
        info!(%kind, "capability.grant persisted to config");
        Ok(())
    }

    fn deny_capability(&self, capability: &str, scope: Option<&str>) -> Result<()> {
        let kind = Self::parse_permission(capability)?;
        info!(%kind, ?scope, "capability.deny — persisting");

        let mut guard = self.lock_config()?;
        guard.permissions.deny(kind);
        drop(guard);

        self.save_config()?;
        info!(%kind, "capability.deny persisted to config");
        Ok(())
    }

    fn query_onboarding_state(&self) -> Result<serde_json::Value> {
        let guard = self.lock_config()?;
        let onboarded = guard.onboarded;
        let phase = guard.onboarding_phase;
        let granted: Vec<String> = guard
            .permissions
            .all_granted()
            .iter()
            .map(|k| k.to_string())
            .collect();
        Ok(serde_json::json!({
            "onboarded": onboarded,
            "phase": phase.as_str(),
            "granted_permissions": granted
        }))
    }

    fn advance_onboarding_phase(&self) -> Result<OnboardingPhase> {
        let mut guard = self.lock_config()?;
        let current = guard.onboarding_phase;
        let new_phase = current.advance().unwrap_or(current);
        guard.onboarding_phase = new_phase;
        drop(guard);

        self.save_config()?;
        info!(phase = new_phase.as_str(), "onboarding.advance persisted to config");
        Ok(new_phase)
    }

    fn complete_onboarding(&self) -> Result<()> {
        info!("onboarding.complete — setting onboarded = true");

        let mut guard = self.lock_config()?;
        guard.onboarded = true;
        drop(guard);

        self.save_config()?;
        info!("onboarding.complete persisted to config");
        Ok(())
    }

    fn request_conversation_inject_text(&self, text: &str) -> Result<()> {
        info!(text, "conversation.inject_text requested");
        Ok(())
    }

    fn request_conversation_gate_set(&self, active: bool) -> Result<()> {
        info!(active, "conversation.gate_set requested");
        Ok(())
    }

    fn request_runtime_start(&self) -> Result<()> {
        info!("runtime.start requested");
        Ok(())
    }

    fn request_runtime_stop(&self) -> Result<()> {
        info!("runtime.stop requested");
        Ok(())
    }

    fn query_runtime_status(&self) -> Result<serde_json::Value> {
        info!("runtime.status queried");
        Ok(serde_json::json!({"status": "running"}))
    }

    fn request_approval_respond(
        &self,
        request_id: &str,
        approved: bool,
        reason: Option<&str>,
    ) -> Result<()> {
        info!(request_id, approved, ?reason, "approval.respond received");
        Ok(())
    }

    fn query_scheduler_list(&self) -> Result<serde_json::Value> {
        info!("scheduler.list queried");
        Ok(serde_json::json!({"tasks": []}))
    }

    fn request_scheduler_create(&self, spec: &serde_json::Value) -> Result<serde_json::Value> {
        info!(?spec, "scheduler.create requested");
        Ok(serde_json::json!({"id": null}))
    }

    fn request_scheduler_update(&self, id: &str, spec: &serde_json::Value) -> Result<()> {
        info!(id, ?spec, "scheduler.update requested");
        Ok(())
    }

    fn request_scheduler_delete(&self, id: &str) -> Result<()> {
        info!(id, "scheduler.delete requested");
        Ok(())
    }

    fn request_scheduler_trigger_now(&self, id: &str) -> Result<()> {
        info!(id, "scheduler.trigger_now requested");
        Ok(())
    }

    fn query_config_get(&self, key: Option<&str>) -> Result<serde_json::Value> {
        info!(?key, "config.get queried");
        let guard = self.lock_config()?;
        // Return the full permissions state when key is "permissions" or None.
        match key {
            Some("permissions") => {
                let granted: Vec<String> = guard
                    .permissions
                    .all_granted()
                    .iter()
                    .map(|k| k.to_string())
                    .collect();
                Ok(serde_json::json!({"permissions": granted}))
            }
            Some("onboarded") => Ok(serde_json::json!({"onboarded": guard.onboarded})),
            _ => Ok(serde_json::json!({})),
        }
    }

    fn request_config_patch(&self, key: &str, value: &serde_json::Value) -> Result<()> {
        info!(key, ?value, "config.patch requested");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    fn temp_handler() -> (FaeDeviceTransferHandler, tempfile::TempDir) {
        let dir = tempfile::tempdir().expect("create temp dir");
        let path = dir.path().join("config.toml");
        let config = SpeechConfig::default();
        let handler = FaeDeviceTransferHandler::new(config, path);
        (handler, dir)
    }

    #[test]
    fn grant_capability_persists_to_config() {
        let (handler, _dir) = temp_handler();

        handler.grant_capability("calendar", None).unwrap();

        let guard = handler.config.lock().unwrap();
        assert!(guard.permissions.is_granted(PermissionKind::Calendar));
    }

    #[test]
    fn deny_capability_revokes_permission() {
        let (handler, _dir) = temp_handler();

        handler.grant_capability("contacts", None).unwrap();
        handler.deny_capability("contacts", None).unwrap();

        let guard = handler.config.lock().unwrap();
        assert!(!guard.permissions.is_granted(PermissionKind::Contacts));
    }

    #[test]
    fn unknown_capability_returns_error() {
        let (handler, _dir) = temp_handler();

        let result = handler.grant_capability("teleportation", None);
        assert!(result.is_err());
    }

    #[test]
    fn onboarding_state_default_false() {
        let (handler, _dir) = temp_handler();

        let state = handler.query_onboarding_state().unwrap();
        assert_eq!(state["onboarded"], false);
        assert!(state["granted_permissions"].as_array().unwrap().is_empty());
    }

    #[test]
    fn complete_onboarding_sets_flag() {
        let (handler, _dir) = temp_handler();

        handler.complete_onboarding().unwrap();

        let guard = handler.config.lock().unwrap();
        assert!(guard.onboarded);
    }

    #[test]
    fn grant_capability_saves_to_disk() {
        let (handler, dir) = temp_handler();
        let path = dir.path().join("config.toml");

        handler.grant_capability("mail", None).unwrap();

        // Read from disk and verify
        let loaded = SpeechConfig::from_file(&path).unwrap();
        assert!(loaded.permissions.is_granted(PermissionKind::Mail));
    }

    #[test]
    fn complete_onboarding_saves_to_disk() {
        let (handler, dir) = temp_handler();
        let path = dir.path().join("config.toml");

        handler.complete_onboarding().unwrap();

        let loaded = SpeechConfig::from_file(&path).unwrap();
        assert!(loaded.onboarded);
    }

    #[test]
    fn request_capability_validates_known_capability() {
        let (handler, _dir) = temp_handler();

        // Known capability should succeed
        assert!(
            handler
                .request_capability("microphone", "need to listen", None)
                .is_ok()
        );

        // Unknown capability should fail
        assert!(
            handler
                .request_capability("xray_vision", "seeing through walls", None)
                .is_err()
        );
    }

    #[test]
    fn config_get_permissions_returns_granted() {
        let (handler, _dir) = temp_handler();

        handler.grant_capability("files", None).unwrap();
        handler.grant_capability("location", None).unwrap();

        let result = handler.query_config_get(Some("permissions")).unwrap();
        let perms = result["permissions"].as_array().unwrap();
        assert_eq!(perms.len(), 2);
    }

    #[test]
    fn onboarding_state_includes_granted_permissions() {
        let (handler, _dir) = temp_handler();

        handler.grant_capability("calendar", None).unwrap();
        handler.grant_capability("reminders", None).unwrap();

        let state = handler.query_onboarding_state().unwrap();
        assert_eq!(state["onboarded"], false);
        let granted = state["granted_permissions"].as_array().unwrap();
        assert_eq!(granted.len(), 2);
    }

    #[test]
    fn query_onboarding_state_includes_phase_field() {
        let (handler, _dir) = temp_handler();

        let state = handler.query_onboarding_state().unwrap();
        // Default phase is Welcome
        assert_eq!(state["phase"], "welcome");
    }

    #[test]
    fn advance_onboarding_phase_cycles_through_phases() {
        let (handler, _dir) = temp_handler();

        // Welcome → Permissions
        let p1 = handler.advance_onboarding_phase().unwrap();
        assert_eq!(p1.as_str(), "permissions");

        // Permissions → Ready
        let p2 = handler.advance_onboarding_phase().unwrap();
        assert_eq!(p2.as_str(), "ready");

        // Ready → Complete
        let p3 = handler.advance_onboarding_phase().unwrap();
        assert_eq!(p3.as_str(), "complete");

        // Complete stays at Complete (no further advance)
        let p4 = handler.advance_onboarding_phase().unwrap();
        assert_eq!(p4.as_str(), "complete");
    }

    #[test]
    fn advance_onboarding_phase_persists_to_disk() {
        let (handler, dir) = temp_handler();
        let path = dir.path().join("config.toml");

        handler.advance_onboarding_phase().unwrap();

        let loaded = SpeechConfig::from_file(&path).unwrap();
        // Should have advanced from Welcome to Permissions
        assert_eq!(loaded.onboarding_phase.as_str(), "permissions");
    }
}
