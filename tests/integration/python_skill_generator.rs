//! Integration tests for the skill generator pipeline.

use fae::skills::discovery::SkillDiscoveryIndex;
use fae::skills::skill_generator::{
    GeneratorOutcome, SkillGeneratorConfig, SkillGeneratorPipeline, index_proposal,
    install_proposal, validate_staged_skill,
};

#[test]
fn generate_proposal_from_intent() {
    let staging = tempfile::tempdir().expect("staging");
    let pipeline = SkillGeneratorPipeline::with_defaults();

    let outcome = pipeline
        .generate("send slack messages", staging.path())
        .expect("generate");

    match outcome {
        GeneratorOutcome::Proposed(proposal) => {
            assert_eq!(proposal.skill_id, "send-slack-messages");
            assert!(!proposal.manifest_toml.is_empty());
            assert!(proposal.script_source.contains("handshake"));
            assert!(proposal.script_source.contains("invoke"));
            assert!(proposal.description.contains("send slack messages"));
        }
        other => panic!("expected Proposed, got: {other:?}"),
    }
}

#[test]
fn install_proposal_creates_files_on_disk() {
    let staging = tempfile::tempdir().expect("staging");
    let target = tempfile::tempdir().expect("target");
    let pipeline = SkillGeneratorPipeline::with_defaults();

    let outcome = pipeline
        .generate("github notifier", staging.path())
        .expect("generate");

    let proposal = match outcome {
        GeneratorOutcome::Proposed(p) => p,
        other => panic!("expected Proposed, got: {other:?}"),
    };

    let info = install_proposal(&proposal, target.path()).expect("install");
    assert_eq!(info.id, "github-notifier");

    // Verify files on disk.
    let skill_dir = target.path().join("github-notifier");
    assert!(skill_dir.join("manifest.toml").is_file());
    assert!(skill_dir.join("skill.py").is_file());

    // Verify manifest content.
    let manifest = std::fs::read_to_string(skill_dir.join("manifest.toml")).expect("read manifest");
    assert!(manifest.contains("github-notifier"));
}

#[test]
fn index_proposal_makes_searchable() {
    let staging = tempfile::tempdir().expect("staging");
    let pipeline = SkillGeneratorPipeline::with_defaults();

    let outcome = pipeline
        .generate("weather forecast checker", staging.path())
        .expect("generate");

    let proposal = match outcome {
        GeneratorOutcome::Proposed(p) => p,
        other => panic!("expected Proposed, got: {other:?}"),
    };

    let db_dir = tempfile::tempdir().expect("db_dir");
    let index = SkillDiscoveryIndex::open(&db_dir.path().join("discovery.db")).expect("open index");

    // Mock embedding (384-dim).
    let embedding: Vec<f32> = (0..384).map(|i| (i as f32 * 0.1).sin()).collect();

    index_proposal(&index, &proposal, &embedding).expect("index");

    let results = index.search(&embedding, 5).expect("search");
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].skill_id, "weather-forecast-checker");
    assert_eq!(results[0].source, "python");
}

#[test]
fn empty_intent_returns_error() {
    let staging = tempfile::tempdir().expect("staging");
    let pipeline = SkillGeneratorPipeline::with_defaults();

    let result = pipeline.generate("", staging.path());
    assert!(result.is_err());
    assert!(result.unwrap_err().to_string().contains("empty"));
}

#[test]
fn validate_staged_skill_roundtrip() {
    let staging = tempfile::tempdir().expect("staging");
    let pipeline = SkillGeneratorPipeline::with_defaults();

    // Generate to staging.
    let outcome = pipeline
        .generate("email sender", staging.path())
        .expect("generate");

    let proposal = match outcome {
        GeneratorOutcome::Proposed(p) => p,
        other => panic!("expected Proposed, got: {other:?}"),
    };

    // Re-validate the same staging dir.
    let revalidated = validate_staged_skill(staging.path()).expect("revalidate");
    assert_eq!(revalidated.skill_id, proposal.skill_id);
    assert_eq!(revalidated.name, proposal.name);
}

#[test]
fn generator_config_defaults() {
    let config = SkillGeneratorConfig::default();
    assert_eq!(config.max_llm_turns, 8);
    assert_eq!(config.max_test_rounds, 4);
    assert!((config.discovery_threshold - 0.85).abs() < f32::EPSILON);
}

#[test]
fn host_command_skill_generate() {
    use fae::host::channel::command_channel;
    use fae::host::contract::{CommandEnvelope, CommandName};

    let (handler, _dir, _rt) = super::helpers::temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    let envelope = CommandEnvelope::new(
        "req-gen-1",
        CommandName::SkillGenerate,
        serde_json::json!({ "intent": "track expenses", "confirm": false }),
    );

    let response = server.route(&envelope).expect("route");
    assert!(response.ok);

    let payload = &response.payload;
    assert_eq!(payload["status"], "proposed");
    assert!(
        payload["proposal"]["skill_id"]
            .as_str()
            .unwrap()
            .contains("track-expenses")
    );
}

#[test]
fn host_command_skill_generate_empty_intent_errors() {
    use fae::host::channel::command_channel;
    use fae::host::contract::{CommandEnvelope, CommandName};

    let (handler, _dir, _rt) = super::helpers::temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    let envelope = CommandEnvelope::new(
        "req-gen-2",
        CommandName::SkillGenerate,
        serde_json::json!({ "intent": "", "confirm": false }),
    );

    let result = server.route(&envelope);
    assert!(result.is_err());
}
