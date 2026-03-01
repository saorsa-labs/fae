#!/usr/bin/env python3
"""
Replay harness for broker policy simulation.

Input format (JSONL):
  {
    "toolName": "run_skill",
    "riskLevel": "medium",
    "requiresApproval": false,
    "isOwner": true,
    "hasCapabilityTicket": true,
    "explicitUserAuthorization": false,
    "policyProfile": "balanced"
  }

Usage:
  python3 scripts/security/replay_broker_decisions.py traces.jsonl
"""

from __future__ import annotations

import json
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path


EXPLICIT_RULE_TOOLS = {
    "read", "write", "edit", "bash", "self_config",
    "web_search", "fetch_url", "input_request",
    "activate_skill", "run_skill", "manage_skill",
    "calendar", "reminders", "contacts", "mail", "notes",
    "scheduler_list", "scheduler_create", "scheduler_update", "scheduler_delete", "scheduler_trigger",
    "roleplay",
}

HIGH_IMPACT_MEDIUM_TOOLS = {"run_skill"}


@dataclass
class Intent:
    toolName: str
    riskLevel: str
    requiresApproval: bool
    isOwner: bool
    hasCapabilityTicket: bool
    explicitUserAuthorization: bool
    policyProfile: str


def decide(intent: Intent) -> tuple[str, str]:
    if intent.toolName not in EXPLICIT_RULE_TOOLS:
        return ("deny", "noExplicitRule")
    if not intent.hasCapabilityTicket:
        return ("deny", "noCapabilityTicket")

    if not intent.isOwner and intent.riskLevel == "high":
        return ("deny", "ownerRequired")

    profile = intent.policyProfile
    risk = intent.riskLevel

    if profile == "moreCautious":
        return ("confirm", "cautiousProfile")

    if profile == "balanced":
        if intent.requiresApproval or risk == "high":
            return ("confirm", "highOrExplicitApproval")
        if risk == "medium" and intent.toolName in HIGH_IMPACT_MEDIUM_TOOLS and not intent.explicitUserAuthorization:
            return ("confirm", "ambiguousMediumHighImpact")
        return ("allow", "balancedAllow")

    if profile == "moreAutonomous":
        if intent.requiresApproval or risk == "high":
            return ("confirm", "highOrExplicitApproval")
        if risk == "medium" and intent.toolName in HIGH_IMPACT_MEDIUM_TOOLS and not intent.explicitUserAuthorization:
            return ("confirm", "ambiguousMediumHighImpact")
        if risk == "medium":
            return ("allow", "allowAutonomousMediumRisk")
        return ("allow", "autonomousAllow")

    return ("deny", "unknownProfile")


def load_intents(path: Path) -> list[Intent]:
    intents: list[Intent] = []
    with path.open("r", encoding="utf-8") as f:
        for line_no, line in enumerate(f, start=1):
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            intents.append(Intent(**obj))
    return intents


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: replay_broker_decisions.py <intents.jsonl>")
        return 2

    path = Path(sys.argv[1])
    if not path.exists():
        print(f"Input file not found: {path}")
        return 2

    intents = load_intents(path)
    decision_counts = Counter()
    reason_counts = Counter()

    for intent in intents:
        decision, reason = decide(intent)
        decision_counts[decision] += 1
        reason_counts[reason] += 1

    print("== Replay Summary ==")
    print(f"Total intents: {len(intents)}")
    print("Decisions:")
    for k, v in decision_counts.most_common():
        print(f"  {k:>8}: {v}")

    print("Reasons:")
    for k, v in reason_counts.most_common():
        print(f"  {k:>28}: {v}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
