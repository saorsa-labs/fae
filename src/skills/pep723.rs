//! PEP 723 inline script metadata parser.
//!
//! Extracts the `# /// script` TOML block from Python files as specified by
//! [PEP 723](https://peps.python.org/pep-0723/). This metadata declares
//! dependencies, required Python version, and tool-specific settings inline
//! within the script — no separate `pyproject.toml` needed.
//!
//! # Format
//!
//! ```python
//! # /// script
//! # requires-python = ">=3.11"
//! # dependencies = [
//! #     "requests>=2.31",
//! #     "rich",
//! # ]
//! # ///
//! ```

use std::collections::HashMap;
use std::path::Path;

/// Parsed PEP 723 script metadata.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ScriptMetadata {
    /// Python version constraint (e.g. `">=3.11"`).
    pub requires_python: Option<String>,
    /// Declared package dependencies.
    pub dependencies: Vec<String>,
    /// Tool-specific TOML sections (e.g. `tool.uv.sources`).
    pub tool_sections: HashMap<String, toml::Value>,
}

/// Parse PEP 723 inline metadata from a Python script file.
///
/// Reads the file at `script_path` and extracts the `# /// script` … `# ///`
/// block. Returns [`ScriptMetadata::default()`] if no metadata block is found
/// or if parsing fails gracefully.
///
/// # Errors
///
/// Returns an I/O error only if the file cannot be read.
pub fn parse_script_metadata(script_path: &Path) -> std::io::Result<ScriptMetadata> {
    let content = std::fs::read_to_string(script_path)?;
    Ok(parse_inline_metadata(&content))
}

/// Parse PEP 723 inline metadata from a string of Python source code.
///
/// Returns [`ScriptMetadata::default()`] if no metadata block is present or
/// if the embedded TOML is malformed.
pub fn parse_inline_metadata(source: &str) -> ScriptMetadata {
    let toml_str = match extract_metadata_block(source) {
        Some(s) => s,
        None => return ScriptMetadata::default(),
    };

    parse_toml_metadata(&toml_str)
}

/// Extract the raw TOML content between `# /// script` and `# ///` markers.
///
/// Returns `None` if no valid metadata block is found.
fn extract_metadata_block(source: &str) -> Option<String> {
    let mut in_block = false;
    let mut toml_lines = Vec::new();

    for line in source.lines() {
        let trimmed = line.trim();

        if !in_block {
            if trimmed == "# /// script" {
                in_block = true;
            }
            continue;
        }

        // End marker.
        if trimmed == "# ///" {
            break;
        }

        // Strip the `# ` prefix. Lines must start with `# ` or be just `#`.
        if let Some(rest) = trimmed.strip_prefix("# ") {
            toml_lines.push(rest.to_owned());
        } else if trimmed == "#" {
            // Blank line within the block.
            toml_lines.push(String::new());
        } else {
            // Non-comment line inside block — malformed, abort.
            return None;
        }
    }

    if toml_lines.is_empty() {
        return None;
    }

    Some(toml_lines.join("\n"))
}

