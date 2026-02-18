use fae::host::contract::{
    CommandEnvelope, CommandName, ContractErrorKind, EVENT_VERSION, EventEnvelope, ResponseEnvelope,
};

#[test]
fn command_name_parse_known_and_unknown() {
    let parsed = CommandName::parse("runtime.start");
    assert_eq!(parsed, Some(CommandName::RuntimeStart));

    let device_move = CommandName::parse("device.move");
    assert_eq!(device_move, Some(CommandName::DeviceMove));
    let orb_palette_set = CommandName::parse("orb.palette.set");
    assert_eq!(orb_palette_set, Some(CommandName::OrbPaletteSet));
    let orb_palette_clear = CommandName::parse("orb.palette.clear");
    assert_eq!(orb_palette_clear, Some(CommandName::OrbPaletteClear));
    let capability_request = CommandName::parse("capability.request");
    assert_eq!(capability_request, Some(CommandName::CapabilityRequest));
    let capability_grant = CommandName::parse("capability.grant");
    assert_eq!(capability_grant, Some(CommandName::CapabilityGrant));
    let capability_deny = CommandName::parse("capability.deny");
    assert_eq!(capability_deny, Some(CommandName::CapabilityDeny));
    let onboarding_get_state = CommandName::parse("onboarding.get_state");
    assert_eq!(onboarding_get_state, Some(CommandName::OnboardingGetState));
    let onboarding_complete = CommandName::parse("onboarding.complete");
    assert_eq!(onboarding_complete, Some(CommandName::OnboardingComplete));

    let orb_feeling_set = CommandName::parse("orb.feeling.set");
    assert_eq!(orb_feeling_set, Some(CommandName::OrbFeelingSet));
    let orb_urgency_set = CommandName::parse("orb.urgency.set");
    assert_eq!(orb_urgency_set, Some(CommandName::OrbUrgencySet));
    let orb_flash = CommandName::parse("orb.flash");
    assert_eq!(orb_flash, Some(CommandName::OrbFlash));

    let conversation_inject = CommandName::parse("conversation.inject_text");
    assert_eq!(
        conversation_inject,
        Some(CommandName::ConversationInjectText)
    );
    let conversation_gate = CommandName::parse("conversation.gate_set");
    assert_eq!(conversation_gate, Some(CommandName::ConversationGateSet));

    let unknown = CommandName::parse("runtime.not_real");
    assert!(unknown.is_none());

    assert_eq!(CommandName::DeviceMove.as_str(), "device.move");
    assert_eq!(CommandName::OrbPaletteSet.as_str(), "orb.palette.set");
    assert_eq!(CommandName::OrbPaletteClear.as_str(), "orb.palette.clear");
    assert_eq!(CommandName::OrbFeelingSet.as_str(), "orb.feeling.set");
    assert_eq!(CommandName::OrbUrgencySet.as_str(), "orb.urgency.set");
    assert_eq!(CommandName::OrbFlash.as_str(), "orb.flash");
    assert_eq!(
        CommandName::CapabilityRequest.as_str(),
        "capability.request"
    );
    assert_eq!(CommandName::CapabilityGrant.as_str(), "capability.grant");
    assert_eq!(CommandName::CapabilityDeny.as_str(), "capability.deny");
    assert_eq!(
        CommandName::OnboardingGetState.as_str(),
        "onboarding.get_state"
    );
    assert_eq!(
        CommandName::OnboardingComplete.as_str(),
        "onboarding.complete"
    );
    assert_eq!(
        CommandName::ConversationInjectText.as_str(),
        "conversation.inject_text"
    );
    assert_eq!(
        CommandName::ConversationGateSet.as_str(),
        "conversation.gate_set"
    );
}

#[test]
fn command_envelope_json_shape_matches_v0_contract() {
    let envelope = CommandEnvelope::new(
        "req-123",
        CommandName::RuntimeStart,
        serde_json::json!({"source": "test"}),
    );

    let json = serde_json::to_value(&envelope).expect("serialize command envelope");
    assert_eq!(json["v"], EVENT_VERSION);
    assert_eq!(json["request_id"], "req-123");
    assert_eq!(json["command"], "runtime.start");
    assert_eq!(json["payload"]["source"], "test");
}

#[test]
fn event_envelope_json_shape_matches_v0_contract() {
    let envelope = EventEnvelope::new(
        "evt-777",
        "runtime.assistant_sentence",
        serde_json::json!({"text": "hello"}),
    );

    let json = serde_json::to_value(&envelope).expect("serialize event envelope");
    assert_eq!(json["v"], EVENT_VERSION);
    assert_eq!(json["event_id"], "evt-777");
    assert_eq!(json["event"], "runtime.assistant_sentence");
    assert_eq!(json["payload"]["text"], "hello");
}

#[test]
fn command_envelope_rejects_wrong_version() {
    let mut envelope =
        CommandEnvelope::new("req-1", CommandName::RuntimeStatus, serde_json::json!({}));
    envelope.v = EVENT_VERSION + 1;

    let err = envelope.validate().expect_err("version should be rejected");
    assert_eq!(err.kind, ContractErrorKind::UnsupportedVersion);
}

