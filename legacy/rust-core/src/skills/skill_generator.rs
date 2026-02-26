//! Skill Generator Pipeline — LATM (Language Agent Tool Making) pattern.
//!
//! Generates Python skills from plain-English user intents. The pipeline:
//!
//! 1. Checks the discovery index for existing matching skills.
//! 2. Creates a staging directory with `manifest.toml` and entry script.
//! 3. Validates the staged output (manifest parsing, PEP 723 metadata, script structure).
//! 4. Returns a [`SkillProposal`] for caller approval.
//! 5. On approval, installs via [`crate::skills::python_lifecycle::install_python_skill_at`]
//!    and optionally indexes in the discovery index.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::error::PythonSkillError;
use super::manifest::{CredentialSchema, PythonSkillManifest};
use super::pep723::parse_inline_metadata;

// ── Types ────────────────────────────────────────────────────────────────────

/// A proposed skill ready for user review before installation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillProposal {
    /// Unique skill identifier (lowercase, digits, hyphens, underscores).
    pub skill_id: String,
    /// Human-readable skill name.
    pub name: String,
    /// Plain-English description of what the skill does.
    pub description: String,
    /// Raw TOML content for `manifest.toml`.
    pub manifest_toml: String,
    /// Raw Python source code for the entry script.
    pub script_source: String,
    /// Credentials declared in the manifest.
    pub credentials: Vec<CredentialSchemaView>,
    /// Python dependencies extracted from PEP 723 metadata.
    pub dependencies: Vec<String>,
    /// Path to the staging directory holding the generated files.
    #[serde(skip)]
    pub staging_dir: PathBuf,
}

/// Serializable view of a credential schema for proposal display.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CredentialSchemaView {
    /// Credential name.
    pub name: String,
    /// Environment variable name.
    pub env_var: String,
    /// Human-readable description.
    pub description: String,
    /// Whether this credential is required.
    pub required: bool,
}

impl From<&CredentialSchema> for CredentialSchemaView {
    fn from(schema: &CredentialSchema) -> Self {
        Self {
            name: schema.name.clone(),
            env_var: schema.env_var.clone(),
            description: schema.description.clone(),
            required: schema.required,
        }
    }
}

/// Outcome of a skill generation attempt.
#[derive(Debug)]
pub enum GeneratorOutcome {
    /// A valid skill was generated and is ready for review.
    Proposed(SkillProposal),
    /// An existing skill already matches the intent closely enough.
    ExistingMatch {
        /// The matching skill's identifier.
        skill_id: String,
        /// The matching skill's name.
        name: String,
        /// Cosine similarity score (0.0–1.0).
        score: f32,
    },
    /// Generation failed with a reason.
    Failed {
        /// Why the generation failed.
        reason: String,
    },
}

/// Configuration for the skill generator pipeline.
#[derive(Debug, Clone)]
pub struct SkillGeneratorConfig {
    /// Maximum LLM agent turns for generation (default: 8).
    pub max_llm_turns: usize,
    /// Maximum test/fix iterations (default: 4).
    pub max_test_rounds: usize,
    /// Similarity threshold above which an existing skill is returned
    /// instead of generating a new one (default: 0.85).
    pub discovery_threshold: f32,
}

impl Default for SkillGeneratorConfig {
    fn default() -> Self {
        Self {
            max_llm_turns: 8,
            max_test_rounds: 4,
            discovery_threshold: 0.85,
        }
    }
}

// ── LATM System Prompt ───────────────────────────────────────────────────────

/// System prompt for the LATM skill generation agent.
///
/// This prompt instructs the LLM to produce a `manifest.toml` and a PEP 723
/// Python script that implements a JSON-RPC 2.0 skill over stdin/stdout.
pub const SKILL_GENERATOR_SYSTEM_PROMPT: &str = r#"You are a Python skill generator for Fae, a personal AI assistant.

Your task is to generate a working Python skill package from a user's plain-English request.
A skill package consists of two files:

## 1. manifest.toml

