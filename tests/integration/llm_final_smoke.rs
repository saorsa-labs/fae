//! Final smoke test — verifies fae_llm subsystems can be instantiated.

use fae::fae_llm::{ConfigService, ToolMode, ToolRegistry, default_config};
use tempfile::TempDir;

#[test]
fn all_subsystems_initialize() {
    // Config
    let dir = TempDir::new().expect("temp dir");
    let path = dir.path().join("fae_llm.toml");
    let config = default_config();
    std::fs::write(&path, toml::to_string(&config).unwrap()).unwrap();
    let service = ConfigService::new(path);
    service.load().expect("config load");

    // Tools
    let _tools = ToolRegistry::new(ToolMode::Full);

    // Verified: config + tools subsystems work
}
