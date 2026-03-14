# /// script
# requires-python = ">=3.10"
# dependencies = ["huggingface-hub>=0.20"]
# ///
"""Search HuggingFace Hub for datasets."""
import json, sys
from datetime import datetime
from huggingface_hub import HfApi

def main(args: dict) -> dict:
    query = args.get("query", "instruction tuning")
    sort = args.get("sort", "downloads")
    limit = min(args.get("limit", 10), 50)
    author = args.get("author")
    filter_tags = args.get("filter_tags", [])
    api = HfApi()
    try:
        datasets = api.list_datasets(search=query, sort=sort, direction=-1, limit=limit, author=author)
        results = []
        for ds in datasets:
            tags = list(ds.tags) if ds.tags else []
            if filter_tags and not any(ft.lower() in (t.lower() for t in tags) for ft in filter_tags):
                continue
            lm = ds.last_modified.isoformat() if isinstance(ds.last_modified, datetime) else str(ds.last_modified) if ds.last_modified else None
            results.append({"dataset_id": ds.id, "downloads": ds.downloads or 0, "likes": ds.likes or 0,
                            "last_modified": lm, "tags": tags[:15], "private": ds.private})
        return {"status": "ok", "query": query, "count": len(results), "datasets": results}
    except Exception as e:
        return {"status": "error", "error": str(e)}

if __name__ == "__main__":
    raw = sys.argv[1] if len(sys.argv) > 1 else "{}"
    try: input_args = json.loads(raw)
    except json.JSONDecodeError: input_args = {"query": raw}
    print(json.dumps(main(input_args), indent=2))
