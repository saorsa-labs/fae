# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "transformers>=5.12",
#   "torch>=2.2",
#   "peft>=0.11",
#   "accelerate>=0.30",
#   "safetensors>=0.4",
#   "sentencepiece>=0.2",
# ]
# ///
#
# transformers>=5.12 is REQUIRED for the production 12B tier: that base ships as
# the `gemma4_unified` architecture (native-audio variant), which only landed in
# transformers 5.12 (verified 2026-06-16: 5.8.1 lacks it). The E4B tier (`gemma4`)
# also loads cleanly on 5.12. NOTE: if uv enforces an `exclude-newer` cutoff
# earlier than transformers 5.12's publish date (2026-06-15), override it per
# package, e.g. `uv run --exclude-newer-package 'transformers=<date>' …`.

"""Cross-platform LoRA SFT trainer (gap C2) — produces a **PEFT** adapter.

The portable training lane: plain `peft` + `transformers`, device-auto
(CUDA on NVIDIA, MPS on Apple, CPU fallback). The PEFT output feeds
`convert_to_gguf.py` → a GGUF the llama.cpp daemon loads directly (the
validated personalization path). Unsloth (NVIDIA, lower VRAM) accelerates this
same PEFT path and is a drop-in optimization for later — the artifact format is
identical.

Critical (thinking-alignment finding, 2026-06-16): Gemma 4's served, thinking-
enabled turn opens with a thought channel — `<|channel>thought\n…<channel|>` —
*before* the answer. The chat template's `strip_thinking` macro removes that
channel from assistant content, so templating a full `{user, assistant}` message
list yields a **bare-answer** target glued to `<|turn>model\n`. A LoRA trained on
that learns to answer in a position the served model never occupies (it emits a
thought span first), so the personalization does not surface through the chat
endpoint. The fix: build the assistant target BY HAND as
`<|channel>thought\n{thinking}\n<channel|>{answer}<turn|>\n` — bypassing
strip_thinking — so the answer lands in the post-thinking position the served
template generates. The thinking trace is taken from an optional `reasoning`/
`thinking` field on the assistant message (captured at conversation time) or
synthesized when absent.

Input  (argv[1] = JSON): {
  "sft_path":     "<sft_export.jsonl>",          # {messages:[{role,content[,reasoning]}...]} per line
  "base_model":   "google/gemma-4-E4B-it",
  "output_dir":   "<dir for the adapter>",
  "preset":       "smoke|light|standard|deep",   # default "light"
  "max_examples": <int optional cap>
}
Output (stdout JSON): { status, adapter_path, model_id, device, steps, final_loss }
Writes: <output_dir>/adapter_model.safetensors + adapter_config.json,
        <output_dir>/train_metrics.json
"""

import json
import os
import sys
import time

PRESET_MAP = {
    "smoke": {"max_steps": 10, "lr": 1e-4, "lora_r": 8, "max_seq_length": 1024},
    "light": {"max_steps": 60, "lr": 2e-4, "lora_r": 16, "max_seq_length": 1024},
    "standard": {"max_steps": 200, "lr": 1e-4, "lora_r": 16, "max_seq_length": 2048},
    "deep": {"max_steps": 500, "lr": 5e-5, "lora_r": 32, "max_seq_length": 2048},
}

# LoRA on the language model's attention + MLP projections ONLY. lm_head / tied
# embeddings are excluded — they break `convert_lora_to_gguf.py` (llama.cpp
# issue #9065). Scoped to `language_model.*` so we never wrap the vision/audio
# towers of a multimodal Gemma 4.
TARGET_MODULES = (
    r".*language_model.*\.(q_proj|k_proj|v_proj|o_proj|gate_proj|up_proj|down_proj)$"
)

# Gemma 4 thinking-channel markers (Harmony-style, verified against the GGUF /props
# template 2026-06-16) — NOT `<think>`. The served, thinking-enabled turn emits
# `<|turn>model\n<|channel>thought\n…<channel|>{answer}<turn|>`.
THOUGHT_OPEN = "<|channel>thought\n"
THOUGHT_CLOSE = "<channel|>"
TURN_CLOSE = "<turn|>\n"


def synth_thinking(user_text):
    """A short, answer-free reasoning span for examples with no captured trace.

    Deliberately generic and free of the answer text: the LoRA must learn the
    answer in the post-thinking position, not memorize a fixed thinking→answer
    string pair. Mirrors the brief planning style the served model produces.
    """
    snippet = (user_text or "").strip().replace("\n", " ")
    if len(snippet) > 160:
        snippet = snippet[:157] + "…"
    return (
        f"The user asked: {snippet} "
        "I know the relevant detail and will answer it directly and concisely."
    )


