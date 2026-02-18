//! Versioned host command/event envelopes for native shell integration.

use serde::{Deserialize, Serialize};

/// Contract version for host command/event envelopes.
pub const EVENT_VERSION: u32 = 1;

/// V0 command set for host integrations.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CommandName {
    #[serde(rename = "host.ping")]
    HostPing,
    #[serde(rename = "host.version")]
    HostVersion,
    #[serde(rename = "runtime.start")]
    RuntimeStart,
    #[serde(rename = "runtime.stop")]
    RuntimeStop,
    #[serde(rename = "runtime.status")]
    RuntimeStatus,
    #[serde(rename = "conversation.inject_text")]
    ConversationInjectText,
    #[serde(rename = "conversation.gate_set")]
    ConversationGateSet,
    #[serde(rename = "approval.respond")]
    ApprovalRespond,
    #[serde(rename = "scheduler.list")]
    SchedulerList,
    #[serde(rename = "scheduler.create")]
    SchedulerCreate,
    #[serde(rename = "scheduler.update")]
    SchedulerUpdate,
    #[serde(rename = "scheduler.delete")]
    SchedulerDelete,
    #[serde(rename = "scheduler.trigger_now")]
    SchedulerTriggerNow,
    #[serde(rename = "device.move")]
    DeviceMove,
    #[serde(rename = "device.go_home")]
    DeviceGoHome,
    #[serde(rename = "orb.palette.set")]
    OrbPaletteSet,
    #[serde(rename = "orb.palette.clear")]
    OrbPaletteClear,
    #[serde(rename = "orb.feeling.set")]
    OrbFeelingSet,
    #[serde(rename = "orb.urgency.set")]
    OrbUrgencySet,
    #[serde(rename = "orb.flash")]
    OrbFlash,
    #[serde(rename = "capability.request")]
    CapabilityRequest,
    #[serde(rename = "capability.grant")]
    CapabilityGrant,
    #[serde(rename = "capability.deny")]
    CapabilityDeny,
    #[serde(rename = "onboarding.get_state")]
    OnboardingGetState,
    #[serde(rename = "onboarding.complete")]
    OnboardingComplete,
    #[serde(rename = "config.get")]
    ConfigGet,
    #[serde(rename = "config.patch")]
    ConfigPatch,
}

impl CommandName {
    /// Render command name to wire format.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::HostPing => "host.ping",
            Self::HostVersion => "host.version",
            Self::RuntimeStart => "runtime.start",
            Self::RuntimeStop => "runtime.stop",
            Self::RuntimeStatus => "runtime.status",
            Self::ConversationInjectText => "conversation.inject_text",
            Self::ConversationGateSet => "conversation.gate_set",
            Self::ApprovalRespond => "approval.respond",
            Self::SchedulerList => "scheduler.list",
            Self::SchedulerCreate => "scheduler.create",
            Self::SchedulerUpdate => "scheduler.update",
            Self::SchedulerDelete => "scheduler.delete",
            Self::SchedulerTriggerNow => "scheduler.trigger_now",
            Self::DeviceMove => "device.move",
            Self::DeviceGoHome => "device.go_home",
            Self::OrbPaletteSet => "orb.palette.set",
            Self::OrbPaletteClear => "orb.palette.clear",
            Self::OrbFeelingSet => "orb.feeling.set",
            Self::OrbUrgencySet => "orb.urgency.set",
            Self::OrbFlash => "orb.flash",
            Self::CapabilityRequest => "capability.request",
            Self::CapabilityGrant => "capability.grant",
            Self::CapabilityDeny => "capability.deny",
            Self::OnboardingGetState => "onboarding.get_state",
            Self::OnboardingComplete => "onboarding.complete",
            Self::ConfigGet => "config.get",
            Self::ConfigPatch => "config.patch",
        }
    }

    /// Parse a command name from wire format.
    #[must_use]
    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "host.ping" => Some(Self::HostPing),
            "host.version" => Some(Self::HostVersion),
            "runtime.start" => Some(Self::RuntimeStart),
            "runtime.stop" => Some(Self::RuntimeStop),
            "runtime.status" => Some(Self::RuntimeStatus),
            "conversation.inject_text" => Some(Self::ConversationInjectText),
            "conversation.gate_set" => Some(Self::ConversationGateSet),
            "approval.respond" => Some(Self::ApprovalRespond),
            "scheduler.list" => Some(Self::SchedulerList),
            "scheduler.create" => Some(Self::SchedulerCreate),
            "scheduler.update" => Some(Self::SchedulerUpdate),
            "scheduler.delete" => Some(Self::SchedulerDelete),
            "scheduler.trigger_now" => Some(Self::SchedulerTriggerNow),
            "device.move" => Some(Self::DeviceMove),
            "device.go_home" => Some(Self::DeviceGoHome),
            "orb.palette.set" => Some(Self::OrbPaletteSet),
            "orb.palette.clear" => Some(Self::OrbPaletteClear),
            "orb.feeling.set" => Some(Self::OrbFeelingSet),
            "orb.urgency.set" => Some(Self::OrbUrgencySet),
            "orb.flash" => Some(Self::OrbFlash),
            "capability.request" => Some(Self::CapabilityRequest),
            "capability.grant" => Some(Self::CapabilityGrant),
            "capability.deny" => Some(Self::CapabilityDeny),
            "onboarding.get_state" => Some(Self::OnboardingGetState),
            "onboarding.complete" => Some(Self::OnboardingComplete),
            "config.get" => Some(Self::ConfigGet),
            "config.patch" => Some(Self::ConfigPatch),
            _ => None,
        }
    }
}

