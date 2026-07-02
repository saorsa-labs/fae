//! Fail-closed SHA-256 integrity verification (ADR-013 Vision A, A2.5).
//!
//! Ports Swift `SkillManifestPolicy.verifyIntegrity`
//! (`native/macos/Fae/Sources/Fae/Skills/SkillManifest.swift`). An executable
//! skill's `MANIFEST.json` declares a `checksums` map of relative-path →
//! lowercase-hex SHA-256. Verification:
//!
//! 1. `algorithm` must be `sha256` (case-insensitive) — else quarantine.
//! 2. `SKILL.md` MUST be a declared checksum key (Fae hardening beyond Swift,
//!    per the CLAUDE.md skill-manifest contract: checksums cover SKILL.md AND
//!    every script). All real bundled manifests declare it.
//! 3. Every declared file must exist and its digest must match — a missing file
//!    or a modified byte quarantines the skill.
//! 4. Any `scripts/*.py` present on disk but NOT declared quarantines the skill
//!    (Swift's "undeclared executable content" guard): verifying only the
//!    declared set would let an attacker drop an extra runnable `.py` that
//!    `run_skill` would happily execute.
//!
//! Verification runs at discovery AND again immediately before execution
//! (`skillhost.run`), so a file swapped between load and run is caught.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

/// The result of an integrity check: `Ok(())` (verified) or a quarantine
/// reason (never executable).
pub type IntegrityResult = Result<(), String>;

/// Verify a skill directory against its declared checksums. Fail-closed: any
/// anomaly returns `Err(reason)` and the skill must be quarantined.
///
/// `checksums` are relative-path keys (e.g. `"scripts/build.py"`) → lowercase
/// hex digests. `skill_dir` is the skill's on-disk root.
pub fn verify(
    algorithm: &str,
    checksums: &BTreeMap<String, String>,
    skill_dir: &Path,
) -> IntegrityResult {
    if !algorithm.eq_ignore_ascii_case("sha256") {
        return Err(format!("unsupported_algorithm:{algorithm}"));
    }

    // Hardening (CLAUDE.md contract): SKILL.md must be covered. Swift verifies
    // it only if declared; the daemon requires the declaration so a manifest
    // can never silently omit the instruction text from tamper detection.
    if !checksums.contains_key("SKILL.md") {
        return Err("skill_md_not_declared".into());
    }

    // 1. Every declared checksum: resolve safely, hash, compare.
    for (relative, expected) in checksums {
        let resolved = safe_join(skill_dir, relative)
            .ok_or_else(|| format!("checksum_path_escape:{relative}"))?;
        let actual = match sha256_file(&resolved) {
            Ok(hex) => hex,
            Err(_) => return Err(format!("missing_file:{relative}")),
        };
        if !actual.eq_ignore_ascii_case(expected.trim()) {
            return Err(format!("modified:{relative}"));
        }
    }

    // 2. Undeclared executable content: any scripts/*.py on disk not covered by
    //    a checksum key is a tamper/injection vector — quarantine. Matches
    //    Swift: non-recursive scripts/ enumeration, `.py` files only (so a
    //    runtime __pycache__/*.pyc never trips the gate).
    let scripts_dir = skill_dir.join("scripts");
    if let Ok(entries) = std::fs::read_dir(&scripts_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            let is_py = path.extension().and_then(|e| e.to_str()) == Some("py");
            if !is_py {
                continue;
            }
            let is_file = entry.file_type().map(|t| t.is_file()).unwrap_or(false);
            if !is_file {
                continue;
            }
            if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                let relative = format!("scripts/{name}");
                if !checksums.contains_key(&relative) {
                    return Err(format!("undeclared_script:{relative}"));
                }
            }
        }
    }

    Ok(())
}

/// Join `relative` under `base`, rejecting absolute paths and any `..`/`.`
/// component so a hostile manifest key cannot escape the skill directory. The
/// resolved path is returned only when it stays within `base`.
fn safe_join(base: &Path, relative: &str) -> Option<PathBuf> {
    let rel = Path::new(relative);
    if rel.is_absolute() {
        return None;
    }
    let mut out = base.to_path_buf();
    for component in rel.components() {
        use std::path::Component;
        match component {
            Component::Normal(part) => out.push(part),
            // Reject `..`, `.`, root, and prefix components outright.
            _ => return None,
        }
    }
    Some(out)
}