def pick_device():
    import torch

    if torch.cuda.is_available():
        return "cuda"
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def load_examples(path, cap):
    examples = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            messages = row.get("messages")
            if isinstance(messages, list) and messages:
                examples.append(messages)
            if cap and len(examples) >= cap:
                break
    return examples


def main():
    params = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
    sft_path = params.get("sft_path")
    base_model = params.get("base_model", "google/gemma-4-E4B-it")
    output_dir = os.path.expanduser(params.get("output_dir", "./peft-adapter"))
    preset = params.get("preset", "light")
    cap = params.get("max_examples")
    cfg = PRESET_MAP.get(preset, PRESET_MAP["light"])

    if not sft_path or not os.path.exists(sft_path):
        print(json.dumps({"status": "error", "error": f"sft_path not found: {sft_path}"}))
        return 1

    import torch
    from peft import LoraConfig, get_peft_model
    from transformers import AutoModelForImageTextToText, AutoTokenizer

    device = pick_device()
    examples = load_examples(sft_path, cap)
    if not examples:
        print(json.dumps({"status": "error", "error": "no training examples"}))
        return 1

    tok = AutoTokenizer.from_pretrained(base_model)
    model = AutoModelForImageTextToText.from_pretrained(base_model, dtype=torch.bfloat16).to(device)
    model.config.use_cache = False

    lora = LoraConfig(
        r=cfg["lora_r"],
        lora_alpha=cfg["lora_r"] * 2,
        lora_dropout=0.0,
        bias="none",
        task_type="CAUSAL_LM",
        target_modules=TARGET_MODULES,
    )
    model = get_peft_model(model, lora)

    # Prompt is templated (the exact format llama-server applies, ending in
    # `<|turn>model\n`); the assistant target is built BY HAND with a thinking
    # span so the answer lands in the post-thinking position the served,
    # thinking-enabled model generates. We do NOT template the assistant turn —
    # the template's strip_thinking macro would delete the thought channel,
    # collapsing the target back to a bare answer. Loss is on the target only.
    def encode(messages):
        if messages and messages[-1].get("role") == "assistant":
            prompt_msgs, answer_msg = messages[:-1], messages[-1]
        else:
            prompt_msgs, answer_msg = messages, {}
        prompt = tok.apply_chat_template(prompt_msgs, tokenize=False, add_generation_prompt=True)
        answer = (answer_msg.get("content") or "").strip()
        thinking = (answer_msg.get("reasoning") or answer_msg.get("thinking") or "").strip()
        if not thinking:
            last_user = next(
                (m.get("content", "") for m in reversed(prompt_msgs) if m.get("role") == "user"),
                "",
            )
            thinking = synth_thinking(last_user)
        target = f"{THOUGHT_OPEN}{thinking}\n{THOUGHT_CLOSE}{answer}{TURN_CLOSE}"
        full = prompt + target
        p_ids = tok(prompt, add_special_tokens=False)["input_ids"]
        f_ids = tok(full, add_special_tokens=False)["input_ids"][: cfg["max_seq_length"]]
        labels = [-100] * min(len(p_ids), len(f_ids)) + f_ids[len(p_ids):]
        labels = labels[: len(f_ids)]
        return torch.tensor(f_ids), torch.tensor(labels)

    data = [encode(m) for m in examples]
    opt = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=cfg["lr"])

    model.train()
    steps = cfg["max_steps"]
    t0 = time.time()
    last_loss = 0.0
    for step in range(steps):
        ids, labels = data[step % len(data)]
        ids = ids.unsqueeze(0).to(device)
        labels = labels.unsqueeze(0).to(device)
        out = model(input_ids=ids, labels=labels)
        out.loss.backward()
        opt.step()
        opt.zero_grad()
        last_loss = float(out.loss.item())
        if step % 20 == 0 or step == steps - 1:
            print(f"step {step:3d}  loss {last_loss:.4f}", file=sys.stderr, flush=True)

    os.makedirs(output_dir, exist_ok=True)
    model.save_pretrained(output_dir)
    with open(os.path.join(output_dir, "train_metrics.json"), "w", encoding="utf-8") as handle:
        json.dump(
            {
                "final_loss": last_loss,
                "total_steps": steps,
                "model_id": base_model,
                "lora_r": cfg["lora_r"],
                "max_seq_length": cfg["max_seq_length"],
                "device": device,
                "examples": len(examples),
            },
            handle,
        )

    print(
        json.dumps(
            {
                "status": "ok",
                "adapter_path": output_dir,
                "model_id": base_model,
                "device": device,
                "steps": steps,
                "final_loss": last_loss,
                "engine": "peft",
                "elapsed_s": round(time.time() - t0, 1),
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
