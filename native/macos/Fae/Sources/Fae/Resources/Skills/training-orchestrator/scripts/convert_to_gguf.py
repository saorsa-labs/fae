# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "transformers>=5.12",
#   "torch>=2.2",
#   "safetensors>=0.4",
#   "numpy>=1.26",
#   "sentencepiece>=0.2",
# ]
# ///
#
# transformers>=5.12 matches train_peft.py: the 12B base config is `gemma4_unified`,
# which only resolves on transformers 5.12+ (the converter reads that base config).
# See train_peft.py for the uv `exclude-newer` override note.

"""Convert a PEFT LoRA adapter → GGUF (gap C2) so the llama.cpp daemon can load
it as a runtime adapter (`--lora` / `engine.reload`).

Wraps llama.cpp's `convert_lora_to_gguf.py` (validated for Gemma 4 on 2026-06-16:
it remaps `language_model.*` PEFT keys → `blk.N.*` LoRA tensors). The llama.cpp
checkout is located via `llama_cpp_dir` / `FAE_LLAMA_CPP_DIR` (production: the
bundled llama.cpp tooling — gap B2).

Input  (argv[1] = JSON): {
  "adapter_path":  "<PEFT adapter dir>",            # adapter_config.json + adapter_model.safetensors
  "base_model":    "google/gemma-4-E4B-it",         # repo id or local config dir (optional)
  "outfile":       "<personal.gguf>",
  "llama_cpp_dir": "<llama.cpp checkout>",           # else FAE_LLAMA_CPP_DIR
  "outtype":       "f16"                              # f16|bf16|q8_0|f32, default f16
}
Output (stdout JSON): { status, gguf_path, size_bytes }
"""

import json
import os
import subprocess
import sys


def resolve_base_dir(base_model):
    """Local config dir for the base model, preferring the offline HF cache.

    `convert_lora_to_gguf.py --base <dir>` reads config/tokenizer locally (no
    network). Falling back to `--base-model-id` would fetch the tensor index
    remotely (needs `requests` + network) — avoid it when the snapshot is cached.
    """
    direct = os.path.expanduser(base_model)
    if os.path.isdir(direct) and os.path.exists(os.path.join(direct, "config.json")):
        return direct
    hf_home = os.environ.get("HF_HOME") or os.path.expanduser("~/.cache/huggingface")
    repo_dir = "models--" + base_model.replace("/", "--")
    snapshots = os.path.join(hf_home, "hub", repo_dir, "snapshots")
    if os.path.isdir(snapshots):
        for name in sorted(os.listdir(snapshots)):
            candidate = os.path.join(snapshots, name)
            if os.path.exists(os.path.join(candidate, "config.json")):
                return candidate
    return None


def main():
    params = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
    adapter_path = os.path.expanduser(params.get("adapter_path", ""))
    base_model = params.get("base_model", "google/gemma-4-E4B-it")
    outfile = os.path.expanduser(params.get("outfile", ""))
    outtype = params.get("outtype", "f16")
    llama_cpp_dir = os.path.expanduser(
        params.get("llama_cpp_dir")
        or os.environ.get("FAE_LLAMA_CPP_DIR", "~/llama-spike/llama.cpp")
    )

    convert = os.path.join(llama_cpp_dir, "convert_lora_to_gguf.py")
    if not os.path.exists(convert):
        print(json.dumps({"status": "error", "error": f"convert script not found: {convert}"}))
        return 1
    if not os.path.isdir(adapter_path):
        print(json.dumps({"status": "error", "error": f"adapter not found: {adapter_path}"}))
        return 1
    if not outfile:
        print(json.dumps({"status": "error", "error": "outfile required"}))
        return 1

    args = [sys.executable, convert, adapter_path, "--outtype", outtype, "--outfile", outfile]
    base_dir = resolve_base_dir(base_model) if base_model else None
    if base_dir:
        args += ["--base", base_dir]  # offline, no network/requests
    elif base_model:
        args += ["--base-model-id", base_model]  # remote fallback (needs network)

    result = subprocess.run(args, capture_output=True, text=True, check=False)
    if result.returncode != 0 or not os.path.exists(outfile):
        print(
            json.dumps(
                {
                    "status": "error",
                    "error": "convert_lora_to_gguf failed",
                    "stderr": result.stderr[-2000:],
                }
            )
        )
        return 1

    print(
        json.dumps(
            {
                "status": "ok",
                "gguf_path": outfile,
                "size_bytes": os.path.getsize(outfile),
                "outtype": outtype,
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
