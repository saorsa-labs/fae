//! Production host command handler for the embedded Fae runtime.

use crate::error::Result;
use crate::host::channel::{DeviceTarget, DeviceTransferHandler};
use tracing::info;

/// Production device transfer handler that logs all commands.
///
/// Replaces `NoopDeviceTransferHandler` in the FFI layer. Commands that
/// require deeper pipeline integration (text injection, gate control,
/// scheduler CRUD) are logged and acknowledged; channel-based forwarding
/// to the `PipelineCoordinator` will be wired in a future phase.
#[derive(Debug)]
pub struct FaeDeviceTransferHandler;

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
        Ok(())
    }

    fn grant_capability(&self, capability: &str, scope: Option<&str>) -> Result<()> {
        info!(capability, ?scope, "capability.grant received");
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
        Ok(serde_json::json!({}))
    }

    fn request_config_patch(&self, key: &str, value: &serde_json::Value) -> Result<()> {
        info!(key, ?value, "config.patch requested");
        Ok(())
    }
}
