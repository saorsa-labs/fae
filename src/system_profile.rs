//! Lightweight system profiling for model recommendations.
//!
//! Keep this dependency-free: rely on best-effort OS commands where available.

use std::process::Command;

#[derive(Debug, Clone)]
pub struct SystemProfile {
    pub os: String,
    pub arch: String,
    pub total_memory_bytes: Option<u64>,
    pub cpu: Option<String>,
    pub gpu: Option<String>,
}

impl SystemProfile {
    pub fn detect() -> Self {
        let os = std::env::consts::OS.to_owned();
        let arch = std::env::consts::ARCH.to_owned();
        let total_memory_bytes = detect_total_memory_bytes();
        let cpu = detect_cpu();
        let gpu = None;

        Self {
            os,
            arch,
            total_memory_bytes,
            cpu,
            gpu,
        }
    }

    /// Optional slow GPU detection (macOS only).
    pub fn detect_gpu_slow(&mut self) {
        if self.gpu.is_some() {
            return;
        }
        self.gpu = detect_gpu();
    }
}

fn run_cmd(args: &[&str]) -> Option<String> {
    let (program, rest) = args.split_first()?;
    let out = Command::new(program).args(rest).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8(out.stdout).ok()?;
    let trimmed = s.trim().to_owned();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

pub fn detect_total_memory_bytes() -> Option<u64> {
    // macOS: sysctl hw.memsize
    if cfg!(target_os = "macos") {
        let s = run_cmd(&["sysctl", "-n", "hw.memsize"])?;
        return s.parse::<u64>().ok();
    }
    // Linux: /proc/meminfo MemTotal in kB
    if cfg!(target_os = "linux") {
        let content = std::fs::read_to_string("/proc/meminfo").ok()?;
        for line in content.lines() {
            if let Some(rest) = line.strip_prefix("MemTotal:") {
                let parts = rest.split_whitespace().collect::<Vec<_>>();
                if parts.len() >= 2
                    && let Ok(kb) = parts[0].parse::<u64>()
                {
                    return Some(kb.saturating_mul(1024));
                }
            }
        }
    }
    None
}

fn detect_cpu() -> Option<String> {
    if cfg!(target_os = "macos") {
        return run_cmd(&["sysctl", "-n", "machdep.cpu.brand_string"]);
    }
    if cfg!(target_os = "linux") {
        let content = std::fs::read_to_string("/proc/cpuinfo").ok()?;
        for line in content.lines() {
            if let Some(rest) = line.strip_prefix("model name")
                && let Some((_, v)) = rest.split_once(':')
            {
                let v = v.trim().to_owned();
                if !v.is_empty() {
                    return Some(v);
                }
            }
        }
    }
    None
}

fn detect_gpu() -> Option<String> {
    if cfg!(target_os = "macos") {
        // Very best-effort. Keep it cheap: "system_profiler" is slow, but this
        // only runs when the GUI starts.
        return run_cmd(&["system_profiler", "SPDisplaysDataType"]).and_then(|s| {
            for line in s.lines() {
                let l = line.trim();
                if l.ends_with(':') && !l.starts_with("Displays") && !l.starts_with("Graphics") {
                    return Some(l.trim_end_matches(':').to_owned());
                }
            }
            None
        });
    }
    None
}