```toml
id = "skill-id"           # lowercase, digits, hyphens, underscores only
name = "Human Name"        # display name
version = "0.1.0"
description = "What this skill does in one sentence."
entry_file = "skill.py"

# Only if the skill needs API keys or tokens:
# [[credentials]]
# name = "api_key"
# env_var = "SERVICE_API_KEY"
# description = "Your API key for the service"
# required = true
```

## 2. skill.py (PEP 723 script)

```python
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "requests>=2.31",
# ]
# ///

import json
import sys

def handle_invoke(params):
    """Handle an invoke request. Return a dict with the result."""
    action = params.get("action", "")
    # ... implement the skill logic here ...
    return {"status": "ok", "result": "done"}

def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue

        method = request.get("method", "")
        req_id = request.get("id")
        params = request.get("params", {})

        if method == "handshake":
            response = {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "protocol_version": "1.0",
                    "skill_name": "SKILL_NAME_HERE",
                    "capabilities": ["invoke"]
                }
            }
        elif method == "invoke":
            try:
                result = handle_invoke(params)
                response = {"jsonrpc": "2.0", "id": req_id, "result": result}
            except Exception as e:
                response = {"jsonrpc": "2.0", "id": req_id, "error": {"code": -1, "message": str(e)}}
        elif method == "health":
            response = {"jsonrpc": "2.0", "id": req_id, "result": {"status": "healthy"}}
        elif method == "shutdown":
            response = {"jsonrpc": "2.0", "id": req_id, "result": {"status": "ok"}}
            print(json.dumps(response), flush=True)
            sys.exit(0)
        else:
            response = {"jsonrpc": "2.0", "id": req_id, "error": {"code": -32601, "message": f"unknown method: {method}"}}

        print(json.dumps(response), flush=True)

if __name__ == "__main__":
    main()
```

## Rules

1. The `id` MUST be lowercase letters, digits, hyphens, and underscores only.
2. Always include PEP 723 inline metadata with `dependencies`.
3. The script MUST handle `handshake`, `invoke`, `health`, and `shutdown` methods.
4. All responses MUST be valid JSON-RPC 2.0 (include `jsonrpc`, `id`, and `result` or `error`).
5. Use `print(json.dumps(response), flush=True)` for all output.
6. Never use `input()` — read from `sys.stdin` line by line.
7. Credentials should be read from environment variables, declared in manifest.toml.
8. Keep the script focused — one skill, one purpose.
"#;

/// Build the generation prompt for a specific user intent.
pub fn build_generation_prompt(intent: &str) -> String {
    format!(
        "Generate a Python skill package for the following request:\n\n\
         \"{intent}\"\n\n\
         Write the manifest.toml first, then the skill.py script. \
         Make sure the skill_name in the handshake response matches the manifest id."
    )
}

// ── Template generation ──────────────────────────────────────────────────────

/// Sanitize a user intent string into a valid skill id.
///
/// Converts to lowercase, replaces spaces/special chars with hyphens,
/// collapses consecutive hyphens, and trims leading/trailing hyphens.
pub fn intent_to_skill_id(intent: &str) -> String {
    let lowered: String = intent
        .to_lowercase()
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '-'
            }
        })
        .collect();

    // Collapse consecutive hyphens.
    let mut collapsed = String::with_capacity(lowered.len());
    let mut prev_hyphen = false;
    for ch in lowered.chars() {
        if ch == '-' {
            if !prev_hyphen {
                collapsed.push(ch);
            }
            prev_hyphen = true;
        } else {
            collapsed.push(ch);
            prev_hyphen = false;
        }
    }

    // Trim leading/trailing hyphens and truncate.
    let trimmed = collapsed.trim_matches('-');
    if trimmed.len() > 60 {
        trimmed[..60].trim_end_matches('-').to_owned()
    } else {
        trimmed.to_owned()
    }
}

/// Generate a template-based manifest TOML string from intent.
fn generate_template_manifest(skill_id: &str, name: &str, description: &str) -> String {
    format!(
        "id = \"{skill_id}\"\n\
         name = \"{name}\"\n\
         version = \"0.1.0\"\n\
         description = \"{description}\"\n\
         entry_file = \"skill.py\"\n"
    )
}

