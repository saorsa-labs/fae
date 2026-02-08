//! Fae desktop GUI — simple start/stop interface with progress feedback.
//!
//! Requires the `gui` feature: `cargo run --features gui --bin fae-gui`

#[cfg(feature = "gui")]
fn main() {
    dioxus::launch(app);
}

#[cfg(feature = "gui")]
use dioxus::prelude::*;

/// Root application component.
#[cfg(feature = "gui")]
fn app() -> Element {
    rsx! {
        div {
            style: "display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 100vh; background: #1a1a2e; color: #e0e0e0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;",
            h1 {
                style: "font-size: 2rem; margin-bottom: 1rem; color: #a78bfa;",
                "Fae"
            }
            p {
                style: "color: #888; font-size: 0.9rem;",
                "GUI implementation in progress — Phase 1.2"
            }
        }
    }
}

#[cfg(not(feature = "gui"))]
fn main() {
    eprintln!("fae-gui requires the `gui` feature. Run with:");
    eprintln!("  cargo run --features gui --bin fae-gui");
    std::process::exit(1);
}
