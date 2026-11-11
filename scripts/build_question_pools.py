"""Freeze roughly 20% as Exam, balanced along continuous difficulty scores.

Existing membership never moves. Exact melodic transpositions stay together.
Files, IDs, score versions, difficulty scores and minigame catalogs are untouched.
"""
import collections
import hashlib
import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
from solfege.features.musicxml import decode, read_xml
from solfege.question_pools import VERSION

CONTENT = ROOT / "backend/content"
RESOURCE = ROOT / "frontend/IPadApp/IPadApp/Resources"


def family(path):
    measures, _, attacks, _ = decode(read_xml(path), "pool-family", {})
    tonic = attacks[0]["midi"] if attacks else 0
    value = [[(m["meter"], m["actual_duration_qn"]) for m in measures],
             [(a["midi"]-tonic, a["absolute_onset_qn"], a["sounding_duration_qn"]) for a in attacks]]
    return hashlib.sha256(json.dumps(value, separators=(",", ":")).encode()).hexdigest()


def build():
    difficulty = json.loads((CONTENT / "practice-difficulty.json").read_text(encoding="utf8"))
    rows = {}
    for name in ("catalog.json", "additional-practice-catalog.json", "sheet-revisions.json", "practice-bank-catalog.json"):
        for row in json.loads((CONTENT / name).read_text(encoding="utf8")):
            q = row["metadata"]
            if q["id"] not in rows or q["version"] > rows[q["id"]]["metadata"]["version"]:
                rows[q["id"]] = row
    path = CONTENT / "question-pools.json"
    value = json.loads(path.read_text(encoding="utf8")) if path.exists() else dict(
        version=VERSION, selection_difficulty_version=difficulty["version"], exam_fraction=.2,
        seed="solfege-exam-pool-2026-11-12", records={})
    if value["version"] != VERSION:
        raise ValueError("unsupported_existing_pool")
    records = value["records"]
    groups = collections.defaultdict(list)
    for qid, score in difficulty["records"].items():
        fingerprint = records[qid]["family"] if qid in records else family(CONTENT / rows[qid]["main_path"])
        groups[fingerprint].append(qid)
    existing_by_family = {}
    for entry in records.values():
        if entry["family"] in existing_by_family and existing_by_family[entry["family"]] != entry["pool"]:
            raise ValueError("family_crosses_pools")
        existing_by_family[entry["family"]] = entry["pool"]
    pending = []
    for key, members in groups.items():
        new = [qid for qid in members if qid not in records]
        if not new:
            continue
        if key in existing_by_family:
            for qid in new:
                records[qid] = dict(pool=existing_by_family[key], family=key)
        else:
            pending.append((key, new))
    pending.sort(key=lambda g: (sum(difficulty["records"][q]["score"] for q in g[1])/len(g[1]), g[0]))
    rng = random.Random(value["seed"])
    # Approximately 50 questions per adjacent score stratum. No level quotas.
    bins, bucket, size = [], [], 0
    for group in pending:
        if size >= 50:
            bins.append(bucket); bucket, size = [], 0
        bucket.append(group); size += len(group[1])
    if bucket:
        bins.append(bucket)
    cumulative = assigned = 0
    for bucket in bins:
        cumulative += sum(len(members) for _, members in bucket)
        target = round(cumulative*.2)-assigned
        rng.shuffle(bucket)
        chosen, count = set(), 0
        for key, members in bucket:
            if abs(target-count-len(members)) < abs(target-count):
                chosen.add(key); count += len(members)
        assigned += count
        for key, members in bucket:
            for qid in members:
                records[qid] = dict(pool="exam" if key in chosen else "practice", family=key)
    value["records"] = dict(sorted(records.items()))
    raw = json.dumps(value, ensure_ascii=False, indent=2)+"\n"
    for target in (path, RESOURCE / path.name):
        target.write_text(raw, encoding="utf8")
    counts = collections.Counter(records[qid]["pool"] for qid in difficulty["records"])
    print(json.dumps(dict(version=value["version"], counts=dict(counts), families=len(groups)), ensure_ascii=False))


if __name__ == "__main__":
    build()
