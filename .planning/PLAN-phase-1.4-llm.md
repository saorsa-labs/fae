# Phase 1.4: Tool Registry & Implementations

## Overview

Build the tool-calling system for fae_llm with a registry-based architecture. Four core tools (read, bash, edit, write) with JSON Schema validation, mode gating (read_only vs full), and bounded output. Tools are the bridge between LLM function calls and system operations.

**Architecture:**
- Tool trait with name/description/schema/execute lifecycle
- ToolRegistry with mode-based gating and tool lookup
- Each tool in its own submodule: `tools/read.rs`, `tools/bash.rs`, `tools/edit.rs`, `tools/write.rs`
- JSON Schema for argument validation (via `serde_json::Value`)
- ToolResult for success/error handling (bounded output)
- Path validation prevents sandbox escapes and system file writes

**Key Constraints:**
- Zero `.unwrap()` or `.expect()` — use proper error handling
- All tests must pass without modification
- TDD: Write tests first, then implement
- ~50 lines per task (smallest possible increments)

---

## Tasks

### Task 1: Tool trait and ToolResult type

**Description:**
Define the core `Tool` trait and `ToolResult` type that all tools will implement. The trait provides name, description, JSON Schema, and execution. ToolResult captures success/error and enforces bounded output limits.

**Files:**
- Create `src/fae_llm/tools/mod.rs`
- Create `src/fae_llm/tools/types.rs`

**Key types/functions:**
```rust
/// Result of tool execution
pub struct ToolResult {
    pub success: bool,
    pub content: String,      // bounded output
    pub error: Option<String>,
    pub truncated: bool,      // true if output was truncated
}

/// Core tool interface
pub trait Tool: Send + Sync {
    fn name(&self) -> &str;
    fn description(&self) -> &str;
    fn schema(&self) -> serde_json::Value;
    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError>;
    fn allowed_in_mode(&self, mode: ToolMode) -> bool;
}
```

**Tests:**
- ToolResult construction with success/error variants
- ToolResult respects max_bytes limit and sets truncated flag
- Tool trait bounds are Send + Sync
- allowed_in_mode returns correct boolean for read_only vs full

**Dependencies:**
- `serde_json` (already in Cargo.toml)
- Imports `FaeLlmError`, `ToolMode` from existing types

---

### Task 2: ToolRegistry with mode gating

**Description:**
Implement ToolRegistry that holds registered tools, looks them up by name, validates mode permissions, and provides schema export for LLM API calls.

**Files:**
- Create `src/fae_llm/tools/registry.rs`
- Update `src/fae_llm/tools/mod.rs` to export ToolRegistry

**Key types/functions:**
```rust
pub struct ToolRegistry {
    tools: HashMap<String, Arc<dyn Tool>>,
    mode: ToolMode,
}

impl ToolRegistry {
    pub fn new(mode: ToolMode) -> Self;
    pub fn register(&mut self, tool: Arc<dyn Tool>);
    pub fn get(&self, name: &str) -> Option<Arc<dyn Tool>>;
    pub fn list_available(&self) -> Vec<&str>;  // respects mode gating
    pub fn schemas_for_api(&self) -> Vec<serde_json::Value>;  // export for LLM
    pub fn set_mode(&mut self, mode: ToolMode);
}
```

**Tests:**
- Register multiple tools and retrieve by name
- list_available() only returns tools allowed in current mode
- get() returns None for tools not allowed in current mode
- schemas_for_api() returns JSON array of tool schemas
- set_mode() changes available tools dynamically

**Dependencies:**
- `std::collections::HashMap`
- `std::sync::Arc`

---

### Task 3: Read tool implementation

**Description:**
Implement the read tool that reads file contents with offset/limit pagination and bounded output. Validates file exists, is readable, and enforces max_bytes truncation.

**Files:**
- Create `src/fae_llm/tools/read.rs`
- Update `src/fae_llm/tools/mod.rs` to export ReadTool

