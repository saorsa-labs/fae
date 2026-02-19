//! Host command channel and router for native shell integrations.

use crate::error::{Result, SpeechError};
use crate::host::contract::{CommandEnvelope, CommandName, EventEnvelope, ResponseEnvelope};
use crate::onboarding::OnboardingPhase;
use serde::{Deserialize, Serialize};
use tokio::sync::{broadcast, mpsc, oneshot};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeviceTarget {
    Mac,
    Iphone,
    Watch,
}

impl DeviceTarget {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Mac => "mac",
            Self::Iphone => "iphone",
            Self::Watch => "watch",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "mac" | "home" => Some(Self::Mac),
            "iphone" | "phone" => Some(Self::Iphone),
            "watch" => Some(Self::Watch),
            _ => None,
        }
    }
}

pub trait DeviceTransferHandler: Send + Sync + 'static {
    fn request_move(&self, target: DeviceTarget) -> Result<()>;
    fn request_go_home(&self) -> Result<()>;
    fn request_orb_palette_set(&self, _palette: &str) -> Result<()> {
        Ok(())
    }
    fn request_orb_palette_clear(&self) -> Result<()> {
        Ok(())
    }
    fn request_orb_feeling_set(&self, _feeling: &str) -> Result<()> {
        Ok(())
    }
    fn request_orb_urgency_set(&self, _urgency: f32) -> Result<()> {
        Ok(())
    }
    fn request_orb_flash(&self, _flash_type: &str) -> Result<()> {
        Ok(())
    }
    fn request_capability(
        &self,
        _capability: &str,
        _reason: &str,
        _scope: Option<&str>,
    ) -> Result<()> {
        Ok(())
    }
    fn grant_capability(&self, _capability: &str, _scope: Option<&str>) -> Result<()> {
        Ok(())
    }
    /// Deny (revoke) a previously granted capability, persisting to config.
    fn deny_capability(&self, _capability: &str, _scope: Option<&str>) -> Result<()> {
        Ok(())
    }
    /// Query the current onboarding state (onboarded flag + current phase).
    fn query_onboarding_state(&self) -> Result<serde_json::Value> {
        Ok(serde_json::json!({"onboarded": false, "phase": "welcome"}))
    }
    /// Advance the onboarding phase by one step.
    ///
    /// Returns the new phase after advancing. Returns the current phase
    /// unchanged if already at `Complete`.
    fn advance_onboarding_phase(&self) -> Result<OnboardingPhase> {
        Ok(OnboardingPhase::Welcome)
    }
    /// Mark onboarding as complete, persisting to config.
    fn complete_onboarding(&self) -> Result<()> {
        Ok(())
    }
    fn request_conversation_inject_text(&self, _text: &str) -> Result<()> {
        Ok(())
    }
    fn request_conversation_gate_set(&self, _active: bool) -> Result<()> {
        Ok(())
    }
    fn request_conversation_link_detected(&self, _url: &str) -> Result<()> {
        Ok(())
    }
    fn request_runtime_start(&self) -> Result<()> {
        Ok(())
    }
    fn request_runtime_stop(&self) -> Result<()> {
        Ok(())
    }
    fn query_runtime_status(&self) -> Result<serde_json::Value> {
        Ok(serde_json::json!({"status": "unknown"}))
    }
    fn request_approval_respond(
        &self,
        _request_id: &str,
        _approved: bool,
        _reason: Option<&str>,
    ) -> Result<()> {
        Ok(())
    }
    fn query_scheduler_list(&self) -> Result<serde_json::Value> {
        Ok(serde_json::json!({"tasks": []}))
    }
    fn request_scheduler_create(&self, _spec: &serde_json::Value) -> Result<serde_json::Value> {
        Ok(serde_json::json!({"id": null}))
    }
    fn request_scheduler_update(&self, _id: &str, _spec: &serde_json::Value) -> Result<()> {
        Ok(())
    }
    fn request_scheduler_delete(&self, _id: &str) -> Result<()> {
        Ok(())
    }
    fn request_scheduler_trigger_now(&self, _id: &str) -> Result<()> {
        Ok(())
    }
    fn query_config_get(&self, _key: Option<&str>) -> Result<serde_json::Value> {
        Ok(serde_json::json!({}))
    }
    fn request_config_patch(&self, _key: &str, _value: &serde_json::Value) -> Result<()> {
        Ok(())
    }
}

