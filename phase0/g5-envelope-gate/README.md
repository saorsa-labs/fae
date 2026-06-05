# G5 Envelope Gate — Phase 0 Scaffold

This is a Phase-0-only enforcement scaffold for W2. It is not production daemon code.

It proves the minimum machine-enforced peer envelope boundary:

- closed `EnvelopeKind` enum;
- `schema_version` gate;
- `serde(deny_unknown_fields)` envelope/signature structs;
- signature-verification hook;
- accepted-envelope wrapper instead of raw free-form peer text dispatch;
- no public raw payload accessor from `AcceptedEnvelope`;
- JSONL audit writer for accepted and rejected envelopes;
- preferred `gate_and_audit` API that writes audit before returning accepted data;
- tests for unknown kind rejection, schema rejection, signature rejection, accepted audit writing, and rejected audit writing.

Run:

```bash
cargo fmt --manifest-path phase0/g5-envelope-gate/Cargo.toml
cargo clippy --manifest-path phase0/g5-envelope-gate/Cargo.toml --all-features --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
cargo test --manifest-path phase0/g5-envelope-gate/Cargo.toml
```

Open before production:

- replace placeholder signature verifier with ML-DSA-65/x0xd verification integration;
- add consent receipt lookup;
- write audits to the production append-only/tamper-evident audit store;
- connect to daemon control-plane capability checks;
- add fuzz/adversarial cases.
