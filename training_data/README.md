Historical compatibility directory.

Current generated datasets live in `training/data/` and are produced by
`scripts/prepare_training_data.py` from every `*-post-train-data.md` file in the
project root.

Run that script to regenerate the current outputs:

```bash
python3 scripts/prepare_training_data.py
```

The source of truth is the markdown files. The JSONL files are derived outputs and are not committed to git.

## Files produced

- `training/data/dpo.jsonl` — DPO preference pairs (prompt / chosen / rejected).
- `training/data/sft.jsonl` — SFT chat examples in messages format.
- `training/data/dpo_train.jsonl` / `training/data/dpo_val.jsonl` — 90/10 split of DPO pairs (with `--split` flag).
- `training/data/sft_train.jsonl` / `training/data/sft_val.jsonl` — 90/10 split of SFT examples (with `--split` flag).
