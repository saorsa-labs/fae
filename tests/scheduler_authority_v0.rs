use fae::scheduler::authority::{LeaderLease, LeaderLeaseConfig, LeadershipDecision, RunKeyLedger};
use std::sync::Arc;
use std::sync::Barrier;
use std::sync::atomic::{AtomicUsize, Ordering};

#[test]
fn leader_lease_acquire_renew_and_takeover() {
    let temp = tempfile::tempdir().expect("tempdir");
    let lease_path = temp.path().join("scheduler.leader.lock");
    let cfg = LeaderLeaseConfig {
        ttl_secs: 15,
        heartbeat_secs: 5,
    };

    let lease_a = LeaderLease::new("instance-a", 111, lease_path.clone(), cfg);
    let lease_b = LeaderLease::new("instance-b", 222, lease_path, cfg);

    let first = lease_a
        .try_acquire_or_renew_at(1_000)
        .expect("acquire a first");
    assert!(matches!(
        first,
        LeadershipDecision::Leader { takeover: false }
    ));

    let blocked = lease_b
        .try_acquire_or_renew_at(2_000)
        .expect("b sees leader");
    assert!(matches!(blocked, LeadershipDecision::Follower { .. }));

    let renewed = lease_a
        .try_acquire_or_renew_at(6_000)
        .expect("a renews lease");
    assert!(matches!(
        renewed,
        LeadershipDecision::Leader { takeover: false }
    ));

    let takeover = lease_b
        .try_acquire_or_renew_at(22_000)
        .expect("b takes over expired lease");
    assert!(matches!(
        takeover,
        LeadershipDecision::Leader { takeover: true }
    ));
}

#[test]
fn run_key_ledger_records_once_and_persists() {
    let temp = tempfile::tempdir().expect("tempdir");
    let path = temp.path().join("scheduler.run_keys.jsonl");

    let mut ledger = RunKeyLedger::new(path.clone());
    assert!(ledger.record_once("task-1:123").expect("first insert"));
    assert!(!ledger.record_once("task-1:123").expect("duplicate insert"));
    assert!(ledger.record_once("task-1:124").expect("distinct insert"));

    let mut reloaded = RunKeyLedger::new(path);
    assert!(
        !reloaded
            .record_once("task-1:123")
            .expect("persisted duplicate")
    );
    assert!(
        !reloaded
            .record_once("task-1:124")
            .expect("persisted duplicate")
    );
    assert!(
        reloaded
            .record_once("task-2:900")
            .expect("new key after reload")
    );
}

#[test]
fn run_key_ledger_detects_external_writes_after_initial_load() {
    let temp = tempfile::tempdir().expect("tempdir");
    let path = temp.path().join("scheduler.run_keys.jsonl");

    let mut writer_a = RunKeyLedger::new(path.clone());
    let mut writer_b = RunKeyLedger::new(path);

    assert!(writer_b.record_once("warmup:1").expect("warmup insert"));
    assert!(writer_a.record_once("shared:42").expect("writer a insert"));
    assert!(
        !writer_b
            .record_once("shared:42")
            .expect("writer b should observe external write"),
        "writer b should treat shared:42 as duplicate after external write"
    );
}

#[test]
fn leader_lease_tolerates_heartbeat_jitter_within_ttl() {
    let temp = tempfile::tempdir().expect("tempdir");
    let lease_path = temp.path().join("scheduler.leader.lock");
    let cfg = LeaderLeaseConfig {
        ttl_secs: 15,
        heartbeat_secs: 5,
    };

    let lease_a = LeaderLease::new("instance-a", 111, lease_path.clone(), cfg);
    let lease_b = LeaderLease::new("instance-b", 222, lease_path, cfg);

    let start = 10_000_u64;
    assert!(matches!(
        lease_a
            .try_acquire_or_renew_at(start)
            .expect("initial acquire"),
        LeadershipDecision::Leader { takeover: false }
    ));

    assert!(matches!(
        lease_a
            .try_acquire_or_renew_at(start + 6_200)
            .expect("renew with positive jitter"),
        LeadershipDecision::Leader { takeover: false }
    ));
    assert!(
        matches!(
            lease_b
                .try_acquire_or_renew_at(start + 6_300)
                .expect("follower blocked while lease active"),
            LeadershipDecision::Follower { .. }
        ),
        "follower should remain blocked while jittered heartbeat is still within TTL"
    );

    assert!(matches!(
        lease_a
            .try_acquire_or_renew_at(start + 11_700)
            .expect("second jittered renewal"),
        LeadershipDecision::Leader { takeover: false }
    ));
    assert!(
        matches!(
            lease_b
                .try_acquire_or_renew_at(start + 24_000)
                .expect("follower still blocked before ttl expiry"),
            LeadershipDecision::Follower { .. }
        ),
        "follower should remain blocked until lease ttl actually expires"
    );

    assert!(matches!(
        lease_b
            .try_acquire_or_renew_at(start + 27_000)
            .expect("takeover after missed heartbeat past ttl"),
        LeadershipDecision::Leader { takeover: true }
    ));
}

#[test]
fn run_key_ledger_contention_allows_single_winner() {
    let temp = tempfile::tempdir().expect("tempdir");
    let path = temp.path().join("scheduler.run_keys.jsonl");
    let barrier = Arc::new(Barrier::new(8));
    let winners = Arc::new(AtomicUsize::new(0));

    let mut handles = Vec::new();
    for _ in 0..8 {
        let barrier = Arc::clone(&barrier);
        let winners = Arc::clone(&winners);
        let path = path.clone();
        handles.push(std::thread::spawn(move || {
            let mut ledger = RunKeyLedger::new(path);
            barrier.wait();
            if ledger
                .record_once("contended-task:777")
                .expect("record once under contention")
            {
                winners.fetch_add(1, Ordering::SeqCst);
            }
        }));
    }

    for handle in handles {
        handle.join().expect("join");
    }

    assert_eq!(
        winners.load(Ordering::SeqCst),
        1,
        "exactly one contended writer should win run-key insertion"
    );
}
