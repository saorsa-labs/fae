# Plan: Refactor coordinator.rs into Modules

**Goal**: Split `src/pipeline/coordinator.rs` (2877 LOC) into focused modules

## Phase 1: Analyze Current Structure
- [ ] Read and map `coordinator.rs` structure
- [ ] Identify logical boundaries (messages, state, events, handlers)
- [ ] Count methods per logical group

## Phase 2: Create New Modules

### src/pipeline/mod.rs (new)
```rust
pub mod coordinator;  // Re-export with new structure
pub use coordinator::{PipelineCoordinator, CoordinatorHandle};
```

### src/pipeline/state.rs (new)
- Extract `CoordinatorState` enum
- Extract state machine transitions
- Extract state persistence (save/load)

### src/pipeline/events.rs (new)  
- Extract event types from `CoordinatorMessage`
- Extract event handlers
- Extract pub/sub logic

### src/pipeline/handlers.rs (new)
- Extract message handlers from `CoordinatorMessage::handle()`
- Extract task handlers
- Extract notification handlers

### src/pipeline/coordinator.rs (refactored)
- Keep main struct and public API
- Delegate to modules
- Target: ~800 LOC

## Phase 3: Update Dependencies
- [ ] Update `src/pipeline/mod.rs` exports
- [ ] Update imports in `src/lib.rs`
- [ ] Update any downstream consumers

## Phase 4: Verify
- [ ] All tests pass
- [ ] Clippy clean
- [ ] Docs build

## Estimated LOC per Module
| Module | Target LOC |
|--------|-----------|
| state.rs | ~600 |
| events.rs | ~500 |
| handlers.rs | ~700 |
| coordinator.rs | ~800 |
| mod.rs | ~50 |
| **Total** | ~2650 |
