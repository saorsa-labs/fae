//! Host command channel and router for native shell integrations.

use crate::error::{Result, SpeechError};
use crate::host::contract::{CommandEnvelope, CommandName, EventEnvelope, ResponseEnvelope};
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
    let (request_tx, request_rx) = mpsc::channel(request_capacity.max(1));
    let (event_tx, _event_rx) = broadcast::channel(event_capacity.max(1));

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

    fn route(&self, envelope: &CommandEnvelope) -> Result<ResponseEnvelope> {
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
            CommandName::CapabilityRequest => self.handle_capability_request(envelope),
            CommandName::CapabilityGrant => self.handle_capability_grant(envelope),
            _ => Ok(ResponseEnvelope::error(
                envelope.request_id.clone(),
                format!(
                    "command not implemented in host channel: {}",
                    envelope.command.as_str()
                ),
            )),
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
                "reason": request.reason
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
        let grant = parse_capability_grant(&envelope.payload)?;
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

#[derive(Debug)]
struct CapabilityRequestPayload {
    capability: String,
    reason: String,
    scope: Option<String>,
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
    Ok(CapabilityRequestPayload {
        capability,
        reason,
        scope,
    })
}

fn parse_capability_grant(payload: &serde_json::Value) -> Result<CapabilityGrantPayload> {
    let capability = parse_non_empty_field(payload, "capability", "capability.grant")?;
    let scope = parse_optional_scope(payload, "capability.grant")?;
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
