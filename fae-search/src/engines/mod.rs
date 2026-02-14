//! Search engine implementations.
//!
//! Each module provides a struct implementing [`crate::engine::SearchEngineTrait`] that
//! scrapes a specific search engine's HTML results page.

pub mod bing;
pub mod brave;
pub mod duckduckgo;
pub mod google;
pub mod startpage;

pub use bing::BingEngine;
pub use brave::BraveEngine;
pub use duckduckgo::DuckDuckGoEngine;
pub use google::GoogleEngine;
pub use startpage::StartpageEngine;