**Key types/functions:**
```rust
pub struct ReadTool {
    max_bytes: usize,  // default 100KB
}

impl Tool for ReadTool {
    fn name(&self) -> &str { "read" }
    fn description(&self) -> &str { "Read file contents..." }
    fn schema(&self) -> serde_json::Value {
        // JSON Schema: {path: str, offset?: int, limit?: int}
    }
    fn execute(&self, args: Value) -> Result<ToolResult, FaeLlmError>;
    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        true  // allowed in both modes
    }
}
```

**Tests:**
- Read entire file returns correct content
- Read with offset/limit returns correct slice
- Read nonexistent file returns error ToolResult
- Read with no read permission returns error
- Output truncated at max_bytes boundary
- Schema validation rejects missing path argument

**Dependencies:**
- `std::fs` (already available)
- `serde_json` for args parsing

---

### Task 4: Bash tool implementation

**Description:**
Implement the bash tool that executes shell commands with timeout, bounded output (stdout + stderr merged), and optional cancellation. Uses `tokio::process::Command` for async execution.

**Files:**
- Create `src/fae_llm/tools/bash.rs`
- Update `src/fae_llm/tools/mod.rs` to export BashTool

**Key types/functions:**
```rust
pub struct BashTool {
    max_bytes: usize,       // default 100KB
    timeout_secs: u64,      // default 30s
}

impl Tool for BashTool {
    fn name(&self) -> &str { "bash" }
    fn description(&self) -> &str { "Execute shell command..." }
    fn schema(&self) -> serde_json::Value {
        // JSON Schema: {command: str, timeout?: int}
    }
    fn execute(&self, args: Value) -> Result<ToolResult, FaeLlmError>;
    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        mode == ToolMode::Full  // only in full mode
    }
}
```

**Tests:**
- Execute simple command (echo hello) returns stdout
- Command timeout triggers TimeoutError
- Command with large output is truncated at max_bytes
- Nonzero exit code returns error ToolResult with stderr
- Schema validation rejects empty command
- allowed_in_mode returns false for read_only mode

**Dependencies:**
- `tokio::process::Command` (tokio already in Cargo.toml)
- `tokio::time::timeout` for command timeout

---

### Task 5: Path validation utilities

**Description:**
Implement path validation helpers that prevent directory traversal, absolute path escapes, and writes to system directories. Used by edit and write tools.

**Files:**
- Create `src/fae_llm/tools/path_validation.rs`
- Update `src/fae_llm/tools/mod.rs` to export path validation functions

**Key functions:**
```rust
/// Validate path is safe for reading
pub fn validate_read_path(path: &str) -> Result<PathBuf, FaeLlmError>;

/// Validate path is safe for writing (no system dirs)
pub fn validate_write_path(path: &str) -> Result<PathBuf, FaeLlmError>;

/// Check if path escapes sandbox (../ or absolute paths)
pub fn is_path_safe(path: &str) -> bool;

/// Check if path is in restricted system directory
pub fn is_system_path(path: &Path) -> bool;
```

**Tests:**
- validate_read_path accepts relative paths
- validate_read_path rejects ../ traversal
- validate_write_path rejects /etc, /usr, /System paths
- validate_write_path accepts user directories
- is_path_safe returns false for absolute paths
- is_system_path returns true for /bin, /usr/bin, etc.

**Dependencies:**
- `std::path::{Path, PathBuf}`
- `std::fs::canonicalize` for path resolution

---

### Task 6: Edit tool implementation

**Description:**
Implement the edit tool that performs deterministic text edits using old_string/new_string replacement. Validates target file exists and paths are safe.

**Files:**
- Create `src/fae_llm/tools/edit.rs`
- Update `src/fae_llm/tools/mod.rs` to export EditTool

**Key types/functions:**
```rust
pub struct EditTool {
    max_bytes: usize,  // max file size to edit
}

impl Tool for EditTool {
    fn name(&self) -> &str { "edit" }
    fn description(&self) -> &str { "Edit file by replacing text..." }
    fn schema(&self) -> serde_json::Value {
        // JSON Schema: {path: str, old_string: str, new_string: str}
    }
    fn execute(&self, args: Value) -> Result<ToolResult, FaeLlmError>;
    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        mode == ToolMode::Full  // mutation requires full mode
    }
}
```

