"""Pre-rendered reference images keyed by the immutable source score hash."""
import copy
import json
from functools import lru_cache
from django.conf import settings

@lru_cache(maxsize=1)
def manifest():
    return json.loads((settings.CONTENT_ROOT / "engraving/manifest.json").read_text(encoding="utf-8"))

def reference_asset(metadata):
    item = manifest()["scores"].get(metadata["score_assets"]["main"]["sha256"])
    return copy.deepcopy(item) if item else None
