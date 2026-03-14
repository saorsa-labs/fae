# /// script
# requires-python = ">=3.10"
# dependencies = ["huggingface-hub>=0.20"]
# ///
"""Evaluate a HuggingFace model for Fae compatibility."""
import json, sys
from huggingface_hub import HfApi, hf_hub_download
from huggingface_hub.utils import EntryNotFoundError, RepositoryNotFoundError

def main(args: dict) -> dict:
    model_id = args.get("model_id", "").strip()
    if not model_id: return {"status": "error", "error": "model_id required"}
    api = HfApi()
    try: info = api.model_info(model_id)
    except RepositoryNotFoundError: return {"status": "error", "error": f"Not found: {model_id}"}
    except Exception as e: return {"status": "error", "error": str(e)}

    tags = list(info.tags) if info.tags else []
    lib = info.library_name
    checks, issues, recs = [], [], []

    # Config
    config = None
    try:
        p = hf_hub_download(repo_id=model_id, filename="config.json", repo_type="model")
        with open(p) as f: config = json.load(f)
    except Exception: pass

    # Library
    compat_libs = {"mlx", "transformers", "coreml"}
    if lib and lib.lower() in compat_libs: checks.append(f"Library: {lib} (compatible)")
    elif lib: checks.append(f"Library: {lib} (may need conversion)"); issues.append(f"Library '{lib}' not native")

    # MLX
    is_mlx = "mlx" in (lib or "").lower() or any("mlx" in t.lower() for t in tags)
    if is_mlx: checks.append("MLX: native")
    else:
        base = model_id.split("/")[-1]
        for sfx in ["-4bit","-8bit","-bf16","-MLX","-mlx","-GGUF"]: base = base.replace(sfx, "")
        variants = [m.id for m in api.list_models(search=f"{base} MLX", author="mlx-community", limit=3) if base.lower() in m.id.lower()]
        if variants: recs.append(f"MLX variant: {variants[0]}")
        else: issues.append("No MLX variant found")

    # Context + arch
    ctx = arch = quant = params = None
    if config:
        arch = config.get("model_type") or (config.get("architectures") or [None])[0]
        ctx = config.get("max_position_embeddings") or config.get("max_seq_len")
        quant = (config.get("quantization_config") or {}).get("quant_method")
        if arch: checks.append(f"Architecture: {arch}")
        if ctx:
            ok = ctx >= 32768
            checks.append(f"Context: {ctx:,} ({'OK' if ok else 'below 32K'})")
            if not ok: issues.append(f"Context {ctx:,} < 32K minimum")
        if quant: checks.append(f"Quantization: {quant}")

    # License
    lic = next((t.split(":",1)[1] for t in tags if t.startswith("license:")), None)
    if lic: checks.append(f"License: {lic}")

    # Downloads
    dl = info.downloads or 0
    checks.append(f"Downloads: {dl:,}")
    if dl < 100: issues.append("Very low downloads")

    verdict = "compatible" if not issues else ("needs_conversion" if any("MLX" in i for i in issues) else "compatible_with_caveats")
    return {"status": "ok", "model_id": model_id, "verdict": verdict, "checks": checks, "issues": issues,
            "recommendations": recs, "summary": {"arch": arch, "context": ctx, "quant": quant, "library": lib,
            "is_mlx": is_mlx, "downloads": dl, "license": lic}}

if __name__ == "__main__":
    raw = sys.argv[1] if len(sys.argv) > 1 else "{}"
    try: input_args = json.loads(raw)
    except json.JSONDecodeError: input_args = {"model_id": raw}
    print(json.dumps(main(input_args), indent=2))