#[derive(Debug, Default)]
pub struct NoopDeviceTransferHandler;

impl DeviceTransferHandler for NoopDeviceTransferHandler {
    fn request_move(&self, _target: DeviceTarget) -> Result<()> {
        Ok(())
    }

    fn request_go_home(&self) -> Result<()> {
        Ok(())
    }
}

struct HostCommandRequest {
    envelope: CommandEnvelope,
    response_tx: oneshot::Sender<Result<ResponseEnvelope>>,
}

#[derive(Clone)]
pub struct HostCommandClient {
    request_tx: mpsc::Sender<HostCommandRequest>,
    event_tx: broadcast::Sender<EventEnvelope>,
}

impl HostCommandClient {
    pub async fn send(&self, envelope: CommandEnvelope) -> Result<ResponseEnvelope> {
        envelope.validate().map_err(|e| {
            SpeechError::Pipeline(format!(
                "invalid host command envelope {}: {}",
                envelope.request_id, e
            ))
        })?;

        let (response_tx, response_rx) = oneshot::channel();
        self.request_tx
            .send(HostCommandRequest {
                envelope,
                response_tx,
            })
            .await
            .map_err(|e| {
                SpeechError::Channel(format!("failed to send host command request: {e}"))
            })?;

        response_rx
            .await
            .map_err(|e| SpeechError::Channel(format!("host command response dropped: {e}")))?
    }

    #[must_use]
    pub fn subscribe_events(&self) -> broadcast::Receiver<EventEnvelope> {
        self.event_tx.subscribe()
    }
}

pub struct HostCommandServer<H: DeviceTransferHandler> {
    request_rx: mpsc::Receiver<HostCommandRequest>,
    event_tx: broadcast::Sender<EventEnvelope>,
    handler: H,
}

#[must_use]
pub fn command_channel<H: DeviceTransferHandler>(
    request_capacity: usize,
    event_capacity: usize,
    handler: H,
) -> (HostCommandClient, HostCommandServer<H>) {
    let (event_tx, _event_rx) = broadcast::channel(event_capacity.max(1));
    command_channel_with_events(request_capacity, event_tx, handler)
}

/// Create a command channel using an existing event broadcast sender.
///
/// This allows the handler and the command server to share the same
/// broadcast channel, so events emitted directly by the handler (e.g.
/// pipeline lifecycle events) reach Swift through the same path.
#[must_use]
pub fn command_channel_with_events<H: DeviceTransferHandler>(
    request_capacity: usize,
    event_tx: broadcast::Sender<EventEnvelope>,
    handler: H,
) -> (HostCommandClient, HostCommandServer<H>) {
    let (request_tx, request_rx) = mpsc::channel(request_capacity.max(1));

    (
        HostCommandClient {
            request_tx,
            event_tx: event_tx.clone(),
        },
        HostCommandServer {
            request_rx,
            event_tx,
            handler,
        },
    )
}

impl<H: DeviceTransferHandler> HostCommandServer<H> {
    pub async fn run(mut self) {
        while let Some(request) = self.request_rx.recv().await {
            let response = self.route(&request.envelope);
            let _ = request.response_tx.send(response);
        }
    }