/// Generate a template-based Python script from intent.
fn generate_template_script(skill_id: &str, description: &str) -> String {
    format!(
        r#"# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///

"""
{description}

Generated by Fae skill generator.
"""

import json
import sys


def handle_invoke(params):
    """Handle an invoke request."""
    action = params.get("action", "")
    return {{"status": "ok", "action": action, "message": "Skill '{skill_id}' invoked successfully"}}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue

        method = request.get("method", "")
        req_id = request.get("id")
        params = request.get("params", {{}})

        if method == "handshake":
            response = {{
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {{
                    "protocol_version": "1.0",
                    "skill_name": "{skill_id}",
                    "capabilities": ["invoke"]
                }}
            }}
        elif method == "invoke":
            try:
                result = handle_invoke(params)
                response = {{"jsonrpc": "2.0", "id": req_id, "result": result}}
            except Exception as e:
                response = {{"jsonrpc": "2.0", "id": req_id, "error": {{"code": -1, "message": str(e)}}}}
        elif method == "health":
            response = {{"jsonrpc": "2.0", "id": req_id, "result": {{"status": "healthy"}}}}
        elif method == "shutdown":
            response = {{"jsonrpc": "2.0", "id": req_id, "result": {{"status": "ok"}}}}
            print(json.dumps(response), flush=True)
            sys.exit(0)
        else:
            response = {{"jsonrpc": "2.0", "id": req_id, "error": {{"code": -32601, "message": f"unknown method: {{method}}"}}}}

        print(json.dumps(response), flush=True)


if __name__ == "__main__":
    main()
"#
    )
}

// ── Staging validation ───────────────────────────────────────────────────────

/// Validate a staged skill directory and build a [`SkillProposal`].
///
/// The staging directory must contain:
/// - `manifest.toml` — valid [`PythonSkillManifest`]
/// - The entry script named by the manifest (default `skill.py`)
///
/// The script is checked for:
/// - Non-empty content
/// - Valid PEP 723 metadata block
/// - Presence of JSON-RPC handler structure (`"handshake"`, `"invoke"`)
///
/// # Errors
///
/// Returns [`PythonSkillError`] if validation fails at any step.
pub fn validate_staged_skill(staging_dir: &Path) -> Result<SkillProposal, PythonSkillError> {
    // 1. Load and validate manifest.
    let manifest = PythonSkillManifest::load_from_dir(staging_dir)?;

    // 2. Read entry script.
    let entry_path = staging_dir.join(&manifest.entry_file);
    let script_source =
        std::fs::read_to_string(&entry_path).map_err(|e| PythonSkillError::BootstrapFailed {
            reason: format!("cannot read entry script `{}`: {e}", manifest.entry_file),
        })?;

    if script_source.trim().is_empty() {
        return Err(PythonSkillError::BootstrapFailed {
            reason: "entry script is empty".to_owned(),
        });
    }

    // 3. Parse PEP 723 metadata.
    let pep723 = parse_inline_metadata(&script_source);

    // 4. Verify JSON-RPC structure (basic text checks).
    if !script_source.contains("handshake") {
        return Err(PythonSkillError::BootstrapFailed {
            reason: "entry script missing `handshake` handler".to_owned(),
        });
    }
    if !script_source.contains("invoke") {
        return Err(PythonSkillError::BootstrapFailed {
            reason: "entry script missing `invoke` handler".to_owned(),
        });
    }

    // 5. Read raw manifest TOML for the proposal.
    let manifest_toml = std::fs::read_to_string(staging_dir.join("manifest.toml"))
        .map_err(PythonSkillError::IoError)?;

    // 6. Build proposal.
    Ok(SkillProposal {
        skill_id: manifest.id.clone(),
        name: manifest.name.clone(),
        description: manifest.description.clone().unwrap_or_default(),
        manifest_toml,
        script_source,
        credentials: manifest
            .credentials
            .iter()
            .map(CredentialSchemaView::from)
            .collect(),
        dependencies: pep723.dependencies,
        staging_dir: staging_dir.to_path_buf(),
    })
}

