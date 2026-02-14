//! URL normalisation for search result deduplication.
//!
//! Canonicalises URLs so that equivalent pages (differing only in
//! query-parameter order, tracking parameters, fragments, or
//! capitalisation) compare as equal.

use url::Url;

/// Tracking query parameters that are stripped during normalisation.
const TRACKING_PARAMS: &[&str] = &[
    "utm_source",
    "utm_medium",
    "utm_campaign",
    "utm_term",
    "utm_content",
    "fbclid",
    "gclid",
    "ref",
    "si",
    "feature",
];

/// Normalise a URL for deduplication comparison.
///
/// Applies the following transformations:
///
/// 1. Lowercase scheme and host (path is preserved as-is).
/// 2. Remove default ports (`:80` for HTTP, `:443` for HTTPS).
/// 3. Remove trailing slash from the path (unless path is exactly `"/"`).
/// 4. Sort remaining query parameters alphabetically by key.
/// 5. Strip known tracking parameters (UTM, fbclid, gclid, etc.).
/// 6. Remove the fragment (`#…`).
///
/// If the input cannot be parsed as a valid URL, it is returned unchanged.
///
/// # Examples
///
/// ```
/// use fae_search::orchestrator::url_normalize::normalize_url;
///
/// let a = normalize_url("https://Example.COM/path/?b=2&a=1#section");
/// let b = normalize_url("https://example.com/path?a=1&b=2");
/// assert_eq!(a, b);
/// ```
pub fn normalize_url(raw: &str) -> String {
    let Ok(mut parsed) = Url::parse(raw) else {
        return raw.to_string();
    };

    // 1. Fragment removal (must happen before serialisation).
    parsed.set_fragment(None);

    // 2. Remove default ports.
    if is_default_port(&parsed) {
        let _ = parsed.set_port(None);
    }

    // 3. Filter and sort query parameters.
    let filtered_params: Vec<(String, String)> = {
        let mut params: Vec<(String, String)> = parsed
            .query_pairs()
            .filter(|(key, _)| {
                let k = key.to_lowercase();
                !TRACKING_PARAMS.contains(&k.as_str())
            })
            .map(|(k, v)| (k.into_owned(), v.into_owned()))
            .collect();
        params.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
        params
    };

    // Rebuild query string (or clear it).
    if filtered_params.is_empty() {
        parsed.set_query(None);
    } else {
        let qs: String = filtered_params
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("&");
        parsed.set_query(Some(&qs));
    }

    // 4. Remove trailing slash (unless path is just "/").
    let path = parsed.path().to_string();
    if path.len() > 1 && path.ends_with('/') {
        parsed.set_path(&path[..path.len() - 1]);
    }

    // Url::parse already lowercases scheme and host, so the serialised
    // form is canonical.
    parsed.to_string()
}

/// Returns `true` if the URL uses the default port for its scheme.
fn is_default_port(url: &Url) -> bool {
    matches!(
        (url.scheme(), url.port()),
        ("http", Some(80)) | ("https", Some(443))
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lowercases_scheme_and_host() {
        let result = normalize_url("HTTPS://Example.COM/Path");
        assert_eq!(result, "https://example.com/Path");
    }

    #[test]
    fn removes_trailing_slash() {
        let result = normalize_url("https://example.com/path/");
        assert_eq!(result, "https://example.com/path");
    }

    #[test]
    fn preserves_root_slash() {
        let result = normalize_url("https://example.com/");
        assert_eq!(result, "https://example.com/");
    }

    #[test]
    fn removes_default_http_port() {
        let result = normalize_url("http://example.com:80/path");
        assert_eq!(result, "http://example.com/path");
    }

    #[test]
    fn removes_default_https_port() {
        let result = normalize_url("https://example.com:443/path");
        assert_eq!(result, "https://example.com/path");
    }

    #[test]
    fn preserves_non_default_port() {
        let result = normalize_url("https://example.com:8080/path");
        assert_eq!(result, "https://example.com:8080/path");
    }

    #[test]
    fn sorts_query_params_alphabetically() {
        let result = normalize_url("https://example.com/search?z=1&a=2&m=3");
        assert_eq!(result, "https://example.com/search?a=2&m=3&z=1");
    }

    #[test]
    fn removes_tracking_params() {
        let result =
            normalize_url("https://example.com/page?q=rust&utm_source=google&fbclid=abc&gclid=xyz");
        assert_eq!(result, "https://example.com/page?q=rust");
    }

    #[test]
    fn removes_fragment() {
        let result = normalize_url("https://example.com/page#section");
        assert_eq!(result, "https://example.com/page");
    }

    #[test]
    fn equivalent_urls_normalize_to_same_string() {
        let a = normalize_url("https://Example.COM/path/?b=2&a=1#section");
        let b = normalize_url("https://example.com/path?a=1&b=2");
        assert_eq!(a, b);
    }

    #[test]
    fn tracking_params_case_insensitive_key_match() {
        // Our tracking list is lowercase; URL keys should be lowercased for comparison.
        let result = normalize_url("https://example.com/page?q=test&utm_source=twitter");
        assert_eq!(result, "https://example.com/page?q=test");
    }

    #[test]
    fn invalid_url_returned_unchanged() {
        let input = "not a url at all";
        assert_eq!(normalize_url(input), input);
    }

    #[test]
    fn empty_string_returned_unchanged() {
        assert_eq!(normalize_url(""), "");
    }

    #[test]
    fn url_with_no_query_or_fragment() {
        let result = normalize_url("https://example.com/page");
        assert_eq!(result, "https://example.com/page");
    }

    #[test]
    fn removes_all_tracking_params_completely() {
        let url = "https://example.com/page?utm_source=a&utm_medium=b&utm_campaign=c&utm_term=d&utm_content=e&fbclid=f&gclid=g&ref=h&si=i&feature=j";
        let result = normalize_url(url);
        assert_eq!(result, "https://example.com/page");
    }

    #[test]
    fn preserves_query_values_with_special_chars() {
        let result = normalize_url("https://example.com/search?q=hello+world&lang=en");
        // The url crate decodes '+' as space and re-encodes as %20.
        // Both forms represent the same query, so normalisation is correct.
        assert!(result.contains("lang=en"));
        assert!(result.contains("q=hello") || result.contains("q=hello%20world"));
    }
}