    /// Route a command envelope to the appropriate handler.
    pub fn route(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        match envelope.command {
            CommandName::HostPing => Ok(ResponseEnvelope::ok(
                envelope.request_id.clone(),
                serde_json::json!({"pong": true}),
            )),
            CommandName::HostVersion => Ok(ResponseEnvelope::ok(
                envelope.request_id.clone(),
                serde_json::json!({
                    "contract_version": crate::host::contract::EVENT_VERSION,
                    "channel": "host_command_v0"
                }),
            )),
            CommandName::DeviceMove => self.handle_device_move(envelope),
            CommandName::DeviceGoHome => self.handle_device_go_home(envelope),
            CommandName::OrbPaletteSet => self.handle_orb_palette_set(envelope),
            CommandName::OrbPaletteClear => self.handle_orb_palette_clear(envelope),
            CommandName::OrbFeelingSet => self.handle_orb_feeling_set(envelope),
            CommandName::OrbUrgencySet => self.handle_orb_urgency_set(envelope),
            CommandName::OrbFlash => self.handle_orb_flash(envelope),
            CommandName::CapabilityRequest => self.handle_capability_request(envelope),
            CommandName::CapabilityGrant => self.handle_capability_grant(envelope),
            CommandName::CapabilityDeny => self.handle_capability_deny(envelope),
            CommandName::OnboardingGetState => self.handle_onboarding_get_state(envelope),
            CommandName::OnboardingAdvance => self.handle_onboarding_advance(envelope),
            CommandName::OnboardingComplete => self.handle_onboarding_complete(envelope),
            CommandName::ConversationInjectText => self.handle_conversation_inject_text(envelope),
            CommandName::ConversationGateSet => self.handle_conversation_gate_set(envelope),
            CommandName::ConversationLinkDetected => {
                self.handle_conversation_link_detected(envelope)
            }
            CommandName::RuntimeStart => self.handle_runtime_start(envelope),
            CommandName::RuntimeStop => self.handle_runtime_stop(envelope),
            CommandName::RuntimeStatus => self.handle_runtime_status(envelope),
            CommandName::ApprovalRespond => self.handle_approval_respond(envelope),
            CommandName::SchedulerList => self.handle_scheduler_list(envelope),
            CommandName::SchedulerCreate => self.handle_scheduler_create(envelope),
            CommandName::SchedulerUpdate => self.handle_scheduler_update(envelope),
            CommandName::SchedulerDelete => self.handle_scheduler_delete(envelope),
            CommandName::SchedulerTriggerNow => self.handle_scheduler_trigger_now(envelope),
            CommandName::ConfigGet => self.handle_config_get(envelope),
            CommandName::ConfigPatch => self.handle_config_patch(envelope),
        }
    }

