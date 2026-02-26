//! Misaki G2P (grapheme-to-phoneme) wrapper for Kokoro.
//!
//! Converts English text to phoneme strings that can be tokenized
//! by Kokoro's character-level tokenizer. Includes a text normalization
//! pass that fixes smart quotes, expands abbreviations/ordinals/currency,
//! and strips markdown artifacts before phonemization.

use crate::error::{Result, SpeechError};

/// Thin wrapper around `misaki-rs` G2P for phonemization.
pub struct Phonemizer {
    g2p: misaki_rs::G2P,
}

impl Phonemizer {
    /// Create a new phonemizer.
    ///
    /// `british` selects British English pronunciation when `true`,
    /// American English when `false`.
    pub fn new(british: bool) -> Self {
        let lang = if british {
            misaki_rs::Language::EnglishGB
        } else {
            misaki_rs::Language::EnglishUS
        };
        Self {
            g2p: misaki_rs::G2P::new(lang),
        }
    }

    /// Convert text to a phoneme string suitable for Kokoro's tokenizer.
    ///
    /// Text is normalized before phonemization to fix smart quotes,
    /// expand abbreviations, ordinals, and currency symbols, and
    /// strip markdown artifacts.
    ///
    /// # Errors
    ///
    /// Returns an error if phonemization fails.
    pub fn phonemize(&self, text: &str) -> Result<String> {
        let normalized = normalize_text(text);
        let (phonemes, _tokens) = self
            .g2p
            .g2p(&normalized)
            .map_err(|e| SpeechError::Tts(format!("phonemization failed: {e}")))?;
        if phonemes.is_empty() {
            return Err(SpeechError::Tts(
                "phonemization produced empty output".into(),
            ));
        }
        Ok(phonemes)
    }
}

// ---------------------------------------------------------------------------
// Text normalization
// ---------------------------------------------------------------------------

/// Normalize text for TTS pronunciation.
///
/// Applies the following transformations in order:
/// 1. Smart/curly quote → ASCII equivalents
/// 2. Em/en dash → spaced hyphen
/// 3. Strip markdown artifacts (`*`, `**`, `#` headings)
/// 4. Expand currency symbols (`$5` → `5 dollars`)
/// 5. Expand ordinals (`1st` → `first`)
/// 6. Expand common abbreviations (`Dr.` → `Doctor`)
pub fn normalize_text(text: &str) -> String {
    let text = normalize_quotes(text);
    let text = strip_markdown(&text);
    let text = expand_currency(&text);
    let text = expand_ordinals(&text);
    expand_abbreviations(&text)
}

/// Replace smart/curly quotes and dashes with ASCII equivalents.
fn normalize_quotes(text: &str) -> String {
    text.replace(['\u{2018}', '\u{2019}'], "'")
        .replace(['\u{201C}', '\u{201D}'], "\"")
        .replace(['\u{2014}', '\u{2013}'], " - ")
}

/// Strip markdown bold/italic markers and heading `#` prefixes.
fn strip_markdown(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    for line in text.lines() {
        let trimmed = line.trim_start();
        // Strip leading `# ` heading markers (e.g. "## Title" → "Title")
        let line_content = if trimmed.starts_with('#') {
            let without_hashes = trimmed.trim_start_matches('#');
            without_hashes.trim_start()
        } else {
            line
        };
        // Strip `*` (bold/italic markers) — we remove all `*` characters
        for ch in line_content.chars() {
            if ch != '*' {
                result.push(ch);
            }
        }
        result.push('\n');
    }
    // Remove the trailing newline we always append
    if result.ends_with('\n') {
        result.pop();
    }
    result
}

