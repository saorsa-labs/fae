//! Minimal latency harness for host-boundary baseline checks.

fn main() {
    if let Err(e) = run() {
        eprintln!("fae-latency-harness failed: {e}");
        std::process::exit(1);
    }
}

fn run() -> fae::Result<()> {
    let config = fae::host::latency::BenchConfig {
        samples: 1_000,
        payload_bytes: 1024,
    };
    let report = fae::host::latency::generate_baseline_report(config)?;

    let output_path = fae::fae_dirs::diagnostics_dir().join("native-app-v0-latency-baseline.json");
    fae::host::latency::write_baseline_report(&report, &output_path)?;

    let json = serde_json::to_string_pretty(&report).map_err(|e| {
        fae::SpeechError::Pipeline(format!("failed to encode baseline report for stdout: {e}"))
    })?;
    println!("{json}");
    println!("saved baseline report: {}", output_path.display());
    Ok(())
}