    fn handle_device_move(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        let target = parse_device_target(&envelope.payload)?;
        self.handler.request_move(target)?;

        self.emit_event(
            "device.transfer_requested",
            serde_json::json!({
                "request_id": envelope.request_id,
                "target": target.as_str()
            }),
        );

        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({
                "accepted": true,
                "target": target.as_str()
            }),
        ))
    }

    fn handle_device_go_home(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        self.handler.request_go_home()?;

        self.emit_event(
            "device.home_requested",
            serde_json::json!({
                "request_id": envelope.request_id,
                "target": "mac"
            }),
        );

        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({"accepted": true, "target": "mac"}),
        ))
    }

    fn handle_orb_palette_set(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        let palette = parse_orb_palette(&envelope.payload)?;
        self.handler.request_orb_palette_set(&palette)?;

        self.emit_event(
            "orb.palette_set_requested",
            serde_json::json!({
                "request_id": envelope.request_id,
                "palette": palette
            }),
        );

        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({
                "accepted": true,
                "palette": palette
            }),
        ))
    }

    fn handle_orb_palette_clear(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        self.handler.request_orb_palette_clear()?;

        self.emit_event(
            "orb.palette_cleared",
            serde_json::json!({
                "request_id": envelope.request_id
            }),
        );

        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({"accepted": true}),
        ))
    }

    fn handle_orb_feeling_set(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        let feeling = parse_orb_feeling(&envelope.payload)?;
        self.handler.request_orb_feeling_set(&feeling)?;

        self.emit_event(
            "orb.feeling_set_requested",
            serde_json::json!({
                "request_id": envelope.request_id,
                "feeling": feeling
            }),
        );

        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({
                "accepted": true,
                "feeling": feeling
            }),
        ))
    }

    fn handle_orb_urgency_set(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        let urgency = parse_orb_urgency(&envelope.payload)?;
        self.handler.request_orb_urgency_set(urgency)?;

        self.emit_event(
            "orb.urgency_set_requested",
            serde_json::json!({
                "request_id": envelope.request_id,
                "urgency": urgency
            }),
        );

        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({
                "accepted": true,
                "urgency": urgency
            }),
        ))
    }

    fn handle_orb_flash(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        let flash_type = parse_orb_flash(&envelope.payload)?;
        self.handler.request_orb_flash(&flash_type)?;

        self.emit_event(
            "orb.flash_requested",
            serde_json::json!({
                "request_id": envelope.request_id,
                "flash_type": flash_type
            }),
        );

        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({
                "accepted": true,
                "flash_type": flash_type
            }),
        ))
    }

    fn handle_capability_request(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        let request = parse_capability_request(&envelope.payload)?;
        self.handler.request_capability(
            &request.capability,
            &request.reason,
            request.scope.as_deref(),
        )?;

        self.emit_event(
            "capability.requested",
            serde_json::json!({
                "request_id": envelope.request_id,
                "capability": request.capability,
                "scope": request.scope,
                "reason": request.reason,
                "jit": request.jit,
                "tool_name": request.tool_name,
                "tool_action": request.tool_action,
            }),
        );

        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({
                "accepted": true,
                "capability": request.capability,
                "scope": request.scope
            }),
        ))
    }

    fn handle_capability_grant(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        let grant = parse_capability_action(&envelope.payload, "capability.grant")?;
        self.handler
            .grant_capability(&grant.capability, grant.scope.as_deref())?;

        self.emit_event(
            "capability.granted",
            serde_json::json!({
                "request_id": envelope.request_id,
                "capability": grant.capability,
                "scope": grant.scope
            }),
        );

        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({
                "accepted": true,
                "capability": grant.capability,
                "scope": grant.scope
            }),
        ))
    }

    fn handle_capability_deny(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        let deny = parse_capability_action(&envelope.payload, "capability.deny")?;
        self.handler
            .deny_capability(&deny.capability, deny.scope.as_deref())?;

        self.emit_event(
            "capability.denied",
            serde_json::json!({
                "request_id": envelope.request_id,
                "capability": deny.capability,
                "scope": deny.scope
            }),
        );

        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({
                "accepted": true,
                "capability": deny.capability,
                "scope": deny.scope
            }),
        ))
    }

    fn handle_onboarding_get_state(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        let state = self.handler.query_onboarding_state()?;
        Ok(ResponseEnvelope::ok(envelope.request_id.clone(), state))
    }

    fn handle_onboarding_advance(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        let new_phase = self.handler.advance_onboarding_phase()?;

        self.emit_event(
            "onboarding.phase_advanced",
            serde_json::json!({
                "request_id": envelope.request_id,
                "phase": new_phase.as_str()
            }),
        );

        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({
                "accepted": true,
                "phase": new_phase.as_str()
            }),
        ))
    }

    fn handle_onboarding_complete(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        self.handler.complete_onboarding()?;

        self.emit_event(
            "onboarding.completed",
            serde_json::json!({
                "request_id": envelope.request_id
            }),
        );

        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({"accepted": true, "onboarded": true}),
        ))
    }

    fn handle_conversation_inject_text(
        &self,
        envelope: &CommandEnvelope,
    ) -> Result<ResponseEnvelope> {
        let text = parse_conversation_text(&envelope.payload)?;
        self.handler.request_conversation_inject_text(&text)?;

        self.emit_event(
            "conversation.text_injected",
            serde_json::json!({
                "request_id": envelope.request_id,
                "text": text
            }),
        );

        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({
                "accepted": true,
                "text": text
            }),
        ))
    }

    fn handle_conversation_link_detected(
        &self,
        envelope: &CommandEnvelope,
    ) -> Result<ResponseEnvelope> {
        let url = parse_conversation_url(&envelope.payload)?;
        self.handler.request_conversation_link_detected(&url)?;

        self.emit_event(
            "conversation.link_detected",
            serde_json::json!({
                "request_id": envelope.request_id,
                "url": url
            }),
        );

        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({
                "accepted": true,
                "url": url
            }),
        ))
    }

    fn handle_conversation_gate_set(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        let active = parse_gate_active(&envelope.payload)?;
        self.handler.request_conversation_gate_set(active)?;

        self.emit_event(
            "conversation.gate_set",
            serde_json::json!({
                "request_id": envelope.request_id,
                "active": active
            }),
        );

        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({
                "accepted": true,
                "active": active
            }),
        ))
    }

    fn handle_runtime_start(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        // The handler emits lifecycle events (runtime.starting, runtime.started)
        // directly — no additional event emission needed here.
        self.handler.request_runtime_start()?;
        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({"accepted": true}),
        ))
    }

    fn handle_runtime_stop(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        // The handler emits runtime.stopped directly.
        self.handler.request_runtime_stop()?;
        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({"accepted": true}),
        ))
    }

    fn handle_runtime_status(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        let status = self.handler.query_runtime_status()?;
        Ok(ResponseEnvelope::ok(envelope.request_id.clone(), status))
    }

    fn handle_approval_respond(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        let (req_id, approved, reason) = parse_approval_respond(&envelope.payload)?;
        self.handler
            .request_approval_respond(&req_id, approved, reason.as_deref())?;
        self.emit_event(
            "approval.responded",
            serde_json::json!({
                "request_id": envelope.request_id,
                "approval_request_id": req_id,
                "approved": approved
            }),
        );
        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({"accepted": true, "approved": approved}),
        ))
    }

    fn handle_scheduler_list(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        let list = self.handler.query_scheduler_list()?;
        Ok(ResponseEnvelope::ok(envelope.request_id.clone(), list))
    }

    fn handle_scheduler_create(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        let result = self.handler.request_scheduler_create(&envelope.payload)?;
        self.emit_event(
            "scheduler.created",
            serde_json::json!({
                "request_id": envelope.request_id,
                "result": result
            }),
        );
        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({"accepted": true, "result": result}),
        ))
    }

    fn handle_scheduler_update(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        let id = parse_scheduler_id(&envelope.payload)?;
        self.handler
            .request_scheduler_update(&id, &envelope.payload)?;
        self.emit_event(
            "scheduler.updated",
            serde_json::json!({"request_id": envelope.request_id, "id": id}),
        );
        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({"accepted": true, "id": id}),
        ))
    }

    fn handle_scheduler_delete(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        let id = parse_scheduler_id(&envelope.payload)?;
        self.handler.request_scheduler_delete(&id)?;
        self.emit_event(
            "scheduler.deleted",
            serde_json::json!({"request_id": envelope.request_id, "id": id}),
        );
        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({"accepted": true, "id": id}),
        ))
    }

    fn handle_scheduler_trigger_now(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        let id = parse_scheduler_id(&envelope.payload)?;
        self.handler.request_scheduler_trigger_now(&id)?;
        self.emit_event(
            "scheduler.triggered",
            serde_json::json!({"request_id": envelope.request_id, "id": id}),
        );
        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({"accepted": true, "id": id}),
        ))
    }

    fn handle_config_get(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        let key = envelope
            .payload
            .get("key")
            .and_then(serde_json::Value::as_str);
        let config = self.handler.query_config_get(key)?;
        Ok(ResponseEnvelope::ok(envelope.request_id.clone(), config))
    }

    fn handle_config_patch(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
        let (key, value) = parse_config_patch(&envelope.payload)?;
        self.handler.request_config_patch(&key, &value)?;
        self.emit_event(
            "config.patched",
            serde_json::json!({"request_id": envelope.request_id, "key": key}),
        );
        Ok(ResponseEnvelope::ok(
            envelope.request_id.clone(),
            serde_json::json!({"accepted": true, "key": key}),
        ))
    }

    fn emit_event(&self, event: &str, payload: serde_json::Value) {
        let envelope =
            EventEnvelope::new(uuid::Uuid::new_v4().to_string(), event.to_owned(), payload);
        let _ = self.event_tx.send(envelope);
    }
}

