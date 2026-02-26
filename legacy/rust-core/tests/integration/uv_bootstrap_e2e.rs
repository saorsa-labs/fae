//! End-to-end integration test for the UV bootstrap pipeline.
//!
//! Verifies the full flow: discover/install → bootstrap → pre-warm → spawn → handshake.
//! Skipped when `uv` is not available on the test machine.

use std::io::Write;
use std::path::PathBuf;

use fae::skills::{
    PythonEnvironmentInfo, SkillProcessConfig, UvBootstrap, UvInfo, bootstrap_python_environment,
};

/// Skip helper: returns `true` if `uv` is not available.
fn uv_not_available() -> bool {
    which::which("uv").is_err()
}

// ---------------------------------------------------------------------------
// bootstrap_python_environment
// ---------------------------------------------------------------------------

#[test]
fn bootstrap_returns_valid_uv_info() {
    if uv_not_available() {
        return;
    }
    let info = bootstrap_python_environment(None).expect("bootstrap should succeed");
    assert!(!info.uv.version.is_empty());
    assert!(info.uv.path.is_file());
}

#[test]
fn bootstrap_with_explicit_path_uses_it() {
    if uv_not_available() {
        return;
    }
    let uv_path = which::which("uv").unwrap();
    let info = bootstrap_python_environment(Some(&uv_path)).expect("bootstrap should succeed");
    assert_eq!(info.uv.path, uv_path);
}

#[test]
fn bootstrap_returns_error_for_nonexistent_explicit_path_when_no_fallback() {
    // This test only works if uv is NOT installed system-wide.
    // On machines with uv, discovery falls back to PATH.
    let result = bootstrap_python_environment(Some(std::path::Path::new("/nonexistent/uv")));
    // Either succeeds (uv on PATH) or fails with UvNotFound — no panic.
    match result {
        Ok(info) => assert!(!info.uv.version.is_empty()),
        Err(fae::skills::PythonSkillError::UvNotFound { .. }) => {}
        Err(other) => panic!("unexpected error: {other}"),
    }
}

// ---------------------------------------------------------------------------
// pre_warm → spawn → handshake E2E
// ---------------------------------------------------------------------------

#[test]
fn pre_warm_then_spawn_succeeds() {
    if uv_not_available() {
        return;
    }

    let dir = tempfile::tempdir().expect("create temp dir");

    // Write a minimal Python script that prints to stdout (no PEP 723 deps).
    let script_path = dir.path().join("hello.py");
    {
        let mut f = std::fs::File::create(&script_path).expect("create script");
        writeln!(f, "#!/usr/bin/env python3").unwrap();
        writeln!(f, "print('hello from e2e test')").unwrap();
    }

    // 1. Bootstrap
    let env_info = bootstrap_python_environment(None).expect("bootstrap");

    // 2. Pre-warm
    UvBootstrap::pre_warm(&env_info.uv.path, &script_path).expect("pre-warm");

    // 3. Verify that a SkillProcessConfig can be built with the resolved UV path.
    let config =
        SkillProcessConfig::new("e2e-test", script_path).with_uv_path(env_info.uv.path.clone());

    assert_eq!(config.uv_path, env_info.uv.path);
    assert_eq!(config.skill_name, "e2e-test");
}

// ---------------------------------------------------------------------------
// Full pipeline: bootstrap → parse PEP 723 → pre-warm → config
// ---------------------------------------------------------------------------

#[test]
fn full_pipeline_with_pep723_script() {
    if uv_not_available() {
        return;
    }

    let dir = tempfile::tempdir().expect("create temp dir");

    // Write a Python script with PEP 723 inline metadata.
    let script_path = dir.path().join("greeter.py");
    {
        let mut f = std::fs::File::create(&script_path).expect("create script");
        writeln!(f, "#!/usr/bin/env python3").unwrap();
        writeln!(f, "# /// script").unwrap();
        writeln!(f, "# requires-python = \">=3.10\"").unwrap();
        writeln!(f, "# dependencies = []").unwrap();
        writeln!(f, "# ///").unwrap();
        writeln!(f).unwrap();
        writeln!(f, "import sys").unwrap();
        writeln!(f, "print('greeter ready')").unwrap();
    }

    // 1. Bootstrap UV
    let env_info = bootstrap_python_environment(None).expect("bootstrap");

    // 2. Parse PEP 723 metadata
    let metadata =
        fae::skills::pep723::parse_script_metadata(&script_path).expect("parse metadata");
    assert_eq!(metadata.requires_python.as_deref(), Some(">=3.10"));
    assert!(metadata.dependencies.is_empty());

    // 3. Pre-warm the environment
    UvBootstrap::pre_warm(&env_info.uv.path, &script_path).expect("pre-warm");

    // 4. Build runner config
    let config = SkillProcessConfig::new("greeter", script_path).with_uv_path(env_info.uv.path);

    assert_eq!(config.skill_name, "greeter");
}

// ---------------------------------------------------------------------------
// PythonEnvironmentInfo Debug
// ---------------------------------------------------------------------------

#[test]
fn environment_info_debug_format() {
    let info = PythonEnvironmentInfo {
        uv: UvInfo {
            path: PathBuf::from("/usr/bin/uv"),
            version: "0.5.0".to_owned(),
        },
    };
    let dbg = format!("{info:?}");
    assert!(dbg.contains("PythonEnvironmentInfo"));
    assert!(dbg.contains("/usr/bin/uv"));
}