/// Lowercase-hex SHA-256 of a file's raw bytes (streamed). Mirrors the Swift
/// `SHA256.hash(data:)` hex encoding and the daemon's `models_lock` idiom.
///
/// # Errors
/// Propagates the underlying I/O error (treated as "missing file" by callers).
pub fn sha256_file(path: &Path) -> std::io::Result<String> {
    let mut file = std::fs::File::open(path)?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 1024 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    Ok(hex::encode(digest.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn hex_of(bytes: &[u8]) -> String {
        hex::encode(Sha256::digest(bytes))
    }

    /// Build a valid executable-skill dir: SKILL.md + scripts/run.py, with a
    /// checksum map covering both. Returns (tempdir, checksums).
    fn valid_skill() -> (tempfile::TempDir, BTreeMap<String, String>) {
        let dir = tempfile::tempdir().expect("tempdir");
        let skill_md = b"---\nname: x\n---\nbody";
        let script = b"print('hi')\n";
        std::fs::write(dir.path().join("SKILL.md"), skill_md).expect("write md");
        std::fs::create_dir(dir.path().join("scripts")).expect("mkdir");
        std::fs::write(dir.path().join("scripts/run.py"), script).expect("write py");
        let mut checksums = BTreeMap::new();
        checksums.insert("SKILL.md".to_string(), hex_of(skill_md));
        checksums.insert("scripts/run.py".to_string(), hex_of(script));
        (dir, checksums)
    }

    #[test]
    fn valid_skill_verifies() {
        let (dir, checksums) = valid_skill();
        assert!(verify("sha256", &checksums, dir.path()).is_ok());
    }

    #[test]
    fn algorithm_is_case_insensitive() {
        let (dir, checksums) = valid_skill();
        assert!(verify("SHA256", &checksums, dir.path()).is_ok());
    }

    #[test]
    fn unsupported_algorithm_quarantines() {
        let (dir, checksums) = valid_skill();
        let err = verify("md5", &checksums, dir.path()).unwrap_err();
        assert!(err.starts_with("unsupported_algorithm"), "{err}");
    }

    #[test]
    fn tampered_script_byte_quarantines() {
        let (dir, checksums) = valid_skill();
        // Flip a byte in the script AFTER computing the checksum.
        std::fs::write(dir.path().join("scripts/run.py"), b"print('HACKED')\n").expect("rewrite");
        let err = verify("sha256", &checksums, dir.path()).unwrap_err();
        assert_eq!(err, "modified:scripts/run.py");
    }

    #[test]
    fn undeclared_extra_script_quarantines() {
        let (dir, checksums) = valid_skill();
        // Drop an extra, UNDECLARED .py into scripts/.
        std::fs::write(
            dir.path().join("scripts/evil.py"),
            b"os.system('rm -rf ~')\n",
        )
        .expect("write evil");
        let err = verify("sha256", &checksums, dir.path()).unwrap_err();
        assert_eq!(err, "undeclared_script:scripts/evil.py");
    }

    #[test]
    fn missing_declared_file_quarantines() {
        let (dir, checksums) = valid_skill();
        std::fs::remove_file(dir.path().join("scripts/run.py")).expect("rm");
        let err = verify("sha256", &checksums, dir.path()).unwrap_err();
        assert_eq!(err, "missing_file:scripts/run.py");
    }

    #[test]
    fn skill_md_must_be_declared() {
        let (dir, mut checksums) = valid_skill();
        checksums.remove("SKILL.md");
        let err = verify("sha256", &checksums, dir.path()).unwrap_err();
        assert_eq!(err, "skill_md_not_declared");
    }

    #[test]
    fn checksum_path_escape_rejected() {
        let (dir, mut checksums) = valid_skill();
        checksums.insert("../evil".to_string(), "aa".to_string());
        let err = verify("sha256", &checksums, dir.path()).unwrap_err();
        assert!(err.starts_with("checksum_path_escape"), "{err}");
    }

    #[test]
    fn non_py_extra_file_does_not_quarantine() {
        // A runtime artifact like scripts/notes.txt or a .pyc is not enumerated
        // as executable content (Swift parity) — must NOT quarantine.
        let (dir, checksums) = valid_skill();
        std::fs::write(dir.path().join("scripts/cache.pyc"), b"bytecode").expect("write pyc");
        assert!(verify("sha256", &checksums, dir.path()).is_ok());
    }
}
