use serde::{Deserialize, Serialize};

use crate::menu::MenuAction;

#[derive(Debug, Clone, Copy, Deserialize)]
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
        state: FaeUiState,
        audio: Option<f32>,
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
    ClearConversation,
    ShowMessages,
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
                state: FaeUiState::Listening,
                audio: Some(audio),
                feeling: None,
            } => (audio - 0.25).abs() < f32::EPSILON,
            _ => false,
        };
        assert!(decoded);

        let with_feeling: ShellCommand = serde_json::from_str(
            r#"{"type":"state","state":"thinking","audio":null,"feeling":"concern"}"#,
        )?;
        let decoded_feeling = match with_feeling {
            ShellCommand::State {
                state: FaeUiState::Thinking,
                audio: None,
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
    fn encodes_menu_events_as_jsonl_payloads_without_cowork_actions(
    ) -> Result<(), serde_json::Error> {
        let encoded = encode_menu_action(MenuAction::OpenBrowserDataPanel)?;
        assert_eq!(
            encoded,
            r#"{"type":"menu","action":"open_browser_data_panel"}"#
        );
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
}
