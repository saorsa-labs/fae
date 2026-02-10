//! Finds, installs, and manages the Pi coding agent binary.
//!
//! `PiManager` handles the full lifecycle:
//! 1. **Detection** — find Pi in PATH or standard install locations
//! 2. **Installation** — download from GitHub releases and install
//! 3. **Updates** — check for newer versions and replace managed installs
//! 4. **Tracking** — distinguish Fae-managed installs from user-installed Pi