/// Expand currency symbols: `$5` → `5 dollars`, `£12` → `12 pounds`, `€8` → `8 euros`.
///
/// Only handles simple integer amounts immediately following the symbol.
fn expand_currency(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let chars: Vec<char> = text.chars().collect();
    let len = chars.len();
    let mut i = 0;

    while i < len {
        let ch = chars[i];
        let currency_word = match ch {
            '$' => Some("dollars"),
            '£' => Some("pounds"),
            '€' => Some("euros"),
            _ => None,
        };

        if let Some(word) = currency_word {
            // Collect digits following the symbol
            let start = i + 1;
            let mut end = start;
            while end < len && chars[end].is_ascii_digit() {
                end += 1;
            }
            if end > start {
                let digits: String = chars[start..end].iter().collect();
                result.push_str(&digits);
                result.push(' ');
                result.push_str(word);
                i = end;
                continue;
            }
        }

        result.push(ch);
        i += 1;
    }

    result
}

/// Expand ordinal numbers: `1st` → `first`, `22nd` → `twenty second`, etc.
fn expand_ordinals(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let bytes = text.as_bytes();
    let len = bytes.len();
    let mut i = 0;

    while i < len {
        // Look for a digit
        if bytes[i].is_ascii_digit() {
            // Collect the full number
            let num_start = i;
            while i < len && bytes[i].is_ascii_digit() {
                i += 1;
            }
            let num_str = &text[num_start..i];

            // Check for ordinal suffix (st, nd, rd, th)
            if i + 1 < len {
                let suffix = &text[i..i + 2];
                let is_ordinal = matches!(
                    suffix.to_ascii_lowercase().as_str(),
                    "st" | "nd" | "rd" | "th"
                );
                // Make sure suffix is not part of a longer word
                let after_suffix = i + 2;
                let suffix_ends_word =
                    after_suffix >= len || !bytes[after_suffix].is_ascii_alphabetic();

                if is_ordinal
                    && suffix_ends_word
                    && let Some(word) = ordinal_word(num_str)
                {
                    result.push_str(word);
                    i += 2; // skip suffix
                    continue;
                }
            }

            // Not an ordinal — emit the digits as-is
            result.push_str(num_str);
            continue;
        }

        result.push(bytes[i] as char);
        i += 1;
    }

    result
}

/// Return the English word for an ordinal given as a digit string, or `None`
/// for numbers outside the supported range.
fn ordinal_word(digits: &str) -> Option<&'static str> {
    let n: u32 = match digits.parse() {
        Ok(v) => v,
        Err(_) => return None,
    };
    match n {
        1 => Some("first"),
        2 => Some("second"),
        3 => Some("third"),
        4 => Some("fourth"),
        5 => Some("fifth"),
        6 => Some("sixth"),
        7 => Some("seventh"),
        8 => Some("eighth"),
        9 => Some("ninth"),
        10 => Some("tenth"),
        11 => Some("eleventh"),
        12 => Some("twelfth"),
        13 => Some("thirteenth"),
        14 => Some("fourteenth"),
        15 => Some("fifteenth"),
        16 => Some("sixteenth"),
        17 => Some("seventeenth"),
        18 => Some("eighteenth"),
        19 => Some("nineteenth"),
        20 => Some("twentieth"),
        21 => Some("twenty first"),
        22 => Some("twenty second"),
        23 => Some("twenty third"),
        24 => Some("twenty fourth"),
        25 => Some("twenty fifth"),
        26 => Some("twenty sixth"),
        27 => Some("twenty seventh"),
        28 => Some("twenty eighth"),
        29 => Some("twenty ninth"),
        30 => Some("thirtieth"),
        31 => Some("thirty first"),
        _ => None,
    }
}

