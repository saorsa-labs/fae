//! Build script: validates Metal Toolchain availability when the `metal` feature is enabled.

fn main() {
    // Register custom cfgs so rustc doesn't warn about them.
    println!("cargo::rustc-check-cfg=cfg(missing_metal_toolchain)");
    println!("cargo::rustc-check-cfg=cfg(apple_platform)");

    // When building with the `metal` feature on macOS, mistralrs needs the Metal
    // shader compiler (`xcrun metal`) to pre-compile .metal → .air at build time.
    // Without it, the build panics deep inside mistralrs-quant with a cryptic error.
    // We detect this early and give a clear, actionable message.
    #[cfg(all(feature = "metal", target_os = "macos"))]
    {
        let output = std::process::Command::new("xcrun")
            .args(["metal", "--version"])
            .output();

        match output {
            Ok(o) if o.status.success() => {
                // Metal Toolchain is installed — nothing to do.
            }
            _ => {
                println!(
                    "cargo::warning=\
                    Metal Toolchain not found. The `metal` feature requires Apple's Metal \
                    shader compiler. Install it with:\n\n    \
                    xcodebuild -downloadComponent MetalToolchain\n\n\
                    This is a one-time ~700 MB download. After installing, re-run the build."
                );
                // Emit a cfg that lib.rs can use to produce a compile_error!
                println!("cargo::rustc-cfg=missing_metal_toolchain");
            }
        }
    }

    // Emit cfg for macOS detection so downstream code can auto-select Metal.
    // The Dioxus app can check this at build time to conditionally enable the
    // `metal` feature without requiring users to pass --features manually.
    #[cfg(target_os = "macos")]
    println!("cargo::rustc-cfg=apple_platform");
}
