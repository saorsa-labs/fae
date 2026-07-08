//! fae-engine build script.
//!
//! `sherpa-onnx` (the Parakeet ASR runtime) ships a prebuilt C++ static library
//! that is GNU-`libstdc++` ABI. On Linux it needs `libstdc++` at the final link.
//! `sherpa-onnx-sys` already emits `cargo:rustc-link-lib=dylib=stdc++`, which the
//! native gcc linker resolves from the system sysroot — so native `cargo build`
//! is unaffected. But `cargo-zigbuild` (the daemon's Linux cross-compile proof)
//! links with zig's `ld.lld`, whose hermetic cross sysroot ships libc++ (LLVM),
//! NOT GNU `libstdc++`, so the `-lstdc++` directive can't resolve and the link
//! fails with undefined `std::*` symbols (e.g. `std::random_device::_M_getval`).
//!
//! Fix (Linux only): ask the host gcc where its `libstdc++` lives and add that
//! directory as a `cargo:rustc-link-search` path. `link-search`/`link-lib`
//! propagate transitively from this build script to dependents (fae-daemon), so
//! the existing `-lstdc++` then resolves under zig too. This is a no-op on macOS
//! (sherpa-onnx-sys links libc++ there) and harmless on native gcc builds (the
//! path is already searched). We prefer the self-contained static archive
//! (`.a`) — no runtime `.so` dependency — and fall back to the `.so`.

fn main() {
    // The libstdc++ path depends on the host compiler; re-probe if it changes.
    println!("cargo:rerun-if-env-changed=CC");
    println!("cargo:rerun-if-env-changed=CXX");

    #[cfg(target_os = "linux")]
    add_libstdcxx_search_path();
}

#[cfg(target_os = "linux")]
fn add_libstdcxx_search_path() {
    use std::path::PathBuf;
    use std::process::Command;

    /// Run `gcc -print-file-name=<name>`; return the path only if gcc reports an
    /// absolute, existing file (gcc echoes the bare name back when absent).
    fn gcc_file(name: &str) -> Option<PathBuf> {
        let output = Command::new("gcc")
            .args(["-print-file-name", name])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let raw = String::from_utf8_lossy(&output.stdout);
        let path = PathBuf::from(raw.trim());
        if path.is_absolute() && path.exists() {
            Some(path)
        } else {
            None
        }
    }

    // Prefer the static archive (self-contained); fall back to the .so linker
    // script (always present on a gcc-installed host).
    let libstdcxx = gcc_file("libstdc++.a").or_else(|| gcc_file("libstdc++.so"));
    let Some(parent) = libstdcxx.as_ref().and_then(|p| p.parent()) else {
        // No host gcc/libstdc++ found. Native gcc builds still link fine without
        // us (the default sysroot is searched); a zig cross-build will fail
        // loudly with the undefined-symbol error, signalling that gcc/libstdc++
        // must be installed on the host.
        return;
    };

    println!("cargo:rustc-link-search=native={}", parent.display());
    // Re-affirm the lib directive (idempotent with sherpa-onnx-sys) so the
    // search path above is exercised even if the upstream emission changes.
    println!("cargo:rustc-link-lib=dylib=stdc++");
}
