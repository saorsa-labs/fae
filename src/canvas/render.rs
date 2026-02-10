//! Content rendering — converts canvas-core `Element` variants to HTML.
//!
//! Each `ElementKind` variant has a dedicated render function that produces
//! HTML suitable for embedding in the Dioxus webview via `dangerous_inner_html`.

use canvas_core::{Element, ElementKind};

use super::session::html_escape;

/// Render a canvas-core `Element` to HTML.
///
/// Dispatches to the appropriate renderer based on `ElementKind`.
/// The `role_class` is an optional CSS class from the message role
/// (e.g. "user", "assistant") — only meaningful for `Text` elements
/// created via the message pipeline.
pub fn render_element_html(element: &Element, role_class: &str) -> String {
    match &element.kind {
        ElementKind::Text {
            content,
            color,
            font_size,
        } => render_text_html(content, color, *font_size, role_class),
        ElementKind::Chart { chart_type, data } => {
            render_chart_html(chart_type, data, &element.transform)
        }
        ElementKind::Image { src, .. } => render_image_html(src, &element.transform),
        ElementKind::Model3D {
            src,
            rotation,
            scale,
        } => render_model3d_html(src, rotation, *scale),
        ElementKind::Video { stream_id, .. } => render_video_placeholder(stream_id),
        ElementKind::OverlayLayer { .. } | ElementKind::Group { .. } => {
            // Groups/overlays have no direct HTML representation — their
            // children are rendered individually by the caller.
            String::new()
        }
    }
}

/// Render `ElementKind::Text` to HTML.
///
/// Uses markdown-aware rendering if the content looks like markdown,
/// otherwise produces a simple escaped `<div>`.
pub fn render_text_html(content: &str, color: &str, _font_size: f32, role_class: &str) -> String {
    if is_markdown(content) {
        let md_html = render_markdown_html(content);
        format!(
            "<div class=\"message {role_class} markdown\" style=\"color: {};\">{md_html}</div>",
            html_escape(color),
        )
    } else {
        format!(
            "<div class=\"message {role_class}\" style=\"color: {};\">{}</div>",
            html_escape(color),
            html_escape(content),
        )
    }
}

/// Render a chart element to an `<img>` with a base64 data URI.
///
/// Uses `canvas_renderer::chart` to produce an RGBA pixel buffer, encodes it
/// as PNG, then base64-encodes the PNG bytes.  If rendering fails, produces
/// a fallback `<div>` with the error message.
pub fn render_chart_html(
    chart_type: &str,
    data: &serde_json::Value,
    transform: &canvas_core::Transform,
) -> String {
    let width = transform.width.max(100.0) as u32;
    let height = transform.height.max(100.0) as u32;

    match render_chart_to_data_uri(chart_type, data, width, height) {
        Ok(data_uri) => {
            format!(
                "<div class=\"canvas-chart\"><img src=\"{data_uri}\" \
                 width=\"{width}\" height=\"{height}\" alt=\"{} chart\" /></div>",
                html_escape(chart_type),
            )
        }
        Err(e) => {
            format!(
                "<div class=\"canvas-chart-error\">\
                 Chart ({}) render failed: {}</div>",
                html_escape(chart_type),
                html_escape(&e),
            )
        }
    }
}

/// Render an image element to an `<img>` tag.
pub fn render_image_html(src: &str, transform: &canvas_core::Transform) -> String {
    let width = transform.width.max(1.0) as u32;
    let height = transform.height.max(1.0) as u32;

    // Data URIs and HTTP(S) URLs can be used directly.
    if src.starts_with("data:") || src.starts_with("http://") || src.starts_with("https://") {
        format!(
            "<div class=\"canvas-image\"><img src=\"{}\" \
             width=\"{width}\" height=\"{height}\" loading=\"lazy\" /></div>",
            html_escape(src),
        )
    } else {
        // Local file path — attempt to read and base64-encode.
        match encode_file_as_data_uri(src) {
            Ok(data_uri) => {
                format!(
                    "<div class=\"canvas-image\"><img src=\"{data_uri}\" \
                     width=\"{width}\" height=\"{height}\" /></div>",
                )
            }
            Err(e) => {
                format!(
                    "<div class=\"canvas-image-error\">\
                     Image load failed: {}</div>",
                    html_escape(&e),
                )
            }
        }
    }
}

