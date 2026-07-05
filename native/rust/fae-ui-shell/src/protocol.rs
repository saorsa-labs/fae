use serde::{Deserialize, Deserializer, Serialize};

use crate::menu::MenuAction;

/// Voice spine V4: tri-state `state.audio` patch. Distinguishes three wire
/// shapes so a plain mode/status command (which OMITS `audio`) never clobber
/// the live-voice ride:
/// - field omitted → [`AudioPatch::Unchanged`] (no-op)
/// - numeric value → [`AudioPatch::Set(f32)`] (clamp 0…1, ride the voice)
/// - explicit `null` → [`AudioPatch::Clear`] (return to synthetic breath)
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub enum AudioPatch {
    /// Field omitted — no-op (so a plain mode command never clobbers the ride).
    #[default]
    Unchanged,
    Set(f32),
    Clear,
}

impl<'de> Deserialize<'de> for AudioPatch {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        // Delegate to `Option<f32>`: `None` (explicit `null`) → Clear,
        // `Some(v)` (number) → Set. The OMITTED case never reaches here —
        // `#[serde(default)]` on the struct field supplies `Unchanged` first.
        match Option::<f32>::deserialize(deserializer)? {
            None => Ok(AudioPatch::Clear),
            Some(value) => Ok(AudioPatch::Set(value)),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FaeUiState {
    Quiescent,
    /// Accepted for protocol compatibility and future mic feedback.
    /// The current product UX maps listening to quiescent so the orb only
    /// appears while Fae is thinking or speaking.
    Listening,
    Thinking,
    Speaking,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ShellCommand {
    State {
        /// Optional so an audio-only frame (voice spine V4 level push) is valid
        /// and leaves the mode untouched. Absent → keep the current orb mode;
        /// present → set it (active/visuals/feeling as before).
        #[serde(default)]
        state: Option<FaeUiState>,
        #[serde(default)]
        audio: AudioPatch,
        /// Butler demeanor (OrbFeeling rawValue from Swift): neutral, calm,
        /// curiosity, warmth, concern, delight, focus, playful. Optional for
        /// protocol compatibility with senders that do not include it.
        #[serde(default)]
        feeling: Option<String>,
    },
    Status {
        phase: String,
        message: String,
        progress: Option<f32>,
    },
    Conversation {
        role: String,
        text: String,
    },
    SchedulerSnapshot {
        tasks: Vec<SchedulerTask>,
    },
    SkillsSnapshot {
        skills: Vec<SkillSummary>,
    },
    /// Tool-access mode + thinking level. The Controls strip that consumed this
    /// lived in the removed Messages panel; Swift still emits the snapshot (its
    /// access/thinking fields are ignored on decode) but the orb host no longer
    /// renders it.
    ControlsSnapshot,
    SettingsSnapshot {
        sections: Vec<SettingsSection>,
        cards: Vec<SettingsCard>,
    },
    /// Swift asks Fae's question INSIDE the pill (UX W1): the composer swaps to
    /// a prompted / masked field, and the pill posts `input_response` /
    /// `input_cancel` back over stdout keyed by `request_id`. Preferred over the
    /// SwiftUI overlay card whenever the orb host is connected.
    RequestInput {
        request_id: String,
        prompt: String,
        /// Mask the field (password style) and disable the paste-chip logic.
        #[serde(default)]
        secure: bool,
        /// Allow the composer textarea to grow to multiple rows.
        #[serde(default)]
        multiline: bool,
        #[serde(default)]
        placeholder: Option<String>,
    },
    ClearConversation,
    Show,
    Hide,
    Quit,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SchedulerTask {
    pub id: String,
    pub name: String,
    pub schedule: String,
    pub enabled: bool,
    pub last_run: Option<String>,
    pub next_run: Option<String>,
    pub status: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SkillSummary {
    pub id: String,
    pub description: String,
    pub skill_type: String,
    pub tier: String,
    pub enabled: bool,
    pub active: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SettingsSection {
    pub id: String,
    pub title: String,
    pub description: Option<String>,
    pub settings: Vec<SettingItem>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SettingItem {
    pub key: String,
    pub title: String,
    pub description: String,
    pub kind: String,
    pub value: String,
    pub options: Option<Vec<SettingOption>>,
    pub min: Option<String>,
    pub max: Option<String>,
    pub step: Option<String>,
    pub unit: Option<String>,
    pub read_only: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SettingOption {
    pub value: String,
    pub label: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SettingsCard {
    pub title: String,
    pub body: String,
    pub detail: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ShellEvent<'a> {
    Menu { action: &'a str },
}

pub fn encode_menu_action(action: MenuAction) -> Result<String, serde_json::Error> {
    serde_json::to_string(&ShellEvent::Menu {
        action: action.as_str(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_state_commands() -> Result<(), serde_json::Error> {
        let command: ShellCommand =
            serde_json::from_str(r#"{"type":"state","state":"listening","audio":0.25}"#)?;
        let decoded = match command {
            ShellCommand::State {
                state: Some(FaeUiState::Listening),
                audio: AudioPatch::Set(audio),
                feeling: None,
            } => (audio - 0.25).abs() < f32::EPSILON,
            _ => false,
        };
        assert!(decoded);

        // Voice spine V4: an audio-only frame (no `state`) must decode — it
        // must NOT require a mode, or every level push is dropped.
        let audio_only: ShellCommand = serde_json::from_str(r#"{"type":"state","audio":0.42}"#)?;
        let decoded_audio_only = matches!(
            audio_only,
            ShellCommand::State {
                state: None,
                audio: AudioPatch::Set(_),
                feeling: None,
            }
        );
        assert!(decoded_audio_only, "audio-only state frame must decode");

        let with_feeling: ShellCommand = serde_json::from_str(
            r#"{"type":"state","state":"thinking","audio":null,"feeling":"concern"}"#,
        )?;
        let decoded_feeling = match with_feeling {
            ShellCommand::State {
                state: Some(FaeUiState::Thinking),
                audio: AudioPatch::Clear,
                feeling: Some(feeling),
            } => feeling == "concern",
            _ => false,
        };
        assert!(decoded_feeling);
        Ok(())
    }

    #[test]
    fn decodes_status_and_conversation_commands() -> Result<(), serde_json::Error> {
        let status: ShellCommand = serde_json::from_str(
            r#"{"type":"status","phase":"starting","message":"Loading model","progress":0.42}"#,
        )?;
        let has_status = match status {
            ShellCommand::Status {
                phase,
                message,
                progress: Some(progress),
            } => {
                phase == "starting"
                    && message == "Loading model"
                    && (progress - 0.42).abs() < f32::EPSILON
            }
            _ => false,
        };
        assert!(has_status);

        let conversation: ShellCommand =
            serde_json::from_str(r#"{"type":"conversation","role":"fae","text":"Hello"}"#)?;
        let has_message = match conversation {
            ShellCommand::Conversation { role, text } => role == "fae" && text == "Hello",
            _ => false,
        };
        assert!(has_message);
        Ok(())
    }

    #[test]
    fn decodes_request_input_command() -> Result<(), serde_json::Error> {
        // Secure request: the pill masks the field and skips the paste chip.
        let secure: ShellCommand = serde_json::from_str(
            r#"{"type":"request_input","request_id":"abc-123","prompt":"Paste your API key","secure":true,"multiline":false,"placeholder":"sk-…"}"#,
        )?;
        let ok = match secure {
            ShellCommand::RequestInput {
                request_id,
                prompt,
                secure,
                multiline,
                placeholder,
            } => {
                request_id == "abc-123"
                    && prompt == "Paste your API key"
                    && secure
                    && !multiline
                    && placeholder.as_deref() == Some("sk-…")
            }
            _ => false,
        };
        assert!(ok, "secure request_input must decode with all fields");

        // Minimal request: optional fields default (not secure, single-line).
        let minimal: ShellCommand = serde_json::from_str(
            r#"{"type":"request_input","request_id":"x","prompt":"What's your city?"}"#,
        )?;
        let defaults_ok = matches!(
            minimal,
            ShellCommand::RequestInput {
                secure: false,
                multiline: false,
                placeholder: None,
                ..
            }
        );
        assert!(defaults_ok, "request_input must default optional fields");
        Ok(())
    }

    #[test]
    fn encodes_menu_events_as_jsonl_payloads_without_cowork_actions(
    ) -> Result<(), serde_json::Error> {
        let encoded = encode_menu_action(MenuAction::Settings)?;
        assert_eq!(encoded, r#"{"type":"menu","action":"settings"}"#);
        assert!(!encoded.contains("cowork"));
        Ok(())
    }

    #[test]
    fn encodes_talk_toggle_event() -> Result<(), serde_json::Error> {
        // S18: plain left-click on the orb body emits this to the Swift host.
        let encoded = encode_menu_action(MenuAction::TalkToggle)?;
        assert_eq!(encoded, r#"{"type":"menu","action":"talk_toggle"}"#);
        Ok(())
    }

    #[test]
    fn encodes_legacy_settings_event() -> Result<(), serde_json::Error> {
        let encoded = encode_menu_action(MenuAction::SettingsLegacy)?;
        assert_eq!(encoded, r#"{"type":"menu","action":"settings_legacy"}"#);
        Ok(())
    }

    #[test]
    fn decodes_settings_snapshot() -> Result<(), serde_json::Error> {
        let command: ShellCommand = serde_json::from_str(
            r#"{"type":"settings_snapshot","sections":[{"id":"voice","title":"Voice","description":"Speech","settings":[{"key":"tts.speed","title":"Speed","description":"Playback speed","kind":"number","value":"1.1","options":null,"min":"0.7","max":"1.4","step":"0.05","unit":"×","read_only":false}]}],"cards":[{"title":"Local first","body":"Everything stays on this Mac","detail":null}]}"#,
        )?;
        let decoded = match command {
            ShellCommand::SettingsSnapshot { sections, cards } => {
                sections.len() == 1
                    && sections[0].settings.len() == 1
                    && sections[0].settings[0].key == "tts.speed"
                    && cards.len() == 1
                    && cards[0].title == "Local first"
            }
            _ => false,
        };
        assert!(decoded);
        Ok(())
    }
}