#[test]
fn response_envelope_json_shape_matches_v0_contract() {
    let ok = ResponseEnvelope::ok("req-1", serde_json::json!({"accepted": true}));
    let ok_json = serde_json::to_value(&ok).expect("serialize ok response envelope");
    assert_eq!(ok_json["v"], EVENT_VERSION);
    assert_eq!(ok_json["request_id"], "req-1");
    assert_eq!(ok_json["ok"], true);
    assert_eq!(ok_json["payload"]["accepted"], true);
    assert!(ok_json["error"].is_null());

    let err = ResponseEnvelope::error("req-2", "bad payload");
    let err_json = serde_json::to_value(&err).expect("serialize error response envelope");
    assert_eq!(err_json["v"], EVENT_VERSION);
    assert_eq!(err_json["request_id"], "req-2");
    assert_eq!(err_json["ok"], false);
    assert_eq!(err_json["payload"], serde_json::Value::Null);
    assert_eq!(err_json["error"], "bad payload");
}

#[test]
fn command_name_orb_feeling_set_roundtrip() {
    let name = CommandName::OrbFeelingSet;
    let wire = name.as_str();
    assert_eq!(wire, "orb.feeling.set");
    let parsed = CommandName::parse(wire).expect("parse orb.feeling.set");
    assert_eq!(parsed, name);

    // Serde roundtrip
    let json = serde_json::to_value(name).expect("serialize OrbFeelingSet");
    assert_eq!(json, "orb.feeling.set");
    let deserialized: CommandName =
        serde_json::from_value(json).expect("deserialize OrbFeelingSet");
    assert_eq!(deserialized, name);
}

#[test]
fn command_name_orb_urgency_set_roundtrip() {
    let name = CommandName::OrbUrgencySet;
    let wire = name.as_str();
    assert_eq!(wire, "orb.urgency.set");
    let parsed = CommandName::parse(wire).expect("parse orb.urgency.set");
    assert_eq!(parsed, name);

    // Serde roundtrip
    let json = serde_json::to_value(name).expect("serialize OrbUrgencySet");
    assert_eq!(json, "orb.urgency.set");
    let deserialized: CommandName =
        serde_json::from_value(json).expect("deserialize OrbUrgencySet");
    assert_eq!(deserialized, name);
}

#[test]
fn command_name_orb_flash_roundtrip() {
    let name = CommandName::OrbFlash;
    let wire = name.as_str();
    assert_eq!(wire, "orb.flash");
    let parsed = CommandName::parse(wire).expect("parse orb.flash");
    assert_eq!(parsed, name);

    // Serde roundtrip
    let json = serde_json::to_value(name).expect("serialize OrbFlash");
    assert_eq!(json, "orb.flash");
    let deserialized: CommandName = serde_json::from_value(json).expect("deserialize OrbFlash");
    assert_eq!(deserialized, name);
}

#[test]
fn command_name_conversation_inject_text_roundtrip() {
    let name = CommandName::ConversationInjectText;
    let wire = name.as_str();
    assert_eq!(wire, "conversation.inject_text");
    let parsed = CommandName::parse(wire).expect("parse conversation.inject_text");
    assert_eq!(parsed, name);

    let json = serde_json::to_value(name).expect("serialize ConversationInjectText");
    assert_eq!(json, "conversation.inject_text");
    let deserialized: CommandName =
        serde_json::from_value(json).expect("deserialize ConversationInjectText");
    assert_eq!(deserialized, name);
}

#[test]
fn command_name_conversation_gate_set_roundtrip() {
    let name = CommandName::ConversationGateSet;
    let wire = name.as_str();
    assert_eq!(wire, "conversation.gate_set");
    let parsed = CommandName::parse(wire).expect("parse conversation.gate_set");
    assert_eq!(parsed, name);

    let json = serde_json::to_value(name).expect("serialize ConversationGateSet");
    assert_eq!(json, "conversation.gate_set");
    let deserialized: CommandName =
        serde_json::from_value(json).expect("deserialize ConversationGateSet");
    assert_eq!(deserialized, name);
}

#[test]
fn command_name_capability_deny_roundtrip() {
    let name = CommandName::CapabilityDeny;
    let wire = name.as_str();
    assert_eq!(wire, "capability.deny");
    let parsed = CommandName::parse(wire).expect("parse capability.deny");
    assert_eq!(parsed, name);

    let json = serde_json::to_value(name).expect("serialize CapabilityDeny");
    assert_eq!(json, "capability.deny");
    let deserialized: CommandName =
        serde_json::from_value(json).expect("deserialize CapabilityDeny");
    assert_eq!(deserialized, name);
}

#[test]
fn command_name_onboarding_get_state_roundtrip() {
    let name = CommandName::OnboardingGetState;
    let wire = name.as_str();
    assert_eq!(wire, "onboarding.get_state");
    let parsed = CommandName::parse(wire).expect("parse onboarding.get_state");
    assert_eq!(parsed, name);

    let json = serde_json::to_value(name).expect("serialize OnboardingGetState");
    assert_eq!(json, "onboarding.get_state");
    let deserialized: CommandName =
        serde_json::from_value(json).expect("deserialize OnboardingGetState");
    assert_eq!(deserialized, name);
}

#[test]
fn command_name_onboarding_complete_roundtrip() {
    let name = CommandName::OnboardingComplete;
    let wire = name.as_str();
    assert_eq!(wire, "onboarding.complete");
    let parsed = CommandName::parse(wire).expect("parse onboarding.complete");
    assert_eq!(parsed, name);

    let json = serde_json::to_value(name).expect("serialize OnboardingComplete");
    assert_eq!(json, "onboarding.complete");
    let deserialized: CommandName =
        serde_json::from_value(json).expect("deserialize OnboardingComplete");
    assert_eq!(deserialized, name);
}
