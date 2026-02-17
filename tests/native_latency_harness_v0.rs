use fae::host::latency::{
    BenchConfig, run_channel_ipc_roundtrip_bench, run_local_ipc_roundtrip_bench,
    run_noop_dispatch_bench,
};

#[test]
fn noop_dispatch_bench_returns_ordered_percentiles() {
    let report = run_noop_dispatch_bench(BenchConfig {
        samples: 128,
        payload_bytes: 0,
    })
    .expect("noop dispatch bench");

    assert_eq!(report.scenario, "noop_dispatch");
    assert_eq!(report.samples, 128);
    assert!(report.p50_micros <= report.p95_micros);
    assert!(report.p95_micros <= report.p99_micros);
}

#[test]
fn channel_ipc_bench_returns_ordered_percentiles() {
    let report = run_channel_ipc_roundtrip_bench(BenchConfig {
        samples: 128,
        payload_bytes: 1024,
    })
    .expect("channel ipc bench");

    assert_eq!(report.scenario, "channel_ipc_roundtrip");
    assert_eq!(report.samples, 128);
    assert!(report.p50_micros <= report.p95_micros);
    assert!(report.p95_micros <= report.p99_micros);
}

#[test]
fn local_ipc_bench_returns_ordered_percentiles() {
    #[cfg(unix)]
    {
        let report = run_local_ipc_roundtrip_bench(BenchConfig {
            samples: 64,
            payload_bytes: 1024,
        })
        .expect("local ipc bench");

        assert_eq!(report.scenario, "uds_ipc_roundtrip");
        assert_eq!(report.samples, 64);
        assert!(report.p50_micros <= report.p95_micros);
        assert!(report.p95_micros <= report.p99_micros);
    }

    #[cfg(not(unix))]
    {
        let err = run_local_ipc_roundtrip_bench(BenchConfig {
            samples: 64,
            payload_bytes: 1024,
        })
        .expect_err("non-unix local ipc bench should return unsupported error");

        let msg = err.to_string();
        assert!(msg.contains("local IPC benchmark"));
    }
}
