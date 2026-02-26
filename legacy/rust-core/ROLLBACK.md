# Rollback Instructions (Restore legacy Rust root layout)

Run these commands from repository root to move quarantined Rust files back to root paths:

```bash
# 1) Move legacy root artifacts back
for item in Cargo.toml Cargo.lock build.rs .cargo src include tests; do
  if [ -e "legacy/rust-core/$item" ]; then
    mv "legacy/rust-core/$item" "./$item"
  fi
done

# 2) (Optional) recreate root target artifacts via cargo build if needed
# cargo build
```

## Notes

- This rollback is intended for controlled recovery only.
- Re-enabling Rust-first paths may conflict with current Swift-first migration guardrails.
