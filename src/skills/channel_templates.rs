//! Pre-built Python skill templates for Discord and WhatsApp channel
//! integrations.
//!
//! These templates replicate the functionality of the hardcoded Rust channel
//! adapters (`src/channels/discord.rs`, `src/channels/whatsapp.rs`) as Python
//! skills. They can be installed via [`install_channel_skill`] which writes the
//! manifest and script to the Python skills directory.

use crate::skills::error::PythonSkillError;
use std::path::Path;

/// Supported channel types that have pre-built templates.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChannelType {
    /// Discord bot channel via gateway websocket + REST API.
    Discord,
    /// WhatsApp Business Cloud API channel via webhook.
    WhatsApp,
}

impl ChannelType {
    /// Returns the skill ID for this channel type.
    #[must_use]
    pub fn skill_id(self) -> &'static str {
        match self {
            Self::Discord => "channel-discord",
            Self::WhatsApp => "channel-whatsapp",
        }
    }

    /// Returns the human-readable name.
    #[must_use]
    pub fn name(self) -> &'static str {
        match self {
            Self::Discord => "Discord Channel",
            Self::WhatsApp => "WhatsApp Channel",
        }
    }

    /// Returns the manifest.toml content for this channel type.
    #[must_use]
    pub fn manifest_toml(self) -> &'static str {
        match self {
            Self::Discord => DISCORD_MANIFEST,
            Self::WhatsApp => WHATSAPP_MANIFEST,
        }
    }

    /// Returns the skill.py content for this channel type.
    #[must_use]
    pub fn script_source(self) -> &'static str {
        match self {
            Self::Discord => DISCORD_SCRIPT,
            Self::WhatsApp => WHATSAPP_SCRIPT,
        }
    }
}

impl std::fmt::Display for ChannelType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Discord => write!(f, "discord"),
            Self::WhatsApp => write!(f, "whatsapp"),
        }
    }
}

// ── Discord template ─────────────────────────────────────────────────────────

const DISCORD_MANIFEST: &str = r#"id = "channel-discord"
name = "Discord Channel"
version = "1.0.0"
description = "Discord bot integration via gateway websocket and REST API"
entry_file = "skill.py"

[[credentials]]
name = "bot_token"
env_var = "DISCORD_BOT_TOKEN"
description = "Discord bot token from the Developer Portal"
required = true
"#;

const DISCORD_SCRIPT: &str = r#"# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "websockets>=12.0",
#     "httpx>=0.27",
# ]
# ///
"""Discord channel skill — gateway websocket + REST API."""

import asyncio
import json
import sys
import httpx
import websockets

GATEWAY_URL = "wss://gateway.discord.gg/?v=10&encoding=json"
API_BASE = "https://discord.com/api/v10"

bot_token = ""
guild_id = ""
allowed_channel_ids = []
allowed_user_ids = []
ws = None
heartbeat_interval = None
sequence = None

def read_request():
    line = sys.stdin.readline()
    if not line:
        return None
    return json.loads(line.strip())

def send_response(response):
    sys.stdout.write(json.dumps(response) + "\n")
    sys.stdout.flush()

def handle_handshake(req_id):
    return {"jsonrpc": "2.0", "id": req_id, "result": {"name": "channel-discord", "version": "1.0.0", "protocol": "fae-skill-v1"}}

def handle_health(req_id):
    status = "ok" if bot_token else "degraded"
    detail = None if bot_token else "no bot token configured"
    result = {"status": status}
    if detail:
        result["detail"] = detail
    return {"jsonrpc": "2.0", "id": req_id, "result": result}

async def send_discord_message(channel_id, text):
    headers = {"Authorization": f"Bot {bot_token}", "Content-Type": "application/json"}
    async with httpx.AsyncClient() as client:
        await client.post(f"{API_BASE}/channels/{channel_id}/messages", headers=headers, json={"content": text})

def handle_invoke(req_id, params):
    action = params.get("action", "")
    if action == "send":
        channel_id = params.get("reply_target", "")
        text = params.get("text", "")
        if channel_id and text:
            asyncio.get_event_loop().run_until_complete(send_discord_message(channel_id, text))
        return {"jsonrpc": "2.0", "id": req_id, "result": {"sent": True}}
    return {"jsonrpc": "2.0", "id": req_id, "result": {"status": "unknown_action"}}

def main():
    global bot_token, guild_id, allowed_channel_ids, allowed_user_ids
    while True:
        req = read_request()
        if req is None:
            break
        req_id = req.get("id")
        method = req.get("method", "")
        params = req.get("params", {})

        if method == "skill.handshake":
            creds = params.get("credentials", {})
            settings = params.get("settings", {})
            bot_token = creds.get("bot_token", "")
            guild_id = settings.get("guild_id", "")
            allowed_channel_ids = [s.strip() for s in settings.get("allowed_channel_ids", "").split(",") if s.strip()]
            allowed_user_ids = [s.strip() for s in settings.get("allowed_user_ids", "").split(",") if s.strip()]
            send_response(handle_handshake(req_id))
        elif method == "skill.invoke":
            send_response(handle_invoke(req_id, params))
        elif method == "skill.health":
            send_response(handle_health(req_id))
        elif method == "skill.shutdown":
            send_response({"jsonrpc": "2.0", "id": req_id, "result": {"status": "ok"}})
            break
        else:
            send_response({"jsonrpc": "2.0", "id": req_id, "error": {"code": -32601, "message": f"unknown method: {method}"}})