/// A versioned response envelope from backend host -> frontend.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResponseEnvelope {
    pub v: u32,
    pub request_id: String,
    pub ok: bool,
    pub payload: serde_json::Value,
    pub error: Option<String>,
}

impl ResponseEnvelope {
    /// Build a successful response envelope.
    #[must_use]
    pub fn ok(request_id: impl Into<String>, payload: serde_json::Value) -> Self {
        Self {
            v: EVENT_VERSION,
            request_id: request_id.into(),
            ok: true,
            payload,
            error: None,
        }
    }

    /// Build an error response envelope.
    #[must_use]
    pub fn error(request_id: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            v: EVENT_VERSION,
            request_id: request_id.into(),
            ok: false,
            payload: serde_json::Value::Null,
            error: Some(message.into()),
        }
    }
}

/// A versioned command envelope from frontend -> backend host.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CommandEnvelope {
    pub v: u32,
    pub request_id: String,
    pub command: CommandName,
    pub payload: serde_json::Value,
}

impl CommandEnvelope {
    /// Build a v1 command envelope.
    #[must_use]
    pub fn new(
        request_id: impl Into<String>,
        command: CommandName,
        payload: serde_json::Value,
    ) -> Self {
        Self {
            v: EVENT_VERSION,
            request_id: request_id.into(),
            command,
            payload,
        }
    }

    /// Validate envelope version and required identifiers.
    pub fn validate(&self) -> Result<(), ContractError> {
        if self.v != EVENT_VERSION {
            return Err(ContractError::new(
                ContractErrorKind::UnsupportedVersion,
                format!(
                    "unsupported contract version {}; expected {}",
                    self.v, EVENT_VERSION
                ),
            ));
        }
        if self.request_id.trim().is_empty() {
            return Err(ContractError::new(
                ContractErrorKind::InvalidEnvelope,
                "request_id cannot be empty".to_owned(),
            ));
        }
        Ok(())
    }
}

/// A versioned event envelope from backend host -> frontend.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EventEnvelope {
    pub v: u32,
    pub event_id: String,
    pub event: String,
    pub payload: serde_json::Value,
}

impl EventEnvelope {
    /// Build a v1 event envelope.
    #[must_use]
    pub fn new(
        event_id: impl Into<String>,
        event: impl Into<String>,
        payload: serde_json::Value,
    ) -> Self {
        Self {
            v: EVENT_VERSION,
            event_id: event_id.into(),
            event: event.into(),
            payload,
        }
    }
}

/// Contract validation error categories.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContractErrorKind {
    UnsupportedVersion,
    InvalidEnvelope,
}

/// Contract validation error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContractError {
    pub kind: ContractErrorKind,
    pub message: String,
}

impl ContractError {
    #[must_use]
    pub fn new(kind: ContractErrorKind, message: String) -> Self {
        Self { kind, message }
    }
}

impl std::fmt::Display for ContractError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}: {}", self.kind, self.message)
    }
}

impl std::error::Error for ContractError {}