fn parse_device_target(payload: &serde_json::Value) -> Result<DeviceTarget> {
    let Some(raw_target) = payload.get("target").and_then(serde_json::Value::as_str) else {
        return Err(SpeechError::Pipeline(
            "device.move requires payload.target".to_owned(),
        ));
    };

    DeviceTarget::parse(raw_target).ok_or_else(|| {
        SpeechError::Pipeline(format!(
            "unsupported device target `{raw_target}` (expected mac/iphone/watch)"
        ))
    })
}

fn parse_orb_palette(payload: &serde_json::Value) -> Result<String> {
    let Some(raw_palette) = payload.get("palette").and_then(serde_json::Value::as_str) else {
        return Err(SpeechError::Pipeline(
            "orb.palette.set requires payload.palette".to_owned(),
        ));
    };

    let normalized = raw_palette.trim().to_ascii_lowercase();
    if normalized.is_empty() {
        return Err(SpeechError::Pipeline(
            "orb.palette.set requires a non-empty palette value".to_owned(),
        ));
    }

    if !is_supported_orb_palette(normalized.as_str()) {
        return Err(SpeechError::Pipeline(format!(
            "unsupported orb palette `{raw_palette}`"
        )));
    }

    Ok(normalized)
}

fn is_supported_orb_palette(palette: &str) -> bool {
    matches!(
        palette,
        "mode-default"
            | "heather-mist"
            | "glen-green"
            | "loch-grey-green"
            | "autumn-bracken"
            | "silver-mist"
            | "rowan-berry"
            | "moss-stone"
            | "dawn-light"
            | "peat-earth"
    )
}

