//! HTML content extraction — strips boilerplate and returns readable text.
//!
//! Parses raw HTML, removes non-content elements (scripts, styles, navigation),
//! finds the main content area, and returns clean readable text suitable for
//! LLM consumption.

use crate::error::{Result, SearchError};
use crate::types::PageContent;
use scraper::{Html, Selector};

/// Default maximum characters to return from extracted content.
pub const DEFAULT_MAX_CHARS: usize = 100_000;

/// Extract readable text content from raw HTML.
///
/// Parses the HTML, strips boilerplate (scripts, styles, navigation, ads),
/// finds the main content area, and returns clean text with metadata.
///
/// # Errors
///
/// Returns [`SearchError::Parse`] if no extractable content is found.
pub fn extract_content(html: &str, url: &str) -> Result<PageContent> {
    extract_content_with_limit(html, url, DEFAULT_MAX_CHARS)
}

/// Extract readable text content from raw HTML with a custom character limit.
///
/// Same as [`extract_content`] but allows specifying the maximum number of
/// characters to return in the extracted text.
///
/// # Errors
///
/// Returns [`SearchError::Parse`] if no extractable content is found.
pub fn extract_content_with_limit(html: &str, url: &str, max_chars: usize) -> Result<PageContent> {
    let cleaned_html = strip_boilerplate_tags(html);
    let document = Html::parse_document(&cleaned_html);

    let title = extract_title(&document);
    let raw_text = extract_main_text(&document);

    let text = normalise_whitespace(&raw_text);
    if text.is_empty() {
        return Err(SearchError::Parse("no extractable content found".into()));
    }

    let text = truncate_to_limit(&text, max_chars);
    let word_count = text.split_whitespace().count();

    Ok(PageContent {
        url: url.to_owned(),
        title,
        text,
        word_count,
    })
}

/// Extract the page title from the `<title>` element.
fn extract_title(document: &Html) -> String {
    let Ok(selector) = Selector::parse("title") else {
        return String::new();
    };
    document
        .select(&selector)
        .next()
        .map(|el| el.text().collect::<String>())
        .unwrap_or_default()
        .trim()
        .to_owned()
}

/// Extract text from the main content area of the document.
///
/// Tries content-specific selectors in priority order, falling back to `<body>`.
fn extract_main_text(document: &Html) -> String {
    let content_selectors = ["article", "main", "[role=\"main\"]", "body"];

    for selector_str in &content_selectors {
        let Ok(selector) = Selector::parse(selector_str) else {
            continue;
        };
        if let Some(element) = document.select(&selector).next() {
            let text: String = element.text().collect::<Vec<_>>().join(" ");
            let trimmed = text.trim();
            if !trimmed.is_empty() {
                return trimmed.to_owned();
            }
        }
    }

    String::new()
}

/// Remove boilerplate HTML tags and their content before parsing.
///
/// Strips `<script>`, `<style>`, `<nav>`, `<footer>`, `<header>`, `<aside>`,
/// `<noscript>`, `<svg>`, and `<iframe>` elements including all their content.
fn strip_boilerplate_tags(html: &str) -> String {
    let tags = [
        "script", "style", "nav", "footer", "header", "aside", "noscript", "svg", "iframe",
    ];

    let mut result = html.to_owned();
    for tag in &tags {
        result = strip_tag(&result, tag);
    }
    result
}

/// Remove all instances of a specific HTML tag and its content.
fn strip_tag(html: &str, tag: &str) -> String {
    let mut result = String::with_capacity(html.len());
    let lower = html.to_lowercase();
    let open_tag = format!("<{tag}");
    let close_tag = format!("</{tag}>");

    let mut pos = 0;
    loop {
        // Find the next opening tag (case-insensitive).
        let start = match lower[pos..].find(&open_tag) {
            Some(offset) => pos + offset,
            None => {
                result.push_str(&html[pos..]);
                break;
            }
        };

        // Verify this is actually the target tag (not e.g. <navigate> for <nav>).
        let after_tag = start + open_tag.len();
        if after_tag < lower.len() {
            let next_byte = lower.as_bytes()[after_tag];
            if next_byte != b' '
                && next_byte != b'>'
                && next_byte != b'/'
                && next_byte != b'\n'
                && next_byte != b'\r'
                && next_byte != b'\t'
            {
                result.push_str(&html[pos..after_tag]);
                pos = after_tag;
                continue;
            }
        }

        // Add everything before this tag.
        result.push_str(&html[pos..start]);

        // Find the matching closing tag.
        let end = match lower[start..].find(&close_tag) {
            Some(offset) => start + offset + close_tag.len(),
            None => {
                // No closing tag — skip to end of the opening tag.
                match lower[start..].find('>') {
                    Some(offset) => start + offset + 1,
                    None => html.len(),
                }
            }
        };

        pos = end;
    }

    result
}