/// Render a 3D model placeholder (actual 3D rendering is out of scope).
fn render_model3d_html(src: &str, rotation: &[f32; 3], scale: f32) -> String {
    format!(
        "<div class=\"canvas-model3d\">\
         <span class=\"model-label\">3D Model</span>\
         <span class=\"model-info\">{} | rot=[{:.1},{:.1},{:.1}] scale={:.1}</span>\
         </div>",
        html_escape(src),
        rotation[0],
        rotation[1],
        rotation[2],
        scale,
    )
}

/// Render a video placeholder.
fn render_video_placeholder(stream_id: &str) -> String {
    format!(
        "<div class=\"canvas-video\">\
         <span class=\"video-label\">Video Stream</span>\
         <span class=\"video-info\">{}</span>\
         </div>",
        html_escape(stream_id),
    )
}

// ---------------------------------------------------------------------------
// Markdown rendering
// ---------------------------------------------------------------------------

/// Heuristic: does the text look like it contains markdown?
///
/// We check for common markdown indicators. Plain conversational text
/// (which makes up most assistant responses) should not trigger this.
pub fn is_markdown(text: &str) -> bool {
    // Fast reject: very short text is rarely markdown.
    if text.len() < 4 {
        return false;
    }

    // Check for block-level indicators at line starts.
    for line in text.lines() {
        let trimmed = line.trim_start();
        if trimmed.starts_with("# ")
            || trimmed.starts_with("## ")
            || trimmed.starts_with("### ")
            || trimmed.starts_with("- ")
            || trimmed.starts_with("* ")
            || trimmed.starts_with("> ")
            || trimmed.starts_with("```")
            || trimmed.starts_with("| ")
        {
            return true;
        }
        // Numbered list: "1. ", "2. ", etc.
        if let Some(rest) = trimmed.strip_prefix(|c: char| c.is_ascii_digit())
            && rest.starts_with(". ")
        {
            return true;
        }
    }

    // Check for inline indicators.
    if text.contains("**") || text.contains("``") || text.contains("[](") {
        return true;
    }

    false
}

/// Render markdown text to HTML via `pulldown_cmark`.
///
/// Code blocks get syntax highlighting via `syntect`.
pub fn render_markdown_html(content: &str) -> String {
    use pulldown_cmark::{CodeBlockKind, Event, Options, Parser, Tag, TagEnd};

    let options =
        Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS;

    let parser = Parser::new_ext(content, options);

    let mut html_output = String::new();
    let mut code_buf = String::new();
    let mut code_lang = String::new();
    let mut in_code_block = false;

    for event in parser {
        match event {
            Event::Start(Tag::CodeBlock(kind)) => {
                in_code_block = true;
                code_buf.clear();
                code_lang = match kind {
                    CodeBlockKind::Fenced(lang) => lang.to_string(),
                    CodeBlockKind::Indented => String::new(),
                };
            }
            Event::End(TagEnd::CodeBlock) => {
                in_code_block = false;
                let highlighted = highlight_code_block(&code_buf, &code_lang);
                html_output.push_str(&highlighted);
            }
            Event::Text(text) if in_code_block => {
                code_buf.push_str(&text);
            }
            other => {
                if !in_code_block {
                    let mut tmp = String::new();
                    pulldown_cmark::html::push_html(&mut tmp, std::iter::once(other));
                    html_output.push_str(&tmp);
                }
            }
        }
    }

    html_output
}

// ---------------------------------------------------------------------------
// Syntax highlighting
// ---------------------------------------------------------------------------

