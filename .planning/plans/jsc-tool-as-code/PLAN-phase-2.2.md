# Phase 2.2: Core Tool Structured Results

## Goal
Add structured results to the tools most likely to benefit JS orchestration first.

## Scope
- `calendar`
- `reminders`
- `contacts`
- `mail`
- `notes`
- `web_search`
- `fetch_url`

## Tasks
- Add structured outputs alongside existing prose.
- Normalize date/time and identity fields for script use.
- Add tests covering both prose and structured variants.

## Acceptance
- These tools all expose stable structured results.
- Existing human-readable responses remain intact.

## Validation
```bash
cd native/macos/Fae
swift build
swift test
```