/// Parse the extracted TOML into a [`ScriptMetadata`].
fn parse_toml_metadata(toml_str: &str) -> ScriptMetadata {
    let table: toml::Table = match toml::from_str(toml_str) {
        Ok(t) => t,
        Err(_) => return ScriptMetadata::default(),
    };

    let requires_python = table
        .get("requires-python")
        .and_then(|v| v.as_str())
        .map(str::to_owned);

    let dependencies = table
        .get("dependencies")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default();

    let tool_sections = table
        .get("tool")
        .and_then(|v| v.as_table())
        .map(|t| {
            t.iter()
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect()
        })
        .unwrap_or_default();

    ScriptMetadata {
        requires_python,
        dependencies,
        tool_sections,
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use std::io::Write;

    // -----------------------------------------------------------------------
    // extract_metadata_block
    // -----------------------------------------------------------------------

    #[test]
    fn extract_basic_block() {
        let source = r#"#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["requests"]
# ///

import requests
"#;
        let block = extract_metadata_block(source).unwrap();
        assert!(block.contains("requires-python"));
        assert!(block.contains("requests"));
    }

    #[test]
    fn extract_no_block_returns_none() {
        let source = "import sys\nprint('hello')\n";
        assert!(extract_metadata_block(source).is_none());
    }

    #[test]
    fn extract_empty_block_returns_none() {
        let source = "# /// script\n# ///\n";
        assert!(extract_metadata_block(source).is_none());
    }

    #[test]
    fn extract_with_blank_comment_lines() {
        let source = r#"# /// script
# requires-python = ">=3.11"
#
# dependencies = ["rich"]
# ///
"#;
        let block = extract_metadata_block(source).unwrap();
        assert!(block.contains("requires-python"));
        assert!(block.contains("rich"));
    }

    #[test]
    fn extract_malformed_non_comment_inside_block() {
        let source = r#"# /// script
# requires-python = ">=3.11"
import sys  # oops, not a comment
# ///
"#;
        assert!(extract_metadata_block(source).is_none());
    }

    // -----------------------------------------------------------------------
    // parse_inline_metadata
    // -----------------------------------------------------------------------

    #[test]
    fn parse_full_metadata() {
        let source = r#"# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "requests>=2.31",
#     "rich",
# ]
# ///

import requests
"#;
        let meta = parse_inline_metadata(source);
        assert_eq!(meta.requires_python.as_deref(), Some(">=3.11"));
        assert_eq!(meta.dependencies, vec!["requests>=2.31", "rich"]);
    }

    #[test]
    fn parse_no_metadata_returns_default() {
        let meta = parse_inline_metadata("print('hello')");
        assert_eq!(meta, ScriptMetadata::default());
    }

    #[test]
    fn parse_dependencies_only() {
        let source = r#"# /// script
# dependencies = ["numpy", "pandas>=2.0"]
# ///
"#;
        let meta = parse_inline_metadata(source);
        assert!(meta.requires_python.is_none());
        assert_eq!(meta.dependencies, vec!["numpy", "pandas>=2.0"]);
    }

    #[test]
    fn parse_requires_python_only() {
        let source = r#"# /// script
# requires-python = ">=3.12"
# ///
"#;
        let meta = parse_inline_metadata(source);
        assert_eq!(meta.requires_python.as_deref(), Some(">=3.12"));
        assert!(meta.dependencies.is_empty());
    }

    #[test]
    fn parse_with_tool_section() {
        let source = r#"# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx"]
#
# [tool.uv.sources]
# httpx = { git = "https://github.com/encode/httpx" }
# ///
"#;
        let meta = parse_inline_metadata(source);
        assert_eq!(meta.dependencies, vec!["httpx"]);
        assert!(meta.tool_sections.contains_key("uv"));
    }

    #[test]
    fn parse_malformed_toml_returns_default() {
        let source = r#"# /// script
# this is not valid toml {{{
# ///
"#;
        let meta = parse_inline_metadata(source);
        assert_eq!(meta, ScriptMetadata::default());
    }

    // -----------------------------------------------------------------------
    // parse_script_metadata (file-based)
    // -----------------------------------------------------------------------

    #[test]
    fn parse_from_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("script.py");
        let mut f = std::fs::File::create(&path).unwrap();
        writeln!(f, "# /// script").unwrap();
        writeln!(f, "# requires-python = \">=3.10\"").unwrap();
        writeln!(f, "# dependencies = [\"click\"]").unwrap();
        writeln!(f, "# ///").unwrap();
        writeln!(f, "import click").unwrap();

        let meta = parse_script_metadata(&path).unwrap();
        assert_eq!(meta.requires_python.as_deref(), Some(">=3.10"));
        assert_eq!(meta.dependencies, vec!["click"]);
    }

    #[test]
    fn parse_from_file_no_metadata() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("bare.py");
        std::fs::write(&path, "print('hello')").unwrap();

        let meta = parse_script_metadata(&path).unwrap();
        assert_eq!(meta, ScriptMetadata::default());
    }

    #[test]
    fn parse_from_nonexistent_file_returns_error() {
        let result = parse_script_metadata(Path::new("/nonexistent/script.py"));
        assert!(result.is_err());
    }

    // -----------------------------------------------------------------------
    // Round-trip: multiple dependency formats
    // -----------------------------------------------------------------------

    #[test]
    fn parse_complex_dependencies() {
        let source = r#"# /// script
# dependencies = [
#     "torch>=2.0",
#     "transformers[torch]",
#     "datasets>=2.14,<3.0",
#     "accelerate",
# ]
# ///
"#;
        let meta = parse_inline_metadata(source);
        assert_eq!(meta.dependencies.len(), 4);
        assert_eq!(meta.dependencies[0], "torch>=2.0");
        assert_eq!(meta.dependencies[1], "transformers[torch]");
        assert_eq!(meta.dependencies[2], "datasets>=2.14,<3.0");
        assert_eq!(meta.dependencies[3], "accelerate");
    }
}
