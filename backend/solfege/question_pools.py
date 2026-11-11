"""Frozen membership; independent of immutable questions and difficulty cutoffs."""
import json
from functools import lru_cache
from pathlib import Path

PATH = Path(__file__).resolve().parents[1] / "content/question-pools.json"
VERSION = "question-pools-1"


@lru_cache(maxsize=1)
def manifest():
    value = json.loads(PATH.read_text(encoding="utf8"))
    if value["version"] != VERSION:
        raise ValueError("unsupported_question_pool_version")
    return value


def ids(pool):
    if pool not in ("exam", "practice"):
        raise ValueError("invalid_question_pool")
    return [qid for qid, entry in manifest()["records"].items() if entry["pool"] == pool]


def membership(question_id):
    return manifest()["records"].get(str(question_id), {}).get("pool")