/// Collapse excess whitespace: multiple spaces become one, 3+ newlines become 2.
fn normalise_whitespace(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut prev_was_space = false;
    let mut newline_count: u32 = 0;

    for ch in text.chars() {
        if ch == '\n' || ch == '\r' {
            newline_count += 1;
            prev_was_space = false;
            if newline_count <= 2 {
                result.push('\n');
            }
        } else if ch.is_whitespace() {
            newline_count = 0;
            if !prev_was_space {
                result.push(' ');
                prev_was_space = true;
            }
        } else {
            newline_count = 0;
            prev_was_space = false;
            result.push(ch);
        }
    }

    result
        .lines()
        .map(str::trim)
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_owned()
}

/// Truncate text to the given character limit, breaking at a char boundary.
fn truncate_to_limit(text: &str, max_chars: usize) -> String {
    if text.len() <= max_chars {
        return text.to_owned();
    }

    let mut end = max_chars;
    while !text.is_char_boundary(end) && end > 0 {
        end -= 1;
    }

    let mut truncated = text[..end].to_owned();
    truncated.push_str("\n\n[Content truncated]");
    truncated
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_title_from_html() {
        let html = "<html><head><title>My Page Title</title></head><body>Content</body></html>";
        let result = extract_content(html, "https://example.com");
        assert!(result.is_ok());
        let page = result.unwrap();
        assert_eq!(page.title, "My Page Title");
    }

    #[test]
    fn extract_title_empty_when_missing() {
        let html = "<html><body>Content here</body></html>";
        let result = extract_content(html, "https://example.com");
        assert!(result.is_ok());
        let page = result.unwrap();
        assert!(page.title.is_empty());
    }

    #[test]
    fn extract_content_from_article() {
        let html = r#"<html><body>
            <nav>Navigation stuff</nav>
            <article>Article content here</article>
            <footer>Footer stuff</footer>
        </body></html>"#;
        let result = extract_content(html, "https://example.com");
        assert!(result.is_ok());
        let page = result.unwrap();
        assert!(page.text.contains("Article content"));
        assert!(!page.text.contains("Navigation"));
        assert!(!page.text.contains("Footer"));
    }

    #[test]
    fn fallback_to_body() {
        let html = "<html><body>Body content only</body></html>";
        let result = extract_content(html, "https://example.com");
        assert!(result.is_ok());
        let page = result.unwrap();
        assert!(page.text.contains("Body content"));
    }

    #[test]
    fn strip_script_tags() {
        let html = r#"<html><body>
            <p>Real content</p>
            <script>var x = 1; alert('hi');</script>
        </body></html>"#;
        let result = extract_content(html, "https://example.com");
        assert!(result.is_ok());
        let page = result.unwrap();
        assert!(page.text.contains("Real content"));
        assert!(!page.text.contains("alert"));
        assert!(!page.text.contains("var x"));
    }

    #[test]
    fn strip_style_tags() {
        let html = r#"<html><body>
            <p>Styled content</p>
            <style>.foo { color: red; }</style>
        </body></html>"#;
        let result = extract_content(html, "https://example.com");
        assert!(result.is_ok());
        let page = result.unwrap();
        assert!(page.text.contains("Styled content"));
        assert!(!page.text.contains("color: red"));
    }

    #[test]
    fn strip_nav_footer_header_aside() {
        let html = r#"<html><body>
            <header>Header content</header>
            <nav>Nav links</nav>
            <main>Main content</main>
            <aside>Sidebar stuff</aside>
            <footer>Footer info</footer>
        </body></html>"#;
        let result = extract_content(html, "https://example.com");
        assert!(result.is_ok());
        let page = result.unwrap();
        assert!(page.text.contains("Main content"));
        assert!(!page.text.contains("Header content"));
        assert!(!page.text.contains("Nav links"));
        assert!(!page.text.contains("Sidebar stuff"));
        assert!(!page.text.contains("Footer info"));
    }

    #[test]
    fn word_count_accuracy() {
        let html = "<html><body>One two three four five</body></html>";
        let result = extract_content(html, "https://example.com");
        assert!(result.is_ok());
        let page = result.unwrap();
        assert_eq!(page.word_count, 5);
    }

    #[test]
    fn max_chars_truncation() {
        let long_text = "word ".repeat(1000);
        let html = format!("<html><body>{long_text}</body></html>");
        let result = extract_content_with_limit(&html, "https://example.com", 100);
        assert!(result.is_ok());
        let page = result.unwrap();
        // 100 chars + "\n\n[Content truncated]" suffix
        assert!(page.text.len() <= 125);
        assert!(page.text.contains("[Content truncated]"));
    }

    #[test]
    fn empty_html_returns_parse_error() {
        let result = extract_content("", "https://example.com");
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.to_string().contains("no extractable content"));
    }

    #[test]
    fn whitespace_only_html_returns_parse_error() {
        let html = "<html><body>   \n\n\n   </body></html>";
        let result = extract_content(html, "https://example.com");
        assert!(result.is_err());
    }

    #[test]
    fn whitespace_normalisation() {
        let html = "<html><body>Word1    Word2\n\n\n\n\nWord3</body></html>";
        let result = extract_content(html, "https://example.com");
        assert!(result.is_ok());
        let page = result.unwrap();
        assert!(!page.text.contains("  "));
        assert!(!page.text.contains("\n\n\n"));
    }

    #[test]
    fn url_preserved_in_output() {
        let html = "<html><body>Content</body></html>";
        let result = extract_content(html, "https://test.example.com/page");
        assert!(result.is_ok());
        let page = result.unwrap();
        assert_eq!(page.url, "https://test.example.com/page");
    }

    #[test]
    fn nav_tag_not_confused_with_similar_tags() {
        let html = "<html><body><nav>Skip this</nav><p>Keep this navigate text</p></body></html>";
        let result = extract_content(html, "https://example.com");
        assert!(result.is_ok());
        let page = result.unwrap();
        assert!(!page.text.contains("Skip this"));
        assert!(page.text.contains("navigate text"));
    }

    #[test]
    fn strip_noscript_and_iframe() {
        let html = r#"<html><body>
            <p>Visible content</p>
            <noscript>Enable JS please</noscript>
            <iframe src="ad.html">Ad frame</iframe>
        </body></html>"#;
        let result = extract_content(html, "https://example.com");
        assert!(result.is_ok());
        let page = result.unwrap();
        assert!(page.text.contains("Visible content"));
        assert!(!page.text.contains("Enable JS"));
        assert!(!page.text.contains("Ad frame"));
    }

    #[test]
    fn main_content_preferred_over_body() {
        let html = r#"<html><body>
            <div>Outer div</div>
            <main>Main content area</main>
        </body></html>"#;
        let result = extract_content(html, "https://example.com");
        assert!(result.is_ok());
        let page = result.unwrap();
        assert!(page.text.contains("Main content area"));
    }

    #[test]
    fn default_max_chars_constant() {
        assert_eq!(DEFAULT_MAX_CHARS, 100_000);
    }

    #[test]
    fn truncate_respects_char_boundaries() {
        // Create text with multi-byte characters
        let text = "Hello ".to_owned() + &"é".repeat(200);
        let html = format!("<html><body>{text}</body></html>");
        let result = extract_content_with_limit(&html, "https://example.com", 50);
        assert!(result.is_ok());
        // Should not panic on char boundary issues
    }
}