fn parse_orb_feeling(payload: &serde_json::Value) -> Result<String> {
    let Some(raw_feeling) = payload.get("feeling").and_then(serde_json::Value::as_str) else {
        return Err(SpeechError::Pipeline(
            "orb.feeling.set requires payload.feeling".to_owned(),
        ));
    };

    let normalized = raw_feeling.trim().to_ascii_lowercase();
    if normalized.is_empty() {
        return Err(SpeechError::Pipeline(
            "orb.feeling.set requires a non-empty feeling value".to_owned(),
        ));
    }

    if !is_supported_orb_feeling(&normalized) {
        return Err(SpeechError::Pipeline(format!(
            "unsupported orb feeling `{raw_feeling}`"
        )));
    }

    Ok(normalized)
}

fn is_supported_orb_feeling(feeling: &str) -> bool {
    matches!(
        feeling,
        "neutral" | "calm" | "curiosity" | "warmth" | "concern" | "delight" | "focus" | "playful"
    )
}

fn parse_orb_urgency(payload: &serde_json::Value) -> Result<f32> {
    let Some(raw_urgency) = payload.get("urgency").and_then(serde_json::Value::as_f64) else {
        return Err(SpeechError::Pipeline(
            "orb.urgency.set requires payload.urgency (number)".to_owned(),
        ));
    };

    let urgency = raw_urgency as f32;
    if !(0.0..=1.0).contains(&urgency) {
        return Err(SpeechError::Pipeline(format!(
            "orb.urgency.set requires urgency in range 0.0-1.0, got {urgency}"
        )));
    }

    Ok(urgency)
}

fn parse_orb_flash(payload: &serde_json::Value) -> Result<String> {
    let Some(raw_flash) = payload
        .get("flash_type")
        .and_then(serde_json::Value::as_str)
    else {
        return Err(SpeechError::Pipeline(
            "orb.flash requires payload.flash_type".to_owned(),
        ));
    };

    let normalized = raw_flash.trim().to_ascii_lowercase();
    if !matches!(normalized.as_str(), "error" | "success") {
        return Err(SpeechError::Pipeline(format!(
            "unsupported orb flash type `{raw_flash}` (expected error/success)"
        )));
    }

    Ok(normalized)
}

#[derive(Debug)]
struct CapabilityRequestPayload {
    capability: String,
    reason: String,
    scope: Option<String>,
    /// Whether this is a just-in-time request triggered mid-conversation.
    jit: bool,
    /// The tool name that triggered this JIT request (e.g. `"search_contacts"`).
    tool_name: Option<String>,
    /// Human-readable description of the action the LLM was attempting.
    tool_action: Option<String>,
}

#[derive(Debug)]
struct CapabilityGrantPayload {
    capability: String,
    scope: Option<String>,
}

fn parse_capability_request(payload: &serde_json::Value) -> Result<CapabilityRequestPayload> {
    let capability = parse_non_empty_field(payload, "capability", "capability.request")?;
    let reason = parse_non_empty_field(payload, "reason", "capability.request")?;
    let scope = parse_optional_scope(payload, "capability.request")?;
    let jit = payload
        .get("jit")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let tool_name = payload
        .get("tool_name")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned);
    let tool_action = payload
        .get("tool_action")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned);
    Ok(CapabilityRequestPayload {
        capability,
        reason,
        scope,
        jit,
        tool_name,
        tool_action,
    })
}

fn parse_capability_action(
    payload: &serde_json::Value,
    command: &str,
) -> Result<CapabilityGrantPayload> {
    let capability = parse_non_empty_field(payload, "capability", command)?;
    let scope = parse_optional_scope(payload, command)?;
    Ok(CapabilityGrantPayload { capability, scope })
}

