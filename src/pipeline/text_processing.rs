//! Pure text-processing helpers extracted from `coordinator.rs`.

/// Strip all punctuation and normalize whitespace.
pub(crate) fn strip_punctuation(text: &str) -> String {
    text.chars()
        .filter(|c| c.is_alphanumeric() || c.is_whitespace())
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Expand common English contractions.
#[cfg(test)]
pub(crate) fn expand_contractions(text: &str) -> String {
    text.replace("that'll", "that will")
        .replace("i'll", "i will")
        .replace("i'm", "i am")
        .replace("i've", "i have")
        .replace("i'd", "i would")
        .replace("you'll", "you will")
        .replace("you're", "you are")
        .replace("you've", "you have")
        .replace("you'd", "you would")
        .replace("we'll", "we will")
        .replace("we're", "we are")
        .replace("we've", "we have")
        .replace("they'll", "they will")
        .replace("they're", "they are")
        .replace("they've", "they have")
        .replace("he'll", "he will")
        .replace("she'll", "she will")
        .replace("it'll", "it will")
        .replace("it's", "it is")
        .replace("can't", "cannot")
        .replace("won't", "will not")
        .replace("don't", "do not")
        .replace("doesn't", "does not")
        .replace("didn't", "did not")
        .replace("isn't", "is not")
        .replace("wasn't", "was not")
        .replace("weren't", "were not")
        .replace("wouldn't", "would not")
        .replace("couldn't", "could not")
        .replace("shouldn't", "should not")
}

/// Capitalize the first character of a string.
#[cfg(test)]
pub(crate) fn capitalize_first(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) => {
            let mut result = c.to_uppercase().to_string();
            result.push_str(chars.as_str());
            result
        }
        None => String::new(),
    }
}

/// Strip markdown code fences from text. Removes leading/trailing
/// ` ```json ` / ` ``` ` markers that models sometimes wrap JSON in.
pub(crate) fn strip_markdown_fences(text: &str) -> String {
    let mut s = text.to_owned();
    // Remove opening fence: ```json or ```
    if let Some(start) = s.find("```") {
        let fence_end = s[start + 3..]
            .find('\n')
            .map(|i| start + 3 + i + 1)
            .unwrap_or(start + 3);
        s.replace_range(start..fence_end, "");
    }
    // Remove closing fence
    if let Some(end) = s.rfind("```") {
        s.replace_range(end..end + 3, "");
    }
    s
}

/// Extract the outermost `{...}` JSON object from `text`, accounting
/// for nested braces and quoted strings. Returns the slice if balanced
/// braces are found, `None` otherwise.
pub(crate) fn extract_json_object(text: &str) -> Option<&str> {
    let start = text.find('{')?;
    let mut depth: i32 = 0;
    let mut in_string = false;
    let mut escape_next = false;

    for (i, ch) in text[start..].char_indices() {
        if escape_next {
            escape_next = false;
            continue;
        }
        match ch {
            '\\' if in_string => escape_next = true,
            '"' => in_string = !in_string,
            '{' if !in_string => depth += 1,
            '}' if !in_string => {
                depth -= 1;
                if depth == 0 {
                    return Some(&text[start..start + i + 1]);
                }
            }
            _ => {}
        }
    }
    None
}

/// Clean up common JSON formatting issues from local LLM output.
///
/// Local models sometimes output values like `1 billion` or `1.25 billion`
/// instead of proper numeric literals. This function normalizes those
/// patterns so the JSON can be parsed by serde.
pub(crate) fn clean_model_json(text: &str) -> String {
    let mut result = text.to_owned();

    // Process multiplier words from largest to smallest.
    for (word, multiplier) in [
        (" trillion", 1_000_000_000_000_f64),
        (" billion", 1_000_000_000_f64),
        (" million", 1_000_000_f64),
    ] {
        while let Some(word_pos) = result.find(word) {
            // Walk backward from the space before the word to find the number.
            let before = &result[..word_pos];
            let num_start = before
                .rfind(|c: char| !c.is_ascii_digit() && c != '.')
                .map_or(0, |i| i + 1);
            let num_str = &result[num_start..word_pos];

            if let Ok(n) = num_str.parse::<f64>() {
                let expanded = format!("{}", (n * multiplier) as i64);
                result.replace_range(num_start..word_pos + word.len(), &expanded);
            } else {
                // Can't parse the preceding text as a number; leave it and
                // break to avoid an infinite loop.
                break;
            }
        }
    }

    result
}