// ── Pipeline ─────────────────────────────────────────────────────────────────

/// Skill generator pipeline.
///
/// Uses template-based generation to produce a valid Python skill package
/// from a user intent. Future versions will integrate an LLM agent loop
/// for more sophisticated code generation.
pub struct SkillGeneratorPipeline {
    config: SkillGeneratorConfig,
}

impl SkillGeneratorPipeline {
    /// Create a new pipeline with the given configuration.
    pub fn new(config: SkillGeneratorConfig) -> Self {
        Self { config }
    }

    /// Create a new pipeline with default configuration.
    pub fn with_defaults() -> Self {
        Self::new(SkillGeneratorConfig::default())
    }

    /// Returns a reference to the pipeline configuration.
    pub fn config(&self) -> &SkillGeneratorConfig {
        &self.config
    }

    /// Generate a skill proposal from a plain-English intent.
    ///
    /// The generated files are written to `staging_dir`. The caller must
    /// create the staging directory before calling this method.
    ///
    /// This method does NOT install the skill — it returns a
    /// [`SkillProposal`] for the caller to review and approve.
    ///
    /// # Errors
    ///
    /// Returns [`PythonSkillError`] if staging or validation fails.
    pub fn generate(
        &self,
        intent: &str,
        staging_dir: &Path,
    ) -> Result<GeneratorOutcome, PythonSkillError> {
        let intent = intent.trim();
        if intent.is_empty() {
            return Err(PythonSkillError::BootstrapFailed {
                reason: "intent cannot be empty".to_owned(),
            });
        }

        // Derive skill identity from intent.
        let skill_id = intent_to_skill_id(intent);
        if skill_id.is_empty() {
            return Err(PythonSkillError::BootstrapFailed {
                reason: format!("cannot derive skill id from intent: {intent}"),
            });
        }

        // Title-case the skill name.
        let name = title_case(&skill_id);
        let description = intent.to_owned();

        // Write manifest.toml to staging directory.
        let manifest_content = generate_template_manifest(&skill_id, &name, &description);
        std::fs::create_dir_all(staging_dir).map_err(PythonSkillError::IoError)?;
        std::fs::write(staging_dir.join("manifest.toml"), &manifest_content)
            .map_err(PythonSkillError::IoError)?;

        // Write entry script to staging directory.
        let script_content = generate_template_script(&skill_id, &description);
        std::fs::write(staging_dir.join("skill.py"), &script_content)
            .map_err(PythonSkillError::IoError)?;

        // Validate the staged output.
        let proposal = validate_staged_skill(staging_dir)?;

        Ok(GeneratorOutcome::Proposed(proposal))
    }
}

/// Install an approved proposal into the Python skills directory.
///
/// Copies the staging directory contents to `python_skills_dir/{skill_id}/`
/// and calls [`crate::skills::python_lifecycle::install_python_skill_at`].
///
/// # Errors
///
/// Returns [`PythonSkillError`] if installation fails.
pub fn install_proposal(
    proposal: &SkillProposal,
    python_skills_dir: &Path,
) -> Result<super::PythonSkillInfo, PythonSkillError> {
    let target_dir = python_skills_dir.join(&proposal.skill_id);
    std::fs::create_dir_all(&target_dir).map_err(PythonSkillError::IoError)?;

    // Write manifest.
    std::fs::write(target_dir.join("manifest.toml"), &proposal.manifest_toml)
        .map_err(PythonSkillError::IoError)?;

    // Determine entry file name from the manifest.
    let manifest = PythonSkillManifest::load_from_dir(&target_dir)?;
    let entry_file = &manifest.entry_file;

    // Write entry script.
    std::fs::write(target_dir.join(entry_file), &proposal.script_source)
        .map_err(PythonSkillError::IoError)?;

    // Install via the lifecycle module.
    let paths = super::SkillPaths::for_root(python_skills_dir.to_path_buf());
    super::python_lifecycle::install_python_skill_at(&paths, &target_dir)
}

