"""Separate catalogs keep the 62 existing, immutable exercise versions intact."""
import json
from django.conf import settings


def shipped_questions():
    result = []
    for name in ("catalog.json", "classical-catalog.json"):
        path = settings.CONTENT_ROOT / name
        if path.exists():
            result.extend(json.loads(path.read_text(encoding="utf-8")))
    return result
