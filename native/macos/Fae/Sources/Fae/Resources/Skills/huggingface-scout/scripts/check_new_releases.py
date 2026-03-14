# /// script
# requires-python = ">=3.10"
# dependencies = ["huggingface-hub>=0.20"]
# ///
"""Check for new model releases on HuggingFace since a given date."""
import json, sys
from datetime import datetime, timezone
from huggingface_hub import HfApi

FAE_MODELS = {"mlx-community/Qwen3.5-0.8B-4bit","mlx-community/Qwen3.5-2B-4bit","mlx-community/Qwen3.5-4B-4bit",
              "mlx-community/Qwen3.5-9B-4bit","mlx-community/Qwen3.5-27B-4bit","LiquidAI/LFM2-24B-A2B-MLX-4bit"}
DEFAULT_AUTHORS = ["mlx-community", "Qwen", "LiquidAI", "hexgrad"]
DEFAULT_FAMILIES = ["Qwen3.5", "Qwen3", "LFM", "Kokoro"]

def main(args: dict) -> dict:
    since_str = args.get("since")
    if not since_str: return {"status": "error", "error": "'since' required (ISO date)"}
    try: since = datetime.fromisoformat(since_str).replace(tzinfo=timezone.utc)
    except ValueError as e: return {"status": "error", "error": str(e)}
    authors = args.get("authors", DEFAULT_AUTHORS)
    families = args.get("families", DEFAULT_FAMILIES)
    limit = min(args.get("limit", 10), 50)
    min_dl = args.get("min_downloads", 50)
    api = HfApi()
    new, seen = [], set()
    try:
        for author in authors:
            for fam in families:
                for m in api.list_models(search=fam, author=author, sort="lastModified", direction=-1, limit=limit):
                    if m.id in seen: continue
                    seen.add(m.id)
                    mod = m.last_modified
                    if not mod: continue
                    if isinstance(mod, str): mod = datetime.fromisoformat(mod)
                    if mod.tzinfo is None: mod = mod.replace(tzinfo=timezone.utc)
                    if mod < since: continue
                    if (m.downloads or 0) < min_dl: continue
                    new.append({"model_id": m.id, "downloads": m.downloads or 0, "likes": m.likes or 0,
                                "last_modified": mod.isoformat(), "tags": list(m.tags or [])[:10],
                                "is_current": m.id in FAE_MODELS})
        new.sort(key=lambda x: x["downloads"], reverse=True)
        return {"status": "ok", "since": since_str, "new_count": len(new), "models": new[:50]}
    except Exception as e:
        return {"status": "error", "error": str(e)}

if __name__ == "__main__":
    raw = sys.argv[1] if len(sys.argv) > 1 else "{}"
    try: input_args = json.loads(raw)
    except json.JSONDecodeError: input_args = {"query": raw}
    print(json.dumps(main(input_args), indent=2))