**Tests:**
- Replace text in file succeeds
- Edit nonexistent file returns error
- old_string not found returns error
- old_string has multiple matches returns error (must be unique)
- Path validation prevents editing system files
- allowed_in_mode returns false for read_only mode

**Dependencies:**
- `std::fs` for file I/O
- Path validation helpers from task 5

---

### Task 7: Write tool implementation

**Description:**
Implement the write tool that creates or overwrites files with path validation. Validates parent directory exists and path is safe for writes.

**Files:**
- Create `src/fae_llm/tools/write.rs`
- Update `src/fae_llm/tools/mod.rs` to export WriteTool

**Key types/functions:**
```rust
pub struct WriteTool {
    max_bytes: usize,  // max file size to write
}

impl Tool for WriteTool {
    fn name(&self) -> &str { "write" }
    fn description(&self) -> &str { "Create or overwrite file..." }
    fn schema(&self) -> serde_json::Value {
        // JSON Schema: {path: str, content: str}
    }
    fn execute(&self, args: Value) -> Result<ToolResult, FaeLlmError>;
    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        mode == ToolMode::Full  // write requires full mode
    }
}
```

**Tests:**
- Write new file creates file with correct content
- Write existing file overwrites content
- Write to nonexistent parent directory returns error
- Content exceeding max_bytes returns error
- Path validation prevents writing to system directories
- allowed_in_mode returns false for read_only mode

**Dependencies:**
- `std::fs` for file I/O
- Path validation helpers from task 5

---

### Task 8: Integration tests and module exports

**Description:**
Add integration tests that exercise the full tool system: register all 4 tools, execute in both read_only and full modes, validate mode gating, and test end-to-end workflows.

**Files:**
- Create `src/fae_llm/tools/integration_tests.rs`
- Update `src/fae_llm/tools/mod.rs` to export all public types
- Update `src/fae_llm/mod.rs` to export tools module

**Key tests:**
```rust
#[test]
fn register_all_tools_and_list_available() { /* ... */ }

#[test]
fn read_only_mode_blocks_mutations() { /* ... */ }

#[test]
fn full_mode_allows_all_tools() { /* ... */ }

#[test]
fn schemas_for_api_exports_valid_json() { /* ... */ }

#[test]
fn execute_read_bash_edit_write_sequence() { /* ... */ }
```

**Tests:**
- Register all 4 tools in ToolRegistry
- read_only mode allows read/bash (read-only), blocks edit/write
- full mode allows all 4 tools
- schemas_for_api returns 4 JSON objects with name/description/parameters
- End-to-end: read file → bash command → edit file → write file
- Mode switch dynamically updates available tools

**Dependencies:**
- `tempfile` (already in dev-dependencies) for temp file tests
- All tool implementations from tasks 3-7

**Module exports:**
```rust
// src/fae_llm/tools/mod.rs
pub mod types;
pub mod registry;
pub mod read;
pub mod bash;
pub mod edit;
pub mod write;
pub mod path_validation;

pub use types::{Tool, ToolResult};
pub use registry::ToolRegistry;
pub use read::ReadTool;
pub use bash::BashTool;
pub use edit::EditTool;
pub use write::WriteTool;
pub use path_validation::{validate_read_path, validate_write_path};

// src/fae_llm/mod.rs
pub mod tools;
pub use tools::{Tool, ToolResult, ToolRegistry, ReadTool, BashTool, EditTool, WriteTool};
```

---

## Dependencies Added

No new Cargo.toml dependencies required:
- `serde_json` (already present)
- `tokio` (already present)
- `std::fs`, `std::path` (standard library)
- `tempfile` (already in dev-dependencies)

## Success Criteria

- All 8 tasks complete with passing tests
- Zero clippy warnings
- Tool system functional with all 4 tools registered
- Mode gating enforces read_only vs full permissions
- Bounded output prevents OOM with large files/command output
- Path validation prevents sandbox escapes
- JSON Schema validation for tool arguments
- Integration tests demonstrate end-to-end workflows