/// Expand common abbreviations to their spoken forms.
///
/// Only matches abbreviations at word boundaries (preceded by whitespace or
/// start-of-string, followed by whitespace or end-of-string).
fn expand_abbreviations(text: &str) -> String {
    /// Abbreviation → expansion pairs. Order matters: longer prefixes first
    /// to avoid partial matches (e.g. "Mrs." before "Mr.").
    const ABBREVS: &[(&str, &str)] = &[
        ("Mrs.", "Missus"),
        ("Mr.", "Mister"),
        ("Ms.", "Miz"),
        ("Dr.", "Doctor"),
        ("St.", "Saint"),
        ("vs.", "versus"),
        ("etc.", "etcetera"),
        ("e.g.", "for example"),
        ("i.e.", "that is"),
    ];

    let mut result = text.to_string();
    for &(abbrev, expansion) in ABBREVS {
        result = replace_word_boundary(&result, abbrev, expansion);
    }
    result
}

/// Replace `pattern` with `replacement` only when `pattern` appears at a word
/// boundary (start-of-string or preceded by whitespace, and followed by
/// whitespace or end-of-string).
fn replace_word_boundary(text: &str, pattern: &str, replacement: &str) -> String {
    if pattern.is_empty() {
        return text.to_string();
    }

    let mut result = String::with_capacity(text.len());
    let mut remaining = text;

    while let Some(pos) = remaining.find(pattern) {
        // Check preceding character — must be start-of-remaining (which could
        // be start-of-text or right after our last replacement), or whitespace.
        let at_word_start = pos == 0 || {
            let before = remaining.as_bytes()[pos - 1];
            before == b' ' || before == b'\t' || before == b'\n' || before == b'\r'
        };

        let after_pos = pos + pattern.len();
        let at_word_end = after_pos >= remaining.len() || {
            let after = remaining.as_bytes()[after_pos];
            after == b' ' || after == b'\t' || after == b'\n' || after == b'\r'
        };

        if at_word_start && at_word_end {
            result.push_str(&remaining[..pos]);
            result.push_str(replacement);
            remaining = &remaining[after_pos..];
        } else {
            // Not at word boundary — copy up to and including the match start,
            // then keep scanning from just past it.
            result.push_str(&remaining[..pos + 1]);
            remaining = &remaining[pos + 1..];
        }
    }

    result.push_str(remaining);
    result
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    // -----------------------------------------------------------------------
    // Smart quote normalization
    // -----------------------------------------------------------------------

    #[test]
    fn test_smart_single_quotes() {
        assert_eq!(normalize_quotes("I\u{2019}ve"), "I've");
        assert_eq!(normalize_quotes("\u{2018}hello\u{2019}"), "'hello'");
    }

    #[test]
    fn test_smart_double_quotes() {
        assert_eq!(
            normalize_quotes("She said \u{201C}hi\u{201D}"),
            "She said \"hi\""
        );
    }

    #[test]
    fn test_em_en_dashes() {
        assert_eq!(normalize_quotes("word\u{2014}word"), "word - word");
        assert_eq!(normalize_quotes("2020\u{2013}2025"), "2020 - 2025");
    }

    // -----------------------------------------------------------------------
    // Markdown stripping
    // -----------------------------------------------------------------------

    #[test]
    fn test_strip_heading_markers() {
        assert_eq!(strip_markdown("## Hello World"), "Hello World");
        assert_eq!(strip_markdown("# Title"), "Title");
        assert_eq!(strip_markdown("### Deep"), "Deep");
    }

    #[test]
    fn test_strip_bold_italic() {
        assert_eq!(strip_markdown("This is **bold** text"), "This is bold text");
        assert_eq!(strip_markdown("This is *italic*"), "This is italic");
    }

    #[test]
    fn test_strip_preserves_normal_text() {
        assert_eq!(strip_markdown("Just normal text"), "Just normal text");
    }

    // -----------------------------------------------------------------------
    // Currency expansion
    // -----------------------------------------------------------------------

    #[test]
    fn test_dollar_expansion() {
        assert_eq!(expand_currency("$5"), "5 dollars");
        assert_eq!(
            expand_currency("costs $100 today"),
            "costs 100 dollars today"
        );
    }

    #[test]
    fn test_pound_expansion() {
        assert_eq!(expand_currency("£12"), "12 pounds");
    }

    #[test]
    fn test_euro_expansion() {
        assert_eq!(expand_currency("€8"), "8 euros");
    }

    #[test]
    fn test_currency_no_digits() {
        // Symbol without digits stays as-is
        assert_eq!(expand_currency("$ amount"), "$ amount");
    }

    // -----------------------------------------------------------------------
    // Ordinal expansion
    // -----------------------------------------------------------------------

    #[test]
    fn test_common_ordinals() {
        assert_eq!(expand_ordinals("1st"), "first");
        assert_eq!(expand_ordinals("2nd"), "second");
        assert_eq!(expand_ordinals("3rd"), "third");
        assert_eq!(expand_ordinals("4th"), "fourth");
        assert_eq!(expand_ordinals("11th"), "eleventh");
        assert_eq!(expand_ordinals("21st"), "twenty first");
        assert_eq!(expand_ordinals("31st"), "thirty first");
    }

    #[test]
    fn test_ordinal_in_sentence() {
        assert_eq!(
            expand_ordinals("the 1st day of the 3rd month"),
            "the first day of the third month"
        );
    }

    #[test]
    fn test_ordinal_out_of_range() {
        // Numbers beyond 31 stay as digits
        assert_eq!(expand_ordinals("100th"), "100th");
    }

    #[test]
    fn test_ordinal_not_word_suffix() {
        // "1strange" should not trigger ordinal expansion
        assert_eq!(expand_ordinals("1strange"), "1strange");
    }

    // -----------------------------------------------------------------------
    // Abbreviation expansion
    // -----------------------------------------------------------------------

    #[test]
    fn test_abbreviation_dr() {
        assert_eq!(expand_abbreviations("Dr. Smith"), "Doctor Smith");
    }

    #[test]
    fn test_abbreviation_mr_mrs() {
        assert_eq!(expand_abbreviations("Mr. Jones"), "Mister Jones");
        assert_eq!(expand_abbreviations("Mrs. Jones"), "Missus Jones");
    }

    #[test]
    fn test_abbreviation_ms() {
        assert_eq!(expand_abbreviations("Ms. Lee"), "Miz Lee");
    }

    #[test]
    fn test_abbreviation_eg_ie() {
        assert_eq!(expand_abbreviations("e.g. cats"), "for example cats");
        assert_eq!(expand_abbreviations("i.e. dogs"), "that is dogs");
    }

    #[test]
    fn test_abbreviation_etc() {
        assert_eq!(
            expand_abbreviations("cats, dogs, etc."),
            "cats, dogs, etcetera"
        );
    }

    #[test]
    fn test_abbreviation_vs() {
        assert_eq!(expand_abbreviations("cats vs. dogs"), "cats versus dogs");
    }

    #[test]
    fn test_abbreviation_st() {
        assert_eq!(expand_abbreviations("St. Louis"), "Saint Louis");
    }

    // -----------------------------------------------------------------------
    // Full pipeline
    // -----------------------------------------------------------------------

    #[test]
    fn test_normalize_text_combined() {
        let input = "I\u{2019}ve got $5 on the 1st of the month, Dr. Smith said.";
        let output = normalize_text(input);
        assert_eq!(
            output,
            "I've got 5 dollars on the first of the month, Doctor Smith said."
        );
    }

    #[test]
    fn test_normalize_text_markdown_and_quotes() {
        let input = "## \u{201C}Hello\u{201D}\u{2014}**world**";
        let output = normalize_text(input);
        assert_eq!(output, "\"Hello\" - world");
    }

    #[test]
    fn test_normalize_text_empty() {
        assert_eq!(normalize_text(""), "");
    }

    #[test]
    fn test_normalize_text_no_changes() {
        let input = "Plain text with nothing to normalize";
        assert_eq!(normalize_text(input), input);
    }
}
