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

    let orb_feeling_set = CommandName::parse("orb.feeling.set");
    assert_eq!(orb_feeling_set, Some(CommandName::OrbFeelingSet));
    let orb_urgency_set = CommandName::parse("orb.urgency.set");
    assert_eq!(orb_urgency_set, Some(CommandName::OrbUrgencySet));
    let orb_flash = CommandName::parse("orb.flash");
    assert_eq!(orb_flash, Some(CommandName::OrbFlash));

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
