//! Simple markdown-backed memory for Fae (primary user + known people).
//!
//! Files are stored under `<root_dir>/memory/` so they are easy to inspect,
//! edit, and back up. By default, `<root_dir>` is `~/.fae`.

use crate::error::{Result, SpeechError};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct MemoryStore {
    root: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrimaryUser {
    pub name: String,
    pub voiceprint: Option<Vec<f32>>,
    #[serde(default)]
    pub voice_sample_wav: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Person {
    pub name: String,
    pub voiceprint: Option<Vec<f32>>,
    #[serde(default)]
    pub voice_sample_wav: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct PeopleFile {
    people: Vec<Person>,
}

impl MemoryStore {
    #[must_use]
    pub fn new(root_dir: &Path) -> Self {
        Self {
            root: root_dir.join("memory"),
        }
    }

    pub fn ensure_dirs(&self) -> Result<()> {
        std::fs::create_dir_all(&self.root)?;
        Ok(())
    }

    pub fn ensure_voice_dirs(root_dir: &Path) -> Result<()> {
        std::fs::create_dir_all(root_dir.join("voices"))?;
        Ok(())
    }

    #[must_use]
    pub fn voices_dir(root_dir: &Path) -> PathBuf {
        root_dir.join("voices")
    }

    #[must_use]
    pub fn root(&self) -> &Path {
        &self.root
    }

    fn primary_user_path(&self) -> PathBuf {
        self.root.join("primary_user.md")
    }

    fn people_path(&self) -> PathBuf {
        self.root.join("people.md")
    }

    pub fn load_primary_user(&self) -> Result<Option<PrimaryUser>> {
        let path = self.primary_user_path();
        if !path.exists() {
            return Ok(None);
        }
        let body = std::fs::read_to_string(&path)?;
        let toml = extract_toml_block(&body).ok_or_else(|| {
            SpeechError::Memory("primary user memory missing ```toml``` block".into())
        })?;
        let user: PrimaryUser = toml::from_str(&toml)
            .map_err(|e| SpeechError::Memory(format!("invalid primary user memory: {e}")))?;
        Ok(Some(user))
    }

    pub fn save_primary_user(&self, user: &PrimaryUser) -> Result<()> {
        self.ensure_dirs()?;
        let path = self.primary_user_path();
        let data = toml::to_string_pretty(user)
            .map_err(|e| SpeechError::Memory(format!("failed to serialize primary user: {e}")))?;

        let md = format!(
            "# Fae Memory: Primary User\n\n\
This file is managed by Fae. It is safe to edit by hand.\n\n\
```toml\n{data}```\n"
        );
        std::fs::write(path, md)?;
        Ok(())
    }

    pub fn load_people(&self) -> Result<Vec<Person>> {
        let path = self.people_path();
        if !path.exists() {
            return Ok(Vec::new());
        }
        let body = std::fs::read_to_string(&path)?;
        let toml = extract_toml_block(&body)
            .ok_or_else(|| SpeechError::Memory("people memory missing ```toml``` block".into()))?;
        let file: PeopleFile = toml::from_str(&toml)
            .map_err(|e| SpeechError::Memory(format!("invalid people memory: {e}")))?;
        Ok(file.people)
    }

    pub fn save_people(&self, people: &[Person]) -> Result<()> {
        self.ensure_dirs()?;
        let path = self.people_path();
        let file = PeopleFile {
            people: people.to_vec(),
        };
        let data = toml::to_string_pretty(&file)
            .map_err(|e| SpeechError::Memory(format!("failed to serialize people: {e}")))?;
        let md = format!(
            "# Fae Memory: People\n\n\
Known people and (optional) voiceprints.\n\n\
```toml\n{data}```\n"
        );
        std::fs::write(path, md)?;
        Ok(())
    }
}

fn extract_toml_block(md: &str) -> Option<String> {
    // Very small parser:
    // - find a line that is exactly ```toml (trimmed)
    // - capture until the next ``` line
    let mut in_block = false;
    let mut buf = Vec::new();
    for raw in md.lines() {
        let line = raw.trim_end();
        if !in_block {
            if line.trim() == "```toml" {
                in_block = true;
            }
            continue;
        }
        if line.trim() == "```" {
            break;
        }
        buf.push(line);
    }
    if buf.is_empty() {
        None
    } else {
        Some(buf.join("\n"))
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    #[test]
    fn extract_toml_block_round_trip() {
        let user = PrimaryUser {
            name: "Alice".into(),
            voiceprint: Some(vec![0.1, 0.2, 0.3]),
            voice_sample_wav: Some("voices/alice.wav".into()),
        };
        let data = toml::to_string_pretty(&user).unwrap();
        let md = format!("# x\n\n```toml\n{data}```\n");
        let extracted = extract_toml_block(&md).expect("toml block");
        let decoded: PrimaryUser = toml::from_str(&extracted).unwrap();
        assert_eq!(decoded.name, "Alice");
        assert_eq!(decoded.voiceprint.unwrap().len(), 3);
        assert_eq!(
            decoded.voice_sample_wav.unwrap_or_default(),
            "voices/alice.wav"
        );
    }
}