fn parse_non_empty_field(
    payload: &serde_json::Value,
    field: &str,
    command: &str,
) -> Result<String> {
    let Some(raw) = payload.get(field).and_then(serde_json::Value::as_str) else {
        return Err(SpeechError::Pipeline(format!(
            "{command} requires payload.{field}"
        )));
    };
    let value = raw.trim();
    if value.is_empty() {
        return Err(SpeechError::Pipeline(format!(
            "{command} requires a non-empty payload.{field}"
        )));
    }
    Ok(value.to_owned())
}

fn parse_optional_scope(payload: &serde_json::Value, command: &str) -> Result<Option<String>> {
    match payload.get("scope") {
        None | Some(serde_json::Value::Null) => Ok(None),
        Some(serde_json::Value::String(raw_scope)) => {
            let scope = raw_scope.trim();
            if scope.is_empty() {
                return Err(SpeechError::Pipeline(format!(
                    "{command} payload.scope cannot be empty when provided"
                )));
            }
            Ok(Some(scope.to_owned()))
        }
        Some(_) => Err(SpeechError::Pipeline(format!(
            "{command} payload.scope must be a string when provided"
        ))),
    }
}

fn parse_conversation_text(payload: &serde_json::Value) -> Result<String> {
    let Some(raw_text) = payload.get("text").and_then(serde_json::Value::as_str) else {
        return Err(SpeechError::Pipeline(
            "conversation.inject_text requires payload.text".to_owned(),
        ));
    };

    let text = raw_text.trim();
    if text.is_empty() {
        return Err(SpeechError::Pipeline(
            "conversation.inject_text requires a non-empty payload.text".to_owned(),
        ));
    }

    Ok(text.to_owned())
}

/// Allowed URL schemes for link-detected events.
const ALLOWED_LINK_SCHEMES: &[&str] = &["http://", "https://", "mailto:"];

fn parse_conversation_url(payload: &serde_json::Value) -> Result<String> {
    let Some(raw_url) = payload.get("url").and_then(serde_json::Value::as_str) else {
        return Err(SpeechError::Pipeline(
            "conversation.link_detected requires payload.url".to_owned(),
        ));
    };

    let url = raw_url.trim();
    if url.is_empty() {
        return Err(SpeechError::Pipeline(
            "conversation.link_detected requires a non-empty payload.url".to_owned(),
        ));
    }

    let lower = url.to_ascii_lowercase();
    if !ALLOWED_LINK_SCHEMES.iter().any(|s| lower.starts_with(s)) {
        return Err(SpeechError::Pipeline(format!(
            "conversation.link_detected: unsupported URL scheme in `{url}` \
             (allowed: http, https, mailto)"
        )));
    }

    Ok(url.to_owned())
}

fn parse_gate_active(payload: &serde_json::Value) -> Result<bool> {
    let Some(active) = payload.get("active").and_then(serde_json::Value::as_bool) else {
        return Err(SpeechError::Pipeline(
            "conversation.gate_set requires payload.active (boolean)".to_owned(),
        ));
    };
    Ok(active)
}

fn parse_approval_respond(payload: &serde_json::Value) -> Result<(String, bool, Option<String>)> {
    let req_id = parse_non_empty_field(payload, "request_id", "approval.respond")?;
    let Some(approved) = payload.get("approved").and_then(serde_json::Value::as_bool) else {
        return Err(SpeechError::Pipeline(
            "approval.respond requires payload.approved (boolean)".to_owned(),
        ));
    };
    let reason = payload
        .get("reason")
        .and_then(serde_json::Value::as_str)
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty());
    Ok((req_id, approved, reason))
}

fn parse_scheduler_id(payload: &serde_json::Value) -> Result<String> {
    parse_non_empty_field(payload, "id", "scheduler")
}