/// Index a proposal in the discovery system.
///
/// Registers the skill's metadata and embedding vector in the
/// [`crate::skills::discovery::SkillDiscoveryIndex`] so it can be found
/// by future semantic searches.
///
/// # Errors
///
/// Returns [`PythonSkillError`] if indexing fails.
pub fn index_proposal(
    index: &super::discovery::SkillDiscoveryIndex,
    proposal: &SkillProposal,
    embedding: &[f32],
) -> Result<(), PythonSkillError> {
    index.index_skill(
        &proposal.skill_id,
        &proposal.name,
        &proposal.description,
        "python",
        embedding,
    )
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Convert a hyphenated skill id to title case.
fn title_case(id: &str) -> String {
    id.split(['-', '_'])
        .filter(|w| !w.is_empty())
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                Some(first) => {
                    let upper: String = first.to_uppercase().collect();
                    format!("{upper}{}", chars.as_str())
                }
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    // ── Type construction tests ──

    #[test]
    fn default_config_values() {
        let config = SkillGeneratorConfig::default();
        assert_eq!(config.max_llm_turns, 8);
        assert_eq!(config.max_test_rounds, 4);
        assert!((config.discovery_threshold - 0.85).abs() < f32::EPSILON);
    }

    #[test]
    fn skill_proposal_serializes_to_json() {
        let proposal = SkillProposal {
            skill_id: "test-skill".to_owned(),
            name: "Test Skill".to_owned(),
            description: "A test skill".to_owned(),
            manifest_toml: "id = \"test-skill\"\nname = \"Test Skill\"\n".to_owned(),
            script_source: "# test script".to_owned(),
            credentials: vec![CredentialSchemaView {
                name: "api_key".to_owned(),
                env_var: "API_KEY".to_owned(),
                description: "Test API key".to_owned(),
                required: true,
            }],
            dependencies: vec!["requests>=2.31".to_owned()],
            staging_dir: PathBuf::from("/tmp/staging"),
        };

        let json = serde_json::to_string(&proposal).expect("serialize");
        assert!(json.contains("test-skill"));
        assert!(json.contains("API_KEY"));
        // staging_dir is #[serde(skip)] so should not appear.
        assert!(!json.contains("/tmp/staging"));
    }

    #[test]
    fn credential_schema_view_from_credential_schema() {
        let schema = CredentialSchema {
            name: "token".to_owned(),
            env_var: "MY_TOKEN".to_owned(),
            description: "A token".to_owned(),
            required: false,
            default: Some("default_val".to_owned()),
        };

        let view = CredentialSchemaView::from(&schema);
        assert_eq!(view.name, "token");
        assert_eq!(view.env_var, "MY_TOKEN");
        assert!(!view.required);
    }

    // ── intent_to_skill_id tests ──

    #[test]
    fn intent_to_skill_id_basic() {
        assert_eq!(
            intent_to_skill_id("Send emails via SendGrid"),
            "send-emails-via-sendgrid"
        );
    }

    #[test]
    fn intent_to_skill_id_special_chars() {
        let result = intent_to_skill_id("Discord Bot (v2)!");
        assert_eq!(result, "discord-bot-v2");
        assert!(
            !result.ends_with('-'),
            "should not end with hyphen: {result}"
        );
    }

    #[test]
    fn intent_to_skill_id_collapses_hyphens() {
        assert_eq!(intent_to_skill_id("foo   bar   baz"), "foo-bar-baz");
    }

    #[test]
    fn intent_to_skill_id_preserves_underscores() {
        assert_eq!(intent_to_skill_id("my_skill_name"), "my_skill_name");
    }

    #[test]
    fn intent_to_skill_id_truncates_long() {
        let long_intent = "a".repeat(100);
        let id = intent_to_skill_id(&long_intent);
        assert!(id.len() <= 60);
    }

    #[test]
    fn intent_to_skill_id_empty_returns_empty() {
        assert_eq!(intent_to_skill_id(""), "");
        assert_eq!(intent_to_skill_id("!!!"), "");
    }

    // ── title_case tests ──

    #[test]
    fn title_case_basic() {
        assert_eq!(title_case("send-email"), "Send Email");
        assert_eq!(title_case("discord_bot"), "Discord Bot");
        assert_eq!(title_case("my-cool-skill"), "My Cool Skill");
    }

    // ── Template generation tests ──

    #[test]
    fn template_manifest_contains_required_fields() {
        let manifest = generate_template_manifest("test-skill", "Test Skill", "A test");
        assert!(manifest.contains("id = \"test-skill\""));
        assert!(manifest.contains("name = \"Test Skill\""));
        assert!(manifest.contains("version = \"0.1.0\""));
        assert!(manifest.contains("entry_file = \"skill.py\""));
    }

    #[test]
    fn template_script_contains_jsonrpc_handlers() {
        let script = generate_template_script("test-skill", "A test skill");
        assert!(script.contains("handshake"));
        assert!(script.contains("invoke"));
        assert!(script.contains("health"));
        assert!(script.contains("shutdown"));
        assert!(script.contains("# /// script"));
        assert!(script.contains("test-skill"));
    }

    // ── LATM prompt tests ──

    #[test]
    fn system_prompt_contains_key_instructions() {
        assert!(SKILL_GENERATOR_SYSTEM_PROMPT.contains("manifest.toml"));
        assert!(SKILL_GENERATOR_SYSTEM_PROMPT.contains("PEP 723"));
        assert!(SKILL_GENERATOR_SYSTEM_PROMPT.contains("JSON-RPC 2.0"));
        assert!(SKILL_GENERATOR_SYSTEM_PROMPT.contains("handshake"));
    }

    #[test]
    fn build_generation_prompt_includes_intent() {
        let prompt = build_generation_prompt("send emails via SendGrid");
        assert!(prompt.contains("send emails via SendGrid"));
        assert!(prompt.contains("manifest.toml"));
    }

    // ── Staging validation tests ──

    #[test]
    fn validate_staged_skill_valid() {
        let dir = tempfile::tempdir().expect("tempdir");

        // Write valid manifest.
        std::fs::write(
            dir.path().join("manifest.toml"),
            "id = \"test-skill\"\nname = \"Test Skill\"\ndescription = \"A test\"\n",
        )
        .unwrap();

        // Write valid script.
        let script = generate_template_script("test-skill", "A test");
        std::fs::write(dir.path().join("skill.py"), &script).unwrap();

        let proposal = validate_staged_skill(dir.path()).expect("validate");
        assert_eq!(proposal.skill_id, "test-skill");
        assert_eq!(proposal.name, "Test Skill");
        assert!(proposal.script_source.contains("handshake"));
    }

    #[test]
    fn validate_staged_skill_missing_manifest() {
        let dir = tempfile::tempdir().expect("tempdir");
        let result = validate_staged_skill(dir.path());
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("cannot read"));
    }

    #[test]
    fn validate_staged_skill_missing_entry_script() {
        let dir = tempfile::tempdir().expect("tempdir");
        std::fs::write(
            dir.path().join("manifest.toml"),
            "id = \"test\"\nname = \"Test\"\n",
        )
        .unwrap();

        let result = validate_staged_skill(dir.path());
        assert!(result.is_err());
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("cannot read entry script"),
        );
    }

    #[test]
    fn validate_staged_skill_empty_script() {
        let dir = tempfile::tempdir().expect("tempdir");
        std::fs::write(
            dir.path().join("manifest.toml"),
            "id = \"test\"\nname = \"Test\"\n",
        )
        .unwrap();
        std::fs::write(dir.path().join("skill.py"), "  \n  ").unwrap();

        let result = validate_staged_skill(dir.path());
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("empty"));
    }

    #[test]
    fn validate_staged_skill_missing_handshake() {
        let dir = tempfile::tempdir().expect("tempdir");
        std::fs::write(
            dir.path().join("manifest.toml"),
            "id = \"test\"\nname = \"Test\"\n",
        )
        .unwrap();
        std::fs::write(dir.path().join("skill.py"), "print('hello')").unwrap();

        let result = validate_staged_skill(dir.path());
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("handshake"));
    }

    #[test]
    fn validate_staged_skill_missing_invoke() {
        let dir = tempfile::tempdir().expect("tempdir");
        std::fs::write(
            dir.path().join("manifest.toml"),
            "id = \"test\"\nname = \"Test\"\n",
        )
        .unwrap();
        std::fs::write(
            dir.path().join("skill.py"),
            "# handshake only\ndef handshake(): pass",
        )
        .unwrap();

        let result = validate_staged_skill(dir.path());
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("invoke"));
    }

    // ── Pipeline tests ──

    #[test]
    fn pipeline_generate_basic() {
        let dir = tempfile::tempdir().expect("tempdir");
        let pipeline = SkillGeneratorPipeline::with_defaults();

        let outcome = pipeline
            .generate("send emails via sendgrid", dir.path())
            .expect("generate");

        match outcome {
            GeneratorOutcome::Proposed(proposal) => {
                assert_eq!(proposal.skill_id, "send-emails-via-sendgrid");
                assert_eq!(proposal.name, "Send Emails Via Sendgrid");
                assert!(proposal.manifest_toml.contains("send-emails-via-sendgrid"));
                assert!(proposal.script_source.contains("handshake"));
            }
            other => panic!("expected Proposed, got: {other:?}"),
        }
    }

    #[test]
    fn pipeline_generate_empty_intent_errors() {
        let dir = tempfile::tempdir().expect("tempdir");
        let pipeline = SkillGeneratorPipeline::with_defaults();

        let result = pipeline.generate("", dir.path());
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("empty"));
    }

    #[test]
    fn pipeline_generate_special_chars_intent() {
        let dir = tempfile::tempdir().expect("tempdir");
        let pipeline = SkillGeneratorPipeline::with_defaults();

        let outcome = pipeline
            .generate("Discord Bot (v2)!", dir.path())
            .expect("generate");

        match outcome {
            GeneratorOutcome::Proposed(proposal) => {
                assert_eq!(proposal.skill_id, "discord-bot-v2");
                assert!(!proposal.skill_id.ends_with('-'));
            }
            other => panic!("expected Proposed, got: {other:?}"),
        }
    }

    #[test]
    fn pipeline_config_is_accessible() {
        let pipeline = SkillGeneratorPipeline::with_defaults();
        assert_eq!(pipeline.config().max_llm_turns, 8);
    }

    // ── Install proposal tests ──

    #[test]
    fn install_proposal_creates_files() {
        let staging = tempfile::tempdir().expect("staging");
        let target = tempfile::tempdir().expect("target");

        let pipeline = SkillGeneratorPipeline::with_defaults();
        let outcome = pipeline
            .generate("weather checker", staging.path())
            .expect("generate");

        let proposal = match outcome {
            GeneratorOutcome::Proposed(p) => p,
            other => panic!("expected Proposed, got: {other:?}"),
        };

        let info = install_proposal(&proposal, target.path()).expect("install");
        assert_eq!(info.id, "weather-checker");
        assert_eq!(info.status, super::super::PythonSkillStatus::Pending);

        // Verify files exist on disk.
        let skill_dir = target.path().join("weather-checker");
        assert!(skill_dir.join("manifest.toml").is_file());
        assert!(skill_dir.join("skill.py").is_file());
    }

    // ── Index proposal tests ──

    #[test]
    fn index_proposal_makes_searchable() {
        let proposal = SkillProposal {
            skill_id: "weather-checker".to_owned(),
            name: "Weather Checker".to_owned(),
            description: "Check weather forecasts".to_owned(),
            manifest_toml: String::new(),
            script_source: String::new(),
            credentials: Vec::new(),
            dependencies: Vec::new(),
            staging_dir: PathBuf::new(),
        };

        let index =
            super::super::discovery::SkillDiscoveryIndex::open_in_memory().expect("open index");

        // Use a mock embedding.
        let embedding: Vec<f32> = (0..384).map(|i| (i as f32 * 0.1).sin()).collect();

        index_proposal(&index, &proposal, &embedding).expect("index");

        let results = index.search(&embedding, 5).expect("search");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].skill_id, "weather-checker");
    }
}
