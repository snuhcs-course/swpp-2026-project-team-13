"""Separate imports keep the existing immutable exercise versions intact."""
import json
from functools import lru_cache
from django.conf import settings


def shipped_questions():
    result = []
    for name in ("catalog.json", "classical-catalog.json", "additional-practice-catalog.json", "sheet-revisions.json"):
        path = settings.CONTENT_ROOT / name
        if path.exists():
            result.extend(json.loads(path.read_text(encoding="utf-8")))
    return result


@lru_cache(maxsize=1)
def intermediate_legacy_ids():
    items = json.loads((settings.CONTENT_ROOT / "catalog.json").read_text(encoding="utf-8"))
    return {item["metadata"]["id"] for item in items if item["order"] <= 3}


def practice_difficulty(metadata):
    if metadata.get("collection") == "classical":
        return None
    return metadata.get("difficulty") or ("intermediate" if metadata["id"] in intermediate_legacy_ids() else "advanced")
