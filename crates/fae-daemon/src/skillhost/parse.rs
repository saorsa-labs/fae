//! `SKILL.md` frontmatter + body splitting (ADR-013 Vision A, A2.5).
//!
//! Ports Swift `SkillParser.splitFrontmatter` / `buildMetadata`
//! (`native/macos/Fae/Sources/Fae/Skills/SkillParser.swift`): a `SKILL.md` is a
//! YAML-frontmatter markdown file delimited by a leading `---` line and a
//! closing `---` line. Fae's Swift side uses a **simple line-based** YAML reader
//! (`parseSimpleYaml`), NOT a full YAML engine — this port mirrors that exactly
//! (top-level `key: value` scalars, nested blocks ignored) so the daemon and the
//! app agree on `name`/`description` for the same file.
//!
//! The `Skill` type in `fluers-runtime` parses only name+description and is
//! insufficient for the integrity'd loader (ADR-013 §changes), so this is Fae's
//! own parser.

/// The parsed front of a `SKILL.md`: the frontmatter `name`/`description` plus
/// the markdown body that follows the closing `---`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkillFront {
    /// The frontmatter `name:` (the skill's identity + registry key).
    pub name: String,
    /// The frontmatter `description:` (progressive-disclosure summary). Empty
    /// when absent — Swift tolerates a missing description.
    pub description: String,
    /// The markdown body after the closing `---` (the instruction text returned
    /// by `skillhost.activate`). Trimmed of a single leading blank line.
    pub body: String,
}

/// Split a `SKILL.md` into `{name, description, body}`.
///
/// Returns `None` when the file has no leading `---` frontmatter fence or no
/// `name:` key — matching Swift `SkillParser.parse` returning `nil` (an
/// unparseable skill is skipped at discovery, never half-loaded).
#[must_use]
pub fn parse_skill_md(content: &str) -> Option<SkillFront> {
    // Normalize CRLF so a Windows-authored SKILL.md parses identically.
    let normalized = content.replace("\r\n", "\n");
    let mut lines = normalized.split('\n');

    // The first non-empty structural line must be the opening fence. Swift
    // requires `lines.first` trimmed == "---" (no leading blank lines allowed).
    let first = lines.next()?;
    if first.trim() != "---" {
        return None;
    }

    let mut name: Option<String> = None;
    let mut description = String::new();
    // Track the byte offset where the body starts (after the closing fence).
    let mut frontmatter_lines: Vec<&str> = Vec::new();
    let mut closed = false;
    let mut consumed = first.len() + 1; // include the newline after the fence
    for line in lines {
        let line_span = line.len() + 1;
        if line.trim() == "---" {
            closed = true;
            consumed += line_span;
            break;
        }
        frontmatter_lines.push(line);
        consumed += line_span;
    }
    if !closed {
        // No closing fence ⇒ malformed frontmatter ⇒ skip (fail closed).
        return None;
    }

    // Simple top-level `key: value` scalar reader (mirrors parseSimpleYaml).
    // Only un-indented keys are top-level; indented lines belong to nested
    // blocks (e.g. `metadata:`) that we deliberately ignore.
    for raw in &frontmatter_lines {
        if raw.starts_with([' ', '\t']) {
            continue; // nested block member — not a top-level scalar
        }
        let trimmed = raw.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let Some((key, value)) = trimmed.split_once(':') else {
            continue;
        };
        let key = key.trim();
        let value = unquote(value.trim());
        match key {
            "name" => name = Some(value.to_string()),
            "description" => description = value.to_string(),
            _ => {}
        }
    }

    let name = name?;
    if name.is_empty() {
        return None;
    }

    // Body = everything after the closing fence, with a single leading blank
    // line stripped (the conventional blank line between fence and heading).
    let after_fence = normalized
        .get(consumed.min(normalized.len())..)
        .unwrap_or("");
    let body = after_fence
        .strip_prefix('\n')
        .unwrap_or(after_fence)
        .to_string();

    Some(SkillFront {
        name,
        description,
        body,
    })
}

/// Strip a single matched pair of surrounding quotes (YAML scalar convention).
fn unquote(value: &str) -> &str {
    let bytes = value.as_bytes();
    if bytes.len() >= 2 {
        let first = bytes[0];
        let last = bytes[bytes.len() - 1];
        if (first == b'"' && last == b'"') || (first == b'\'' && last == b'\'') {
            return &value[1..value.len() - 1];
        }
    }
    value
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_name_description_and_body() {
        let md = "---\nname: forge\ndescription: Tool creation workshop.\nmetadata:\n  author: fae\n  version: \"1.0\"\n---\n\nYou are operating Fae's Forge.\n";
        let front = parse_skill_md(md).expect("parse");
        assert_eq!(front.name, "forge");
        assert_eq!(front.description, "Tool creation workshop.");
        assert_eq!(front.body, "You are operating Fae's Forge.\n");
    }

    #[test]
    fn nested_blocks_are_ignored_not_promoted() {
        // `author`/`version` are nested under metadata: — they must NOT leak
        // into top-level name/description.
        let md = "---\nname: x\nmetadata:\n  name: not-this\n  description: not-this-either\n---\nbody\n";
        let front = parse_skill_md(md).expect("parse");
        assert_eq!(front.name, "x");
        assert_eq!(front.description, "");
    }

    #[test]
    fn missing_opening_fence_returns_none() {
        assert!(parse_skill_md("name: forge\n").is_none());
    }

    #[test]
    fn missing_closing_fence_returns_none() {
        assert!(parse_skill_md("---\nname: forge\nno closing fence\n").is_none());
    }

    #[test]
    fn missing_name_returns_none() {
        assert!(parse_skill_md("---\ndescription: only desc\n---\nbody").is_none());
    }

    #[test]
    fn crlf_frontmatter_parses() {
        let md = "---\r\nname: crlf\r\ndescription: works\r\n---\r\nbody\r\n";
        let front = parse_skill_md(md).expect("parse");
        assert_eq!(front.name, "crlf");
        assert_eq!(front.description, "works");
    }

    #[test]
    fn quoted_values_are_unquoted() {
        let md = "---\nname: \"quoted-name\"\ndescription: 'single'\n---\nbody";
        let front = parse_skill_md(md).expect("parse");
        assert_eq!(front.name, "quoted-name");
        assert_eq!(front.description, "single");
    }
}
