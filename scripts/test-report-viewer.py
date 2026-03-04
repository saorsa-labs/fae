#!/usr/bin/env python3
"""Fae Comprehensive Test Report Viewer

Reads the latest JSON report from tests/comprehensive/reports/ and displays
a formatted summary with pass/fail/skip counts per phase, failed test details,
and overall metrics.

Usage:
    python3 scripts/test-report-viewer.py [report-file]
    just test-report
"""

import json
import sys
from pathlib import Path
from collections import defaultdict

# Colors (only when stdout is a terminal)
USE_COLOR = sys.stdout.isatty()
GREEN = "\033[92m" if USE_COLOR else ""
RED = "\033[91m" if USE_COLOR else ""
YELLOW = "\033[93m" if USE_COLOR else ""
CYAN = "\033[96m" if USE_COLOR else ""
BOLD = "\033[1m" if USE_COLOR else ""
DIM = "\033[2m" if USE_COLOR else ""
RESET = "\033[0m" if USE_COLOR else ""


def find_latest_report():
    """Find the most recent report file."""
    report_dir = Path(__file__).parent.parent / "tests" / "comprehensive" / "reports"
    if not report_dir.exists():
        print(f"{RED}No reports directory found{RESET}")
        sys.exit(1)
    reports = sorted(report_dir.glob("report-*.json"), reverse=True)
    if not reports:
        print(f"{RED}No report files found in {report_dir}{RESET}")
        sys.exit(1)
    return reports[0]


def load_report(path):
    """Load and parse a report JSON file."""
    with open(path) as f:
        return json.load(f)


def print_summary(report):
    """Print phase-by-phase summary table with details on failures."""
    results = report.get("results", [])
    summary = report.get("summary", {})
    duration = report.get("duration_s", 0)
    model = report.get("model", "unknown")
    timestamp = report.get("timestamp", "unknown")

    # Group results by phase
    phases = defaultdict(lambda: {"passed": 0, "failed": 0, "skipped": 0, "total": 0})
    failed_tests = []
    skipped_tests = []

    for r in results:
        phase = r.get("phase", "unknown")
        phases[phase]["total"] += 1
        if r.get("skipped", False):
            phases[phase]["skipped"] += 1
            skipped_tests.append(r)
        elif r.get("pass", False):
            phases[phase]["passed"] += 1
        else:
            phases[phase]["failed"] += 1
            failed_tests.append(r)

    # Header
    print(f"{DIM}Model: {model}  |  Timestamp: {timestamp}{RESET}")
    if duration:
        mins = int(duration) // 60
        secs = int(duration) % 60
        print(f"{DIM}Duration: {mins}m {secs}s{RESET}")
    print()

    # Phase table
    header = f"{'Phase':<30} {'Pass':>6} {'Fail':>6} {'Skip':>6} {'Total':>6}"
    print(f"{BOLD}{header}{RESET}")
    print("-" * len(header))

    for phase in sorted(phases.keys()):
        p = phases[phase]
        pass_str = f"{GREEN}{p['passed']}{RESET}" if p["passed"] else "0"
        fail_str = f"{RED}{p['failed']}{RESET}" if p["failed"] else "0"
        skip_str = f"{YELLOW}{p['skipped']}{RESET}" if p["skipped"] else "0"
        # Pad accounting for ANSI escape codes
        pass_pad = 6 + (len(pass_str) - len(str(p["passed"])))
        fail_pad = 6 + (len(fail_str) - len(str(p["failed"])))
        skip_pad = 6 + (len(skip_str) - len(str(p["skipped"])))
        print(
            f"{phase:<30} {pass_str:>{pass_pad}} {fail_str:>{fail_pad}} "
            f"{skip_str:>{skip_pad}} {p['total']:>6}"
        )

    print("-" * len(header))
    total = summary.get("total", len(results))
    passed = summary.get("passed", sum(p["passed"] for p in phases.values()))
    failed = summary.get("failed", sum(p["failed"] for p in phases.values()))
    skipped = summary.get("skipped", sum(p["skipped"] for p in phases.values()))
    t_pass = f"{GREEN}{passed}{RESET}" if passed else "0"
    t_fail = f"{RED}{failed}{RESET}" if failed else "0"
    t_skip = f"{YELLOW}{skipped}{RESET}" if skipped else "0"
    t_pass_pad = 6 + (len(t_pass) - len(str(passed)))
    t_fail_pad = 6 + (len(t_fail) - len(str(failed)))
    t_skip_pad = 6 + (len(t_skip) - len(str(skipped)))
    print(
        f"{BOLD}{'TOTAL':<30}{RESET} {t_pass:>{t_pass_pad}} {t_fail:>{t_fail_pad}} "
        f"{t_skip:>{t_skip_pad}} {total:>6}"
    )
    print()

    # Failed tests detail
    if failed_tests:
        print(f"{RED}{BOLD}FAILED TESTS ({len(failed_tests)}):{RESET}")
        print()
        for t in failed_tests:
            test_id = t.get("test_id", "?")
            phase = t.get("phase", "?")
            phrasing = t.get("phrasing_used", "")
            scores = t.get("scores", [])
            notes = t.get("notes", "")

            print(f"  {RED}{test_id}{RESET} [{phase}]")
            if phrasing:
                print(f"    Phrasing: {DIM}{phrasing}{RESET}")
            for s in scores:
                criterion = s.get("criterion", "?")
                score = s.get("score", 0)
                evidence = s.get("evidence", "")
                color = GREEN if score >= 0.8 else (YELLOW if score >= 0.5 else RED)
                print(f"    {color}{criterion}: {score:.1f}{RESET}", end="")
                if evidence:
                    print(f"  {DIM}{evidence[:80]}{RESET}", end="")
                print()
            if notes:
                print(f"    Note: {notes}")
            print()

    # Skipped tests
    if skipped_tests:
        print(f"{YELLOW}SKIPPED TESTS ({len(skipped_tests)}):{RESET}")
        for t in skipped_tests:
            test_id = t.get("test_id", "?")
            notes = t.get("notes", "no reason given")
            print(f"  {YELLOW}{test_id}{RESET}: {DIM}{notes}{RESET}")
        print()

    # Overall pass rate
    if total > 0:
        non_skipped = total - skipped
        if non_skipped > 0:
            rate = (passed / non_skipped) * 100
        else:
            rate = 100.0
        color = GREEN if rate == 100 else (YELLOW if rate >= 90 else RED)
        print(
            f"{BOLD}Pass rate: {color}{rate:.1f}%{RESET} "
            f"({passed}/{non_skipped} executed, {skipped} skipped)"
        )
    else:
        print(f"{YELLOW}No test results found.{RESET}")

    return len(failed_tests)


def main():
    if len(sys.argv) > 1:
        report_path = Path(sys.argv[1])
        if not report_path.exists():
            print(f"{RED}Report file not found: {report_path}{RESET}")
            sys.exit(1)
    else:
        report_path = find_latest_report()

    print(f"{BOLD}Fae Comprehensive Test Report{RESET}")
    print(f"Report: {report_path.name}")
    print()

    report = load_report(report_path)
    failures = print_summary(report)
    sys.exit(1 if failures > 0 else 0)


if __name__ == "__main__":
    main()