fn parse_config_patch(payload: &serde_json::Value) -> Result<(String, serde_json::Value)> {
    let key = parse_non_empty_field(payload, "key", "config.patch")?;
    let Some(value) = payload.get("value") else {
        return Err(SpeechError::Pipeline(
            "config.patch requires payload.value".to_owned(),
        ));
    };
    Ok((key, value.clone()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::contract::{CommandEnvelope, CommandName};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    struct TestHandler {
        inject_called: Arc<AtomicBool>,
        gate_called: Arc<AtomicBool>,
    }

    impl TestHandler {
        fn new() -> Self {
            Self {
                inject_called: Arc::new(AtomicBool::new(false)),
                gate_called: Arc::new(AtomicBool::new(false)),
            }
        }
    }

    impl DeviceTransferHandler for TestHandler {
        fn request_move(&self, _target: DeviceTarget) -> Result<()> {
            Ok(())
        }
        fn request_go_home(&self) -> Result<()> {
            Ok(())
        }
        fn request_conversation_inject_text(&self, _text: &str) -> Result<()> {
            self.inject_called.store(true, Ordering::SeqCst);
            Ok(())
        }
        fn request_conversation_gate_set(&self, _active: bool) -> Result<()> {
            self.gate_called.store(true, Ordering::SeqCst);
            Ok(())
        }
    }

    fn make_server() -> HostCommandServer<TestHandler> {
        let handler = TestHandler::new();
        let (_client, server) = command_channel(8, 8, handler);
        server
    }

    fn make_envelope(command: CommandName, payload: serde_json::Value) -> CommandEnvelope {
        CommandEnvelope::new("test-req-1", command, payload)
    }

    #[test]
    fn conversation_inject_text_accepted() {
        let server = make_server();
        let envelope = make_envelope(
            CommandName::ConversationInjectText,
            serde_json::json!({"text": "Hello Fae"}),
        );
        let resp = server.route(&envelope).unwrap();
        assert!(resp.ok);
        assert_eq!(resp.payload["accepted"], true);
        assert_eq!(resp.payload["text"], "Hello Fae");
    }

    #[test]
    fn conversation_inject_text_empty_returns_error() {
        let server = make_server();
        let envelope = make_envelope(
            CommandName::ConversationInjectText,
            serde_json::json!({"text": "   "}),
        );
        let resp = server.route(&envelope);
        assert!(resp.is_err() || !resp.unwrap().ok);
    }

    #[test]
    fn conversation_inject_text_missing_field_returns_error() {
        let server = make_server();
        let envelope = make_envelope(CommandName::ConversationInjectText, serde_json::json!({}));
        let resp = server.route(&envelope);
        assert!(resp.is_err());
    }

    #[test]
    fn conversation_gate_set_active_accepted() {
        let server = make_server();
        let envelope = make_envelope(
            CommandName::ConversationGateSet,
            serde_json::json!({"active": true}),
        );
        let resp = server.route(&envelope).unwrap();
        assert!(resp.ok);
        assert_eq!(resp.payload["accepted"], true);
        assert_eq!(resp.payload["active"], true);
    }

    #[test]
    fn conversation_gate_set_missing_field_returns_error() {
        let server = make_server();
        let envelope = make_envelope(CommandName::ConversationGateSet, serde_json::json!({}));
        let resp = server.route(&envelope);
        assert!(resp.is_err());
    }

    #[test]
    fn conversation_link_detected_accepted() {
        let server = make_server();
        let envelope = make_envelope(
            CommandName::ConversationLinkDetected,
            serde_json::json!({"url": "https://example.com"}),
        );
        let resp = server.route(&envelope).unwrap();
        assert!(resp.ok);
        assert_eq!(resp.payload["accepted"], true);
        assert_eq!(resp.payload["url"], "https://example.com");
    }

    #[test]
    fn conversation_link_detected_empty_returns_error() {
        let server = make_server();
        let envelope = make_envelope(
            CommandName::ConversationLinkDetected,
            serde_json::json!({"url": "   "}),
        );
        let resp = server.route(&envelope);
        assert!(resp.is_err());
    }

    #[test]
    fn conversation_link_detected_bad_scheme_returns_error() {
        let server = make_server();
        let envelope = make_envelope(
            CommandName::ConversationLinkDetected,
            serde_json::json!({"url": "javascript:alert(1)"}),
        );
        let resp = server.route(&envelope);
        assert!(resp.is_err());
    }

    #[test]
    fn conversation_link_detected_missing_field_returns_error() {
        let server = make_server();
        let envelope = make_envelope(CommandName::ConversationLinkDetected, serde_json::json!({}));
        let resp = server.route(&envelope);
        assert!(resp.is_err());
    }

    #[test]
    fn conversation_gate_set_non_bool_returns_error() {
        let server = make_server();
        let envelope = make_envelope(
            CommandName::ConversationGateSet,
            serde_json::json!({"active": "yes"}),
        );
        let resp = server.route(&envelope);
        assert!(resp.is_err());
    }
}