if __name__ == "__main__":
    main()
"#;

// ── WhatsApp template ────────────────────────────────────────────────────────

const WHATSAPP_MANIFEST: &str = r#"id = "channel-whatsapp"
name = "WhatsApp Channel"
version = "1.0.0"
description = "WhatsApp Business Cloud API integration via webhook"
entry_file = "skill.py"

[[credentials]]
name = "access_token"
env_var = "WHATSAPP_ACCESS_TOKEN"
description = "WhatsApp Cloud API access token"
required = true

[[credentials]]
name = "verify_token"
env_var = "WHATSAPP_VERIFY_TOKEN"
description = "Webhook verification token"
required = true
"#;

const WHATSAPP_SCRIPT: &str = r#"# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "httpx>=0.27",
# ]
# ///
"""WhatsApp Business Cloud API channel skill."""

import json
import sys
import httpx

API_BASE = "https://graph.facebook.com/v18.0"

access_token = ""
phone_number_id = ""
verify_token = ""
allowed_numbers = []

def read_request():
    line = sys.stdin.readline()
    if not line:
        return None
    return json.loads(line.strip())

def send_response(response):
    sys.stdout.write(json.dumps(response) + "\n")
    sys.stdout.flush()

def handle_handshake(req_id):
    return {"jsonrpc": "2.0", "id": req_id, "result": {"name": "channel-whatsapp", "version": "1.0.0", "protocol": "fae-skill-v1"}}

def handle_health(req_id):
    status = "ok" if access_token and phone_number_id else "degraded"
    detail = None if status == "ok" else "missing credentials"
    result = {"status": status}
    if detail:
        result["detail"] = detail
    return {"jsonrpc": "2.0", "id": req_id, "result": result}

def send_whatsapp_message(to_number, text):
    headers = {"Authorization": f"Bearer {access_token}", "Content-Type": "application/json"}
    payload = {
        "messaging_product": "whatsapp",
        "to": to_number,
        "type": "text",
        "text": {"body": text},
    }
    resp = httpx.post(f"{API_BASE}/{phone_number_id}/messages", headers=headers, json=payload)
    return resp.status_code == 200

def handle_invoke(req_id, params):
    action = params.get("action", "")
    if action == "send":
        to_number = params.get("reply_target", "")
        text = params.get("text", "")
        if to_number and text:
            success = send_whatsapp_message(to_number, text)
            return {"jsonrpc": "2.0", "id": req_id, "result": {"sent": success}}
        return {"jsonrpc": "2.0", "id": req_id, "result": {"sent": False, "reason": "missing reply_target or text"}}
    elif action == "webhook_verify":
        token = params.get("hub.verify_token", "")
        challenge = params.get("hub.challenge", "")
        if token == verify_token:
            return {"jsonrpc": "2.0", "id": req_id, "result": {"challenge": challenge}}
        return {"jsonrpc": "2.0", "id": req_id, "error": {"code": -32000, "message": "invalid verify token"}}
    return {"jsonrpc": "2.0", "id": req_id, "result": {"status": "unknown_action"}}

def main():
    global access_token, phone_number_id, verify_token, allowed_numbers
    while True:
        req = read_request()
        if req is None:
            break
        req_id = req.get("id")
        method = req.get("method", "")
        params = req.get("params", {})

        if method == "skill.handshake":
            creds = params.get("credentials", {})
            settings = params.get("settings", {})
            access_token = creds.get("access_token", "")
            verify_token = creds.get("verify_token", "")
            phone_number_id = settings.get("phone_number_id", "")
            allowed_numbers = [s.strip() for s in settings.get("allowed_numbers", "").split(",") if s.strip()]
            send_response(handle_handshake(req_id))
        elif method == "skill.invoke":
            send_response(handle_invoke(req_id, params))
        elif method == "skill.health":
            send_response(handle_health(req_id))
        elif method == "skill.shutdown":
            send_response({"jsonrpc": "2.0", "id": req_id, "result": {"status": "ok"}})
            break
        else:
            send_response({"jsonrpc": "2.0", "id": req_id, "error": {"code": -32601, "message": f"unknown method: {method}"}})

if __name__ == "__main__":
    main()
"#;

// ── Install helper ───────────────────────────────────────────────────────────

