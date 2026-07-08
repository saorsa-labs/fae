//! fae-daemon build script — force-link GNU libstdc++ for sherpa-onnx under
//! cargo-zigbuild.
//!
//! `sherpa-onnx` (Parakeet ASR) ships a prebuilt C++ static library that is
//! GNU-`libstdc++` ABI; `sherpa-onnx-sys` already emits
//! `cargo:rustc-link-lib=dylib=stdc++`, which the native gcc linker resolves
//! from the system sysroot. But `cargo-zigbuild` links with zig's `ld.lld`,
//! whose hermetic cross sysroot ships libc++ (LLVM), NOT GNU libstdc++ — and zig
//! IGNORES host `cargo:rustc-link-search` paths for the C++ stdlib, so even with
//! `-L/usr/lib/gcc/…/13` + `-lstdc++` on the link line, the symbols stay
//! undefined (confirmed in CI: `std::string::_Rep::_S_empty_rep_storage`, …).
//!
//! Fix (Linux only): resolve the host gcc's libstdc++ to an ABSOLUTE path and
//! emit it as `cargo:rustc-link-arg=<path>` — a direct file input that lld links
//! verbatim, bypassing sysroot search entirely. `cargo:rustc-link-arg` does NOT
//! propagate from a library crate, so this lives in fae-daemon (the binary being
//! linked), not fae-engine. We prefer the self-contained static `.a` (lld links
//! it directly, no linker-script parsing, no runtime `.so` dep) and fall back to
//! the `.so`. Harmless on native gcc (the archive only supplies the undefined
//! `std::*` symbols). No-op on macOS (sherpa-onnx-sys links libc++ there).

fn main() {
    println!("cargo:rerun-if-env-changed=CC");
    println!("cargo:rerun-if-env-changed=CXX");

    #[cfg(target_os = "linux")]
    force_link_libstdcxx();
}

#[cfg(target_os = "linux")]
fn force_link_libstdcxx() {
    use std::path::PathBuf;
    use std::process::Command;

    /// `gcc -print-file-name=NAME` → the absolute path when gcc reports an
    /// existing file (gcc echoes the bare name back when the file is absent).
    fn gcc_file(name: &str) -> Option<PathBuf> {
        let output = Command::new("gcc")
            .arg(format!("-print-file-name={name}"))
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let path = PathBuf::from(String::from_utf8_lossy(&output.stdout).trim().to_owned());
        if path.is_absolute() && path.exists() {
            Some(path)
        } else {
            None
        }
    }

    // Prefer the static archive (lld links it verbatim, no runtime dep); fall
    // back to the .so linker script.
    let Some(libstdcxx) = gcc_file("libstdc++.a").or_else(|| gcc_file("libstdc++.so")) else {
        // No host gcc/libstdc++ found. Native gcc builds still link fine without
        // us (the system sysroot provides libstdc++); a zig cross-build fails
        // loudly with the undefined-symbol error, signalling that gcc/libstdc++
        // must be installed on the host.
        return;
    };
    // Direct file input — bypasses zig's hermetic sysroot search entirely.
    println!("cargo:rustc-link-arg={}", libstdcxx.display());
}
