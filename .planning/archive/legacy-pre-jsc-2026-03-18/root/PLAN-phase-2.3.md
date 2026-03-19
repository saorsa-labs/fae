# Phase 2.3: Content Extraction (fetch_page_content)

Implement HTML content extraction so `fetch_page_content()` returns clean readable text from any URL.

## Prerequisites (Done in Phase 2.1-2.2)

- `fae-search` crate with reqwest, scraper dependencies
- `PageContent` type defined in `types.rs`
- `SearchError` with Http and Parse variants
- `http::build_client()` for configured reqwest client
- `fetch_page_content()` stub in `lib.rs`

## Tasks

---

## Task 1: Create content extraction module

Create `fae-search/src/content.rs` with HTML parsing and boilerplate removal.

**Implementation:**

```rust
pub const DEFAULT_MAX_CHARS: usize = 100_000;

pub fn extract_content(html: &str, url: &str) -> Result<PageContent>
pub fn extract_content_with_limit(html: &str, url: &str, max_chars: usize) -> Result<PageContent>
```

**Extraction logic:**
1. Parse HTML with `scraper::Html::parse_document()`
2. Extract title from `<title>` tag
3. Remove boilerplate elements: `script`, `style`, `nav`, `footer`, `header`, `aside`, `[role="navigation"]`, `[role="banner"]`, `[role="complementary"]`, `noscript`, `svg`, `iframe`
4. Try content selectors in priority order: `article`, `main`, `[role="main"]`, `.content`, `#content`, then fall back to `body`
5. Extract text, normalise whitespace (collapse multiple newlines/spaces)
6. Count words (split on whitespace)
7. Truncate to max_chars if needed

**Files:**
- Create: `fae-search/src/content.rs`

**Acceptance criteria:**
- Extracts title from HTML
- Strips scripts, styles, nav, footer, aside
- Prefers article/main content over full body
- Normalises whitespace
- Counts words accurately
- Truncates to configurable limit
- No unwrap/expect in production code

---

## Task 2: Wire fetch_page_content() in lib.rs

Replace the stub with real implementation.

**Implementation:**
1. Add `pub mod content;` to lib.rs
2. Implement `fetch_page_content()`:
   - Build HTTP client via `http::build_client()` with default config
   - GET the URL, check status
   - Get response text
   - Call `content::extract_content()`
   - Return PageContent

**Files:**
- Modify: `fae-search/src/lib.rs`

**Acceptance criteria:**
- Stub replaced with working implementation
- Uses existing `http::build_client()`
- Returns proper errors for HTTP failures
- Returns proper errors for parse failures
- Existing stub test updated to expect success or meaningful error

---

## Task 3: Unit tests with sample HTML

Add tests for content extraction covering all extraction paths.

**Tests:**
- Extract title from `<title>` tag
- Extract content from `<article>` tag
- Fall back to `<body>` when no article
- Strip script and style tags
- Strip nav, footer, header, aside
- Handle empty HTML gracefully
- Handle HTML with no title
- Word count accuracy
- Max chars truncation
- Whitespace normalisation

**Files:**
- Add tests in: `fae-search/src/content.rs`
- Update test in: `fae-search/src/lib.rs` (stub test -> real test)

**Acceptance criteria:**
- All extraction paths tested
- Edge cases covered (empty HTML, no title, no content)
- Tests pass without network access
