"""Separate imports keep the existing immutable exercise versions intact."""
import json
from functools import lru_cache
from django.conf import settings


def shipped_questions():
    result = []
    order_path = settings.CONTENT_ROOT / "classical-question-order.json"
    classical_order = {qid:1001+index for index,qid in enumerate(json.loads(order_path.read_text(encoding="utf-8")))} if order_path.exists() else {}
    for name in ("catalog.json", "classical-catalog.json", "additional-practice-catalog.json", "sheet-revisions.json", "brahms-catalog.json", "classical-tempo-revisions.json", "mahler-catalog.json"):
        path = settings.CONTENT_ROOT / name
        if path.exists():
            result.extend(json.loads(path.read_text(encoding="utf-8")))
    for item in result:
        if item["metadata"].get("collection") == "classical" and item["metadata"]["id"] in classical_order:
            item["order"] = classical_order[item["metadata"]["id"]]
    return result


@lru_cache(maxsize=1)
def intermediate_legacy_ids():
    items = json.loads((settings.CONTENT_ROOT / "catalog.json").read_text(encoding="utf-8"))
    return {item["metadata"]["id"] for item in items if item["order"] <= 3}


def practice_difficulty(metadata):
    if metadata.get("collection") == "classical":
        return None
    return metadata.get("difficulty") or ("intermediate" if metadata["id"] in intermediate_legacy_ids() else "advanced")