/// Highlight a code block using `syntect`.
///
/// Returns a `<pre><code>` block with inline CSS colors.
/// Falls back to plain escaped code if the language is unknown or highlighting fails.
pub fn highlight_code_block(code: &str, lang: &str) -> String {
    use syntect::highlighting::ThemeSet;
    use syntect::html::highlighted_html_for_string;
    use syntect::parsing::SyntaxSet;

    let ss = SyntaxSet::load_defaults_newlines();
    let ts = ThemeSet::load_defaults();
    let theme = &ts.themes["base16-ocean.dark"];

    let syntax = if lang.is_empty() {
        ss.find_syntax_plain_text()
    } else {
        ss.find_syntax_by_token(lang)
            .unwrap_or_else(|| ss.find_syntax_plain_text())
    };

    match highlighted_html_for_string(code, &ss, syntax, theme) {
        Ok(highlighted) => {
            format!("<div class=\"code-block\" data-lang=\"{lang}\">{highlighted}</div>")
        }
        Err(_) => {
            format!(
                "<div class=\"code-block\"><pre><code>{}</code></pre></div>",
                html_escape(code),
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Render a chart to a base64-encoded PNG data URI.
fn render_chart_to_data_uri(
    chart_type: &str,
    data: &serde_json::Value,
    width: u32,
    height: u32,
) -> Result<String, String> {
    use base64::Engine as _;
    use canvas_renderer::chart::{parse_chart_config, render_chart_to_buffer};

    let config = parse_chart_config(chart_type, data, width, height).map_err(|e| format!("{e}"))?;
    let rgba = render_chart_to_buffer(&config).map_err(|e| format!("{e}"))?;

    // Encode RGBA buffer to PNG bytes.
    let png_bytes = encode_rgba_to_png(&rgba, width, height)?;

    let b64 = base64::engine::general_purpose::STANDARD.encode(&png_bytes);
    Ok(format!("data:image/png;base64,{b64}"))
}

/// Encode an RGBA pixel buffer to PNG bytes.
fn encode_rgba_to_png(rgba: &[u8], width: u32, height: u32) -> Result<Vec<u8>, String> {
    use image::ImageEncoder;

    let mut buf = Vec::new();
    let encoder = image::codecs::png::PngEncoder::new(&mut buf);
    encoder
        .write_image(rgba, width, height, image::ExtendedColorType::Rgba8)
        .map_err(|e| format!("PNG encode: {e}"))?;
    Ok(buf)
}

/// Read a local file and encode it as a data URI.
fn encode_file_as_data_uri(path: &str) -> Result<String, String> {
    use base64::Engine as _;

    let data = std::fs::read(path).map_err(|e| format!("read {path}: {e}"))?;

    // Guess MIME from extension.
    let mime = match std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
    {
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("svg") => "image/svg+xml",
        Some("webp") => "image/webp",
        Some("gif") => "image/gif",
        _ => "application/octet-stream",
    };

    let b64 = base64::engine::general_purpose::STANDARD.encode(&data);
    Ok(format!("data:{mime};base64,{b64}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use canvas_core::Transform;

    fn default_transform() -> Transform {
        Transform {
            x: 0.0,
            y: 0.0,
            width: 400.0,
            height: 300.0,
            rotation: 0.0,
            z_index: 0,
        }
    }

    // -- render_text_html -------------------------------------------------

    #[test]
    fn test_render_plain_text() {
        let html = render_text_html("Hello world", "#FFF", 14.0, "user");
        assert!(html.contains("class=\"message user\""));
        assert!(html.contains("Hello world"));
        assert!(!html.contains("markdown"));
    }

    #[test]
    fn test_render_markdown_text() {
        let html = render_text_html("# Title\n\nSome text", "#FFF", 14.0, "assistant");
        assert!(html.contains("markdown"));
        assert!(html.contains("<h1>"));
    }

    #[test]
    fn test_render_text_escapes_html() {
        let html = render_text_html("<script>bad</script>", "#FFF", 14.0, "user");
        assert!(!html.contains("<script>"));
        assert!(html.contains("&lt;script&gt;"));
    }

    // -- is_markdown ------------------------------------------------------

    #[test]
    fn test_is_markdown_headers() {
        assert!(is_markdown("# Hello"));
        assert!(is_markdown("## Section"));
        assert!(is_markdown("### Sub"));
    }

    #[test]
    fn test_is_markdown_lists() {
        assert!(is_markdown("- item one\n- item two"));
        assert!(is_markdown("* bullet"));
        assert!(is_markdown("1. numbered"));
    }

    #[test]
    fn test_is_markdown_code_fence() {
        assert!(is_markdown("```rust\nfn main() {}\n```"));
    }

    #[test]
    fn test_is_markdown_bold() {
        assert!(is_markdown("This is **bold** text"));
    }

    #[test]
    fn test_is_not_markdown_plain() {
        assert!(!is_markdown("Hello there!"));
        assert!(!is_markdown("I'm fine thanks."));
        assert!(!is_markdown("ok"));
    }

    #[test]
    fn test_is_markdown_short_text() {
        assert!(!is_markdown("Hi"));
        assert!(!is_markdown(""));
    }

    #[test]
    fn test_is_markdown_blockquote() {
        assert!(is_markdown("> This is a quote"));
    }

    #[test]
    fn test_is_markdown_table() {
        assert!(is_markdown("| col1 | col2 |\n|------|------|\n| a | b |"));
    }

    // -- render_markdown_html ---------------------------------------------

    #[test]
    fn test_markdown_renders_heading() {
        let html = render_markdown_html("# Hello");
        assert!(html.contains("<h1>"));
        assert!(html.contains("Hello"));
    }

    #[test]
    fn test_markdown_renders_bold() {
        let html = render_markdown_html("**bold** text");
        assert!(html.contains("<strong>bold</strong>"));
    }

    #[test]
    fn test_markdown_renders_list() {
        let html = render_markdown_html("- a\n- b\n- c");
        assert!(html.contains("<li>"));
    }

    #[test]
    fn test_markdown_renders_code_block() {
        let html = render_markdown_html("```rust\nlet x = 1;\n```");
        assert!(html.contains("code-block"));
    }

    // -- highlight_code_block ---------------------------------------------

    #[test]
    fn test_highlight_rust() {
        let html = highlight_code_block("fn main() {}", "rust");
        assert!(html.contains("code-block"));
        assert!(html.contains("data-lang=\"rust\""));
        // Syntect produces <pre> with colored spans.
        assert!(html.contains("<pre"));
    }

    #[test]
    fn test_highlight_unknown_lang() {
        let html = highlight_code_block("some code", "xyzlang");
        assert!(html.contains("code-block"));
        // Falls back to plain text syntax.
        assert!(html.contains("some code"));
    }

    #[test]
    fn test_highlight_empty_lang() {
        let html = highlight_code_block("raw text", "");
        assert!(html.contains("code-block"));
    }

    #[test]
    fn test_highlight_empty_code() {
        let html = highlight_code_block("", "rust");
        assert!(html.contains("code-block"));
    }

    // -- render_image_html ------------------------------------------------

    #[test]
    fn test_render_image_data_uri() {
        let t = default_transform();
        let html = render_image_html("data:image/png;base64,abc123", &t);
        assert!(html.contains("canvas-image"));
        assert!(html.contains("src=\"data:image/png;base64,abc123\""));
    }

    #[test]
    fn test_render_image_url() {
        let t = default_transform();
        let html = render_image_html("https://example.com/pic.png", &t);
        assert!(html.contains("canvas-image"));
        assert!(html.contains("loading=\"lazy\""));
    }

    #[test]
    fn test_render_image_local_not_found() {
        let t = default_transform();
        let html = render_image_html("/nonexistent/path.png", &t);
        assert!(html.contains("canvas-image-error"));
    }

    // -- render_chart_html ------------------------------------------------

    #[test]
    fn test_render_chart_bar() {
        let t = default_transform();
        let data = serde_json::json!({
            "labels": ["A", "B", "C"],
            "values": [10, 20, 30]
        });
        let html = render_chart_html("bar", &data, &t);
        // Should produce either a data URI image or an error div.
        assert!(
            html.contains("canvas-chart") || html.contains("canvas-chart-error"),
            "chart HTML: {html}"
        );
    }

    #[test]
    fn test_render_chart_bad_type() {
        let t = default_transform();
        let data = serde_json::json!({});
        let html = render_chart_html("nonexistent_type", &data, &t);
        assert!(html.contains("canvas-chart-error"));
    }

    // -- render_element_html dispatch -------------------------------------

    #[test]
    fn test_dispatch_text() {
        let el = Element::new(ElementKind::Text {
            content: "hello".into(),
            font_size: 14.0,
            color: "#FFF".into(),
        });
        let html = render_element_html(&el, "user");
        assert!(html.contains("hello"));
    }

    #[test]
    fn test_dispatch_model3d() {
        let el = Element::new(ElementKind::Model3D {
            src: "model.glb".into(),
            rotation: [1.0, 2.0, 3.0],
            scale: 1.5,
        });
        let html = render_element_html(&el, "");
        assert!(html.contains("canvas-model3d"));
        assert!(html.contains("model.glb"));
    }

    #[test]
    fn test_dispatch_video() {
        let el = Element::new(ElementKind::Video {
            stream_id: "stream-1".into(),
            is_live: true,
            mirror: false,
            crop: None,
            media_config: None,
        });
        let html = render_element_html(&el, "");
        assert!(html.contains("canvas-video"));
        assert!(html.contains("stream-1"));
    }

    #[test]
    fn test_dispatch_group_empty() {
        let el = Element::new(ElementKind::Group { children: vec![] });
        let html = render_element_html(&el, "");
        assert!(html.is_empty());
    }

    // -- model3d and video placeholders -----------------------------------

    #[test]
    fn test_model3d_placeholder() {
        let html = render_model3d_html("scene.glb", &[0.0, 90.0, 0.0], 2.0);
        assert!(html.contains("3D Model"));
        assert!(html.contains("scene.glb"));
        assert!(html.contains("scale=2.0"));
    }

    #[test]
    fn test_video_placeholder() {
        let html = render_video_placeholder("cam-0");
        assert!(html.contains("Video Stream"));
        assert!(html.contains("cam-0"));
    }
}
