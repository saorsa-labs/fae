# /// script
# requires-python = ">=3.10"
# dependencies = ["huggingface-hub>=0.20"]
# ///
"""Search HuggingFace Hub for models."""
import json, sys
from datetime import datetime
from huggingface_hub import HfApi

def main(args: dict) -> dict:
    query = args.get("query", "Qwen MLX")
    sort = args.get("sort", "downloads")
    limit = min(args.get("limit", 10), 50)
    author = args.get("author")
    filter_tags = args.get("filter_tags", [])
    api = HfApi()
    try:
        models = api.list_models(search=query, sort=sort, direction=-1, limit=limit, author=author)
        results = []
        for m in models:
            tags = list(m.tags) if m.tags else []
            if filter_tags and not any(ft.lower() in (t.lower() for t in tags) for ft in filter_tags):
                continue
            lm = m.last_modified.isoformat() if isinstance(m.last_modified, datetime) else str(m.last_modified) if m.last_modified else None
            results.append({"model_id": m.id, "downloads": m.downloads or 0, "likes": m.likes or 0,
                            "last_modified": lm, "tags": tags[:15], "pipeline_tag": m.pipeline_tag, "library": m.library_name})
        return {"status": "ok", "query": query, "count": len(results), "models": results}
    except Exception as e:
        return {"status": "error", "error": str(e)}

if __name__ == "__main__":
    raw = sys.argv[1] if len(sys.argv) > 1 else "{}"
    try: input_args = json.loads(raw)
    except json.JSONDecodeError: input_args = {"query": raw}
    print(json.dumps(main(input_args), indent=2))
