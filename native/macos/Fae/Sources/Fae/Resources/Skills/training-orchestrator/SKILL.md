---
name: training-orchestrator
description: Personal LoRA training — export conversation data, train adapters, benchmark, and deploy.
metadata:
  author: fae
  version: "1.0"
  type: executable
---

# Personal Training Orchestrator

You manage Fae's personal LoRA fine-tuning cycle. Everything runs locally on this Mac — no data leaves the device.

## Manual Triggers

- **"Fae, export training data"** → run `export_data` script
- **"Fae, train yourself"** or **"Fae, start training"** → run `train` script, then poll `check_status`
- **"Fae, check training status"** → run `check_status` script
- **"Fae, evaluate the trained model"** → run `evaluate` script
- **"Fae, deploy the trained model"** → run `deploy` script (requires user confirmation)
- **"Fae, rollback model"** → run `rollback` script

## Autonomous Cycle (when auto-train is enabled)

The scheduler runs this weekly:
1. **Sunday 01:00** — `export_data` extracts recent conversations into training format
2. **Monday 02:00** — `train` launches LoRA fine-tuning as a background process
3. **Monday 02:00+** — `check_status` polls until training completes (max 3 polls per scheduler tick)
4. **After training** — `evaluate` benchmarks the candidate against current performance
5. **Morning briefing** — `propose` formats results for the user's review
6. **User says "deploy"** — `deploy` activates the new adapter

## Data Flow

- Episodes from `~/Library/Application Support/fae/fae.db` → SFT JSONL + DPO pairs
- Training output → `~/Library/Application Support/fae/models/personal/{timestamp}/`
- Active adapter path stored in config as `training.personalAdapterPath`

## Review Protocol

After training completes, present results conversationally:
- "I trained a personal adapter on {N} conversations. Benchmark improved from {old} to {new}. Want me to activate it?"
- If user says yes → run `deploy`
- If user says no → adapter stays in models/personal/ for later
- If user says rollback → run `rollback` to restore previous adapter

## Safety

- Training data never leaves the Mac
- User must explicitly consent before any training occurs
- Deployment requires explicit user approval
- Previous adapter is always preserved for rollback
