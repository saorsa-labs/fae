//! Minimal Hugging Face REST API client (blocking).
//!
//! This is used for model discovery in the GUI (search, model info, README snippet,
//! and GGUF file size via HEAD requests). Keep it small and resilient: the UI
//! should handle errors gracefully and never panic.

use serde::Deserialize;
use std::time::Duration;

#[derive(Debug, thiserror::Error)]
pub enum HfApiError {
    #[error("http error: {0}")]
    Http(String),
    #[error("json error: {0}")]
    Json(String),
}

#[derive(Debug, Clone)]
pub struct ModelSearchItem {
    pub id: String,
    pub likes: Option<u64>,
    pub downloads: Option<u64>,
    pub tags: Vec<String>,
    pub pipeline_tag: Option<String>,
    pub library_name: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ModelInfo {
    pub id: String,
    pub tags: Vec<String>,
    pub license: Option<String>,
    pub base_models: Vec<String>,
    pub gated: Option<bool>,
    pub siblings: Vec<String>,
    pub gguf: Option<GgufInfo>,
}

#[derive(Debug, Clone)]
pub struct GgufInfo {
    pub architecture: Option<String>,
    pub context_length: Option<u64>,
    pub chat_template: Option<String>,
    pub eos_token: Option<String>,
    pub total_bytes: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct SearchItemWire {
    // Hugging Face APIs sometimes include both `id` and `modelId`. Using
    // `serde(alias=...)` would treat that as a duplicate field. Keep both and
    // prefer `id` when present.
    #[serde(default)]
    id: Option<String>,
    #[serde(rename = "modelId", default)]
    model_id: Option<String>,
    likes: Option<u64>,
    downloads: Option<u64>,
    tags: Option<Vec<String>>,
    pipeline_tag: Option<String>,
    library_name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ModelInfoWire {
    #[serde(default)]
    id: Option<String>,
    #[serde(rename = "modelId", default)]
    model_id: Option<String>,
    tags: Option<Vec<String>>,
    gated: Option<bool>,
    #[serde(rename = "cardData")]
    card_data: Option<CardDataWire>,
    gguf: Option<GgufWire>,
    siblings: Option<Vec<SiblingWire>>,
}

#[derive(Debug, Deserialize)]
struct CardDataWire {
    license: Option<String>,
    base_model: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
struct SiblingWire {
    rfilename: String,
}

#[derive(Debug, Deserialize)]
struct GgufWire {
    total: Option<u64>,
    architecture: Option<String>,
    context_length: Option<u64>,
    chat_template: Option<String>,
    eos_token: Option<String>,
}

fn http_agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(10))
        .timeout_read(Duration::from_secs(20))
        .timeout_write(Duration::from_secs(20))
        .build()
}

fn parse_json<T: for<'de> Deserialize<'de>>(body: &str) -> Result<T, HfApiError> {
    serde_json::from_str(body).map_err(|e| HfApiError::Json(e.to_string()))
}

/// Search Hugging Face models via the public API.
pub fn search_models(
    query: &str,
    filter_gguf: bool,
    pipeline_tag: Option<&str>,
    limit: usize,
) -> Result<Vec<ModelSearchItem>, HfApiError> {
    let agent = http_agent();

    let mut url = format!(
        "https://huggingface.co/api/models?search={}&limit={}",
        urlencoding::encode(query),
        limit.max(1)
    );
    if filter_gguf {
        url.push_str("&filter=gguf");
    }
    if let Some(tag) = pipeline_tag {
        url.push_str("&pipeline_tag=");
        url.push_str(&urlencoding::encode(tag));
    }

    let resp = agent
        .get(&url)
        .set("User-Agent", "fae/0.1 (model picker)")
        .call()
        .map_err(|e| HfApiError::Http(e.to_string()))?;

    let body = resp
        .into_string()
        .map_err(|e| HfApiError::Http(e.to_string()))?;
    let items: Vec<SearchItemWire> = parse_json(&body)?;

    Ok(items
        .into_iter()
        .filter_map(|w| {
            let id = w.id.or(w.model_id)?;
            Some(ModelSearchItem {
                id,
                likes: w.likes,
                downloads: w.downloads,
                tags: w.tags.unwrap_or_default(),
                pipeline_tag: w.pipeline_tag,
                library_name: w.library_name,
            })
        })
        .collect())
}

/// Fetch detailed model info including siblings (filenames) and GGUF metadata when available.
pub fn get_model_info(model_id: &str) -> Result<ModelInfo, HfApiError> {
    let agent = http_agent();
    let url = format!("https://huggingface.co/api/models/{model_id}");

    let resp = agent
        .get(&url)
        .set("User-Agent", "fae/0.1 (model picker)")
        .call()
        .map_err(|e| HfApiError::Http(e.to_string()))?;
    let body = resp
        .into_string()
        .map_err(|e| HfApiError::Http(e.to_string()))?;

    let w: ModelInfoWire = parse_json(&body)?;
    let id = w.id.or(w.model_id).ok_or_else(|| {
        HfApiError::Json("missing model id (expected `id` or `modelId`)".to_owned())
    })?;
    let siblings = w
        .siblings
        .unwrap_or_default()
        .into_iter()
        .map(|s| s.rfilename)
        .collect::<Vec<_>>();

    let gguf = w.gguf.map(|g| GgufInfo {
        architecture: g.architecture,
        context_length: g.context_length,
        chat_template: g.chat_template,
        eos_token: g.eos_token,
        total_bytes: g.total,
    });

    let base_models = w
        .card_data
        .as_ref()
        .and_then(|c| c.base_model.as_ref())
        .and_then(|v| {
            if let Some(s) = v.as_str() {
                return Some(vec![s.to_owned()]);
            }
            if let Some(arr) = v.as_array() {
                let mut out = Vec::new();
                for item in arr {
                    if let Some(s) = item.as_str() {
                        out.push(s.to_owned());
                    }
                }
                return Some(out);
            }
            None
        })
        .unwrap_or_default();

    Ok(ModelInfo {
        id,
        tags: w.tags.unwrap_or_default(),
        license: w.card_data.as_ref().and_then(|c| c.license.clone()),
        base_models,
        gated: w.gated,
        siblings,
        gguf,
    })
}

fn first_paragraph(markdown: &str) -> Option<String> {
    // Extremely simple snippet extraction:
    // - strip leading BOM/whitespace
    // - skip headings, HTML comments, and code fences
    // - return the first "paragraph-ish" block (non-empty consecutive lines)
    let mut in_code = false;
    let mut buf: Vec<String> = Vec::new();

    for raw_line in markdown.lines() {
        let line = raw_line.trim();
        if line.starts_with("```") {
            in_code = !in_code;
            continue;
        }
        if in_code {
            continue;
        }
        if line.is_empty() {
            if !buf.is_empty() {
                break;
            }
            continue;
        }
        if (line.starts_with('#') || line.starts_with("<!--")) && buf.is_empty() {
            continue;
        }
        // Skip badges / image-only lines.
        if buf.is_empty() && (line.starts_with("![") || line.starts_with("[![")) {
            continue;
        }
        buf.push(line.to_owned());
        if buf.join(" ").len() >= 400 {
            break;
        }
    }

    if buf.is_empty() {
        None
    } else {
        Some(buf.join(" "))
    }
}

/// Best-effort README snippet (first paragraph).
pub fn readme_snippet(model_id: &str) -> Result<Option<String>, HfApiError> {
    let agent = http_agent();
    let urls = [
        format!("https://huggingface.co/{model_id}/raw/main/README.md"),
        format!("https://huggingface.co/{model_id}/resolve/main/README.md"),
    ];

    for url in urls {
        let resp = agent
            .get(&url)
            .set("User-Agent", "fae/0.1 (model picker)")
            .call();

        let Ok(resp) = resp else { continue };
        let Ok(body) = resp.into_string() else {
            continue;
        };

        // Limit processing cost; the HTTP client already downloaded it, but we can
        // still keep parsing bounded.
        let prefix = if body.len() > 32 * 1024 {
            &body[..32 * 1024]
        } else {
            &body
        };
        if let Some(p) = first_paragraph(prefix) {
            return Ok(Some(p));
        }
        return Ok(None);
    }

    Ok(None)
}

fn head_follow_location(
    agent: &ureq::Agent,
    url: &str,
    max_hops: usize,
) -> Result<ureq::Response, HfApiError> {
    let mut current = url.to_owned();
    for _ in 0..=max_hops {
        let resp = agent
            .head(&current)
            .set("User-Agent", "fae/0.1 (model picker)")
            .call()
            .map_err(|e| HfApiError::Http(e.to_string()))?;
        let status = resp.status();
        if (300..400).contains(&status)
            && let Some(loc) = resp.header("Location")
        {
            current = loc.to_owned();
            continue;
        }
        return Ok(resp);
    }
    Err(HfApiError::Http("too many redirects".to_owned()))
}

/// Best-effort GGUF file size via `HEAD` on the `resolve/main/...` URL.
///
/// Returns `Ok(None)` if the size could not be determined.
pub fn gguf_file_size_bytes(
    model_id: &str,
    gguf_filename: &str,
) -> Result<Option<u64>, HfApiError> {
    let agent = http_agent();
    let url = format!("https://huggingface.co/{model_id}/resolve/main/{gguf_filename}");

    let resp = head_follow_location(&agent, &url, 3)?;
    if let Some(len) = resp.header("Content-Length")
        && let Ok(v) = len.parse::<u64>()
    {
        return Ok(Some(v));
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::{ModelInfoWire, SearchItemWire};

    #[test]
    fn deserializes_with_both_id_and_model_id() {
        let body = r#"{"id":"a/b","modelId":"a/b","likes":1,"downloads":2}"#;
        let w: SearchItemWire = serde_json::from_str(body).expect("wire must deserialize");
        let id = w.id.or(w.model_id).expect("id must exist");
        assert_eq!(id, "a/b");

        let body = r#"{"id":"c/d","modelId":"c/d","tags":["x"],"gated":false}"#;
        let w: ModelInfoWire = serde_json::from_str(body).expect("wire must deserialize");
        let id = w.id.or(w.model_id).expect("id must exist");
        assert_eq!(id, "c/d");
    }
}
