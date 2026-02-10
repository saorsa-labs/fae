# Plan: Review .unwrap() Calls

**Goal**: Review 19 `.unwrap()` calls and replace with proper error handling where needed

## File Analysis

### src/memory.rs (2 calls)
- [ ] Line 171: `toml::to_string_pretty(&user).unwrap()` 
- [ ] Line 174: `toml::from_str(&extracted).unwrap()`
- **Context**: User profile persistence
- **Approach**: Create `MemoryError` type, use `?` operator

### src/scheduler/tasks.rs (8 calls)
- [ ] Line 343: `task.last_run.unwrap()`
- [ ] Lines 350-351: JSON round-trip (2 calls)
- [ ] Lines 361-362: JSON round-trip (2 calls)
- [ ] Lines 381-382: JSON round-trip (2 calls)
- [ ] Line 426: Test code (OK to keep)
- **Context**: Schedule/task serialization
- **Approach**: Create `SchedulerError`, handle missing fields gracefully

### src/pi/tool.rs (1 call)
- [ ] Line 165: `schema["required"].as_array().unwrap()`
- **Context**: Tool schema validation
- **Approach**: Use `as_array().ok_or(...)` pattern

### src/wakeword.rs (2 calls)
- [ ] Line 622: `save_reference_wav(...).unwrap()`
- [ ] Line 626: `load_wav_mono_16k(...).unwrap()`
- **Context**: Wake word testing
- **Approach**: Propagate errors or convert to Result

### src/scheduler/runner.rs (6 calls)
- [ ] Line 299: `rx.try_recv().unwrap()`
- [ ] Line 331: `rx.try_recv().unwrap()`
- [ ] Line 380: `path.unwrap().to_string_lossy()`
- [ ] Lines 401-402: JSON round-trip (2 calls)
- [ ] Line 426: Test code (OK to keep)
- [ ] Line 449: `rx.try_recv().unwrap()`
- **Context**: Scheduler execution
- **Approach**: Handle channel closed, path missing cases

## Error Types to Create

```rust
#[derive(Debug, thiserror::Error)]
pub enum MemoryError {
    #[error("failed to serialize user profile")]
    Serialize(#[from] toml::Error),
    #[error("failed to deserialize user profile")]
    Deserialize(#[from] toml::Error),
}

#[derive(Debug, thiserror::Error)]
pub enum SchedulerError {
    #[error("task has no scheduled run time")]
    NoScheduledRun,
    #[error("schedule serialization failed: {0}")]
    Serialize(#[from] serde_json::Error),
}
```

## Approach Per Call

| Call Pattern | Approach |
|--------------|----------|
| JSON round-trip | Propagate `serde_json::Error` |
| Option field | Use `.ok_or(Error::Missing)` or provide default |
| Channel recv | Use `rx.recv().map_err(...)` |
| Test code | Keep as-is (allowed) |
| Fallible operation | Use `?` with proper error type |

## Validation
- [ ] All `.unwrap()` reviewed
- [ ] Proper error types created
- [ ] Tests pass
- [ ] Clippy clean