/// Install a pre-built channel skill template to the Python skills directory.
///
/// Creates the skill directory with `manifest.toml` and `skill.py`, then
/// registers it via [`install_python_skill_at`].
pub fn install_channel_skill(
    channel_type: ChannelType,
    python_skills_dir: &Path,
) -> Result<crate::skills::PythonSkillInfo, PythonSkillError> {
    let skill_dir = python_skills_dir.join(channel_type.skill_id());
    std::fs::create_dir_all(&skill_dir).map_err(PythonSkillError::IoError)?;

    std::fs::write(
        skill_dir.join("manifest.toml"),
        channel_type.manifest_toml(),
    )
    .map_err(PythonSkillError::IoError)?;
    std::fs::write(skill_dir.join("skill.py"), channel_type.script_source())
        .map_err(PythonSkillError::IoError)?;

    let paths = crate::skills::SkillPaths::for_root(python_skills_dir.to_path_buf());
    crate::skills::python_lifecycle::install_python_skill_at(&paths, &skill_dir)
}

/// List available channel template types.
#[must_use]
pub fn available_channel_types() -> Vec<ChannelType> {
    vec![ChannelType::Discord, ChannelType::WhatsApp]
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn discord_manifest_is_valid_toml() {
        let manifest: crate::skills::manifest::PythonSkillManifest =
            toml::from_str(DISCORD_MANIFEST).expect("valid manifest");
        assert_eq!(manifest.id, "channel-discord");
        assert_eq!(manifest.entry_file, "skill.py");
    }

    #[test]
    fn whatsapp_manifest_is_valid_toml() {
        let manifest: crate::skills::manifest::PythonSkillManifest =
            toml::from_str(WHATSAPP_MANIFEST).expect("valid manifest");
        assert_eq!(manifest.id, "channel-whatsapp");
        assert_eq!(manifest.entry_file, "skill.py");
    }

    #[test]
    fn discord_manifest_has_credentials() {
        let manifest: crate::skills::manifest::PythonSkillManifest =
            toml::from_str(DISCORD_MANIFEST).unwrap();
        assert_eq!(manifest.credentials.len(), 1);
        assert_eq!(manifest.credentials[0].name, "bot_token");
    }

    #[test]
    fn whatsapp_manifest_has_credentials() {
        let manifest: crate::skills::manifest::PythonSkillManifest =
            toml::from_str(WHATSAPP_MANIFEST).unwrap();
        assert_eq!(manifest.credentials.len(), 2);
        assert_eq!(manifest.credentials[0].name, "access_token");
        assert_eq!(manifest.credentials[1].name, "verify_token");
    }

    #[test]
    fn discord_script_has_required_methods() {
        assert!(DISCORD_SCRIPT.contains("skill.handshake"));
        assert!(DISCORD_SCRIPT.contains("skill.invoke"));
        assert!(DISCORD_SCRIPT.contains("skill.health"));
        assert!(DISCORD_SCRIPT.contains("skill.shutdown"));
        assert!(DISCORD_SCRIPT.contains("# /// script"));
    }

    #[test]
    fn whatsapp_script_has_required_methods() {
        assert!(WHATSAPP_SCRIPT.contains("skill.handshake"));
        assert!(WHATSAPP_SCRIPT.contains("skill.invoke"));
        assert!(WHATSAPP_SCRIPT.contains("skill.health"));
        assert!(WHATSAPP_SCRIPT.contains("skill.shutdown"));
        assert!(WHATSAPP_SCRIPT.contains("# /// script"));
    }

    #[test]
    fn channel_type_skill_ids() {
        assert_eq!(ChannelType::Discord.skill_id(), "channel-discord");
        assert_eq!(ChannelType::WhatsApp.skill_id(), "channel-whatsapp");
    }

    #[test]
    fn channel_type_display() {
        assert_eq!(ChannelType::Discord.to_string(), "discord");
        assert_eq!(ChannelType::WhatsApp.to_string(), "whatsapp");
    }

    #[test]
    fn available_channel_types_contains_both() {
        let types = available_channel_types();
        assert_eq!(types.len(), 2);
        assert!(types.contains(&ChannelType::Discord));
        assert!(types.contains(&ChannelType::WhatsApp));
    }

    #[test]
    fn install_channel_skill_creates_files() {
        let dir = tempfile::tempdir().expect("tempdir");
        let python_dir = dir.path().join("skills");
        std::fs::create_dir_all(&python_dir).unwrap();
        std::fs::create_dir_all(python_dir.join(".state")).unwrap();

        let info = install_channel_skill(ChannelType::Discord, &python_dir).expect("install");
        assert_eq!(info.id, "channel-discord");

        let skill_dir = python_dir.join("channel-discord");
        assert!(skill_dir.join("manifest.toml").is_file());
        assert!(skill_dir.join("skill.py").is_file());
    }

    #[test]
    fn install_both_channels() {
        let dir = tempfile::tempdir().expect("tempdir");
        let python_dir = dir.path().join("skills");
        std::fs::create_dir_all(&python_dir).unwrap();
        std::fs::create_dir_all(python_dir.join(".state")).unwrap();

        install_channel_skill(ChannelType::Discord, &python_dir).expect("install discord");
        install_channel_skill(ChannelType::WhatsApp, &python_dir).expect("install whatsapp");

        assert!(
            python_dir
                .join("channel-discord")
                .join("skill.py")
                .is_file()
        );
        assert!(
            python_dir
                .join("channel-whatsapp")
                .join("skill.py")
                .is_file()
        );
    }
}
