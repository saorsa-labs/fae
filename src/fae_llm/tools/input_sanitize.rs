//! Input sanitization utilities for tool arguments.
//!
//! Provides context-aware sanitization:
//! - Strict mode: for commands/paths (blocks shell metacharacters)
//! - Relaxed mode: for content fields (allows $, etc.)

/// Characters that enable shell injection when unquoted.
const SHELL_METACHARACTERS: &[char] = &[
    '\n',   // Command injection via newlines
    '\r',   // Carriage return
    '>',    // Output redirection
    '<',    // Input redirection
    '|',    // Pipe
    ';',    // Command separator
    '&',    // Background execution
    '$',    // Variable substitution
    '`',    // Command substitution
    '\\',   // Escape character
    '\x1b', // ESC (terminal control)
];

/// Control characters that should be blocked in commands.
const CONTROL_CHARS: &[char] = &[
    '\x00', // Null
    '\x01', '\x02', '\x03', '\x04', '\x05', '\x06', '\x07', '\x08', // Backspace
    '\x0b', // Vertical tab
    '\x0c', // Form feed
    '\x0e', '\x0f', '\x10', '\x11', '\x12', '\x13', '\x14', '\x15', '\x16', '\x17', '\x18', '\x19',
    '\x1a', // Substitute
    '\x1c', '\x1d', '\x1e', '\x1f',
];

/// Result of sanitizing input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SanitizedInput {
    /// The sanitized string.
    pub content: String,
    /// Whether any characters were removed.
    pub modified: bool,
    /// List of character categories that were removed.
    pub removed_categories: Vec<String>,
}

impl SanitizedInput {
    fn new(content: String) -> Self {
        Self {
            content,
            modified: false,
            removed_categories: Vec::new(),
        }
    }

    fn with_category(mut self, category: &str) -> Self {
        self.modified = true;
        self.removed_categories.push(category.to_string());
        self
    }
}

/// Sanitize a string for use as a command or path argument.
///
/// Uses strict mode: removes shell metacharacters and control characters.
/// This is appropriate for command names, path components, and values
/// that will be passed to the shell.
pub fn sanitize_command_input(input: &str) -> SanitizedInput {
    let mut result = String::with_capacity(input.len());
    let mut removed_metachar = false;
    let mut removed_control = false;

    for ch in input.chars() {
        if SHELL_METACHARACTERS.contains(&ch) {
            removed_metachar = true;
            continue;
        }
        if CONTROL_CHARS.contains(&ch) {
            removed_control = true;
            continue;
        }
        result.push(ch);
    }

    let mut sanitized = SanitizedInput::new(result);
    if removed_metachar {
        sanitized = sanitized.with_category("shell_metacharacters");
    }
    if removed_control {
        sanitized = sanitized.with_category("control_characters");
    }

    sanitized
}

/// Sanitize a string for use as file content.
///
/// Uses relaxed mode: only removes null bytes and other clearly dangerous
/// characters. Preserves $, backticks, pipes, etc. for shell scripts,
/// templates, and other legitimate content.
pub fn sanitize_content_input(input: &str) -> SanitizedInput {
    let mut result = String::with_capacity(input.len());
    let mut removed_null = false;

    for ch in input.chars() {
        // Only remove null bytes and other clearly problematic chars
        if ch == '\x00' {
            removed_null = true;
            continue;
        }
        result.push(ch);
    }

    let mut sanitized = SanitizedInput::new(result);
    if removed_null {
        sanitized = sanitized.with_category("null_bytes");
    }

    sanitized
}

/// Check if a string contains shell metacharacters without modifying it.
pub fn contains_shell_metacharacters(input: &str) -> bool {
    input
        .chars()
        .any(|ch| SHELL_METACHARACTERS.contains(&ch) || CONTROL_CHARS.contains(&ch))
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── Strict sanitization (command input) ───────────────────

    #[test]
    fn sanitize_command_blocks_newline() {
        let input = "echo hello\nwhoami";
        let result = sanitize_command_input(input);
        assert!(!result.content.contains('\n'));
        assert!(result.modified);
    }

    #[test]
    fn sanitize_command_blocks_redirect() {
        let input = "cat file.txt > output.txt";
        let result = sanitize_command_input(input);
        assert!(!result.content.contains('>'));
        assert!(result.modified);
    }

    #[test]
    fn sanitize_command_blocks_pipe() {
        let input = "cat file | grep pattern";
        let result = sanitize_command_input(input);
        assert!(!result.content.contains('|'));
        assert!(result.modified);
    }

    #[test]
    fn sanitize_command_blocks_semicolon() {
        let input = "echo a; rm -rf /";
        let result = sanitize_command_input(input);
        assert!(!result.content.contains(';'));
        assert!(result.modified);
    }

    #[test]
    fn sanitize_command_blocks_dollar() {
        let input = "echo $HOME";
        let result = sanitize_command_input(input);
        assert!(!result.content.contains('$'));
        assert!(result.modified);
    }

    #[test]
    fn sanitize_command_blocks_backtick() {
        let input = "echo `ls`";
        let result = sanitize_command_input(input);
        assert!(!result.content.contains('`'));
        assert!(result.modified);
    }

    #[test]
    fn sanitize_command_blocks_control_chars() {
        let input = "hello\x01world\x02";
        let result = sanitize_command_input(input);
        assert!(!result.content.contains('\x01'));
        assert!(!result.content.contains('\x02'));
        assert!(result.modified);
    }

    #[test]
    fn sanitize_command_preserves_safe() {
        let input = "ls -la /home/user";
        let result = sanitize_command_input(input);
        assert_eq!(result.content, input);
        assert!(!result.modified);
    }

    #[test]
    fn sanitize_command_reports_categories() {
        let input = "echo $HOME\nls";
        let result = sanitize_command_input(input);
        assert!(result.modified);
        assert!(
            result
                .removed_categories
                .iter()
                .any(|c| c == "shell_metacharacters")
        );
    }

    // ── Relaxed sanitization (content input) ───────────────────

    #[test]
    fn sanitize_content_allows_dollar() {
        let input = "echo $HOME\nVAR=value";
        let result = sanitize_content_input(input);
        assert_eq!(result.content, input);
        assert!(!result.modified);
    }

    #[test]
    fn sanitize_content_allows_pipes_and_redirects() {
        let input = "cat file.txt | grep pattern > output.txt";
        let result = sanitize_content_input(input);
        assert_eq!(result.content, input);
        assert!(!result.modified);
    }

    #[test]
    fn sanitize_content_blocks_null() {
        let input = "hello\x00world";
        let result = sanitize_content_input(input);
        assert!(!result.content.contains('\x00'));
        assert!(result.modified);
    }

    #[test]
    fn sanitize_content_preserves_backtick() {
        let input = "echo `date`";
        let result = sanitize_content_input(input);
        assert_eq!(result.content, input);
        assert!(!result.modified);
    }

    // ── Detection ─────────────────────────────────────────────

    #[test]
    fn contains_shell_metacharacters_detects() {
        assert!(contains_shell_metacharacters("echo $HOME"));
        assert!(contains_shell_metacharacters("cat > file"));
        assert!(contains_shell_metacharacters("ls | wc"));
        assert!(contains_shell_metacharacters("cmd\narg"));
        assert!(!contains_shell_metacharacters("echo hello"));
        assert!(!contains_shell_metacharacters("ls -la"));
    }
}
