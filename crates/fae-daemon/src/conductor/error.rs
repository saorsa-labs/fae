use std::io;

/// Errors surfaced by the conductor module.
#[derive(Debug, thiserror::Error)]
pub enum ConductorError {
    /// An underlying IO failure (store open / append / read).
    #[error("conductor io: {0}")]
    Io(#[from] io::Error),
    /// A serialization failure (serde_json).
    #[error("conductor serialize: {0}")]
    Serialize(#[from] serde_json::Error),
    /// The CSPRNG could not produce key material for the install fingerprint key.
    #[error("conductor csprng: {0}")]
    Csprng(#[from] getrandom::Error),
    /// HMAC key-length rejected (unreachable for a 32-byte key + SHA-256; kept
    /// panic-free by surfacing as an error rather than `expect`).
    #[error("conductor hmac key-length: {0}")]
    KeyLength(String),
    /// A recipe failed validation against the active safety profile.
    #[error("conductor recipe invalid: {0}")]
    Recipe(String),
    /// A store path component was malformed (non-sanitized id, path escape, …).
    #[error("conductor path: {0}")]
    #[allow(dead_code)]
    // TODO(M2): raised by RecipeSet/recipe-store paths when M2 loads candidate recipes
    Path(String),
    /// Operator configuration failed validation.
    #[error("conductor config: {0}")]
    Config(String),
}
