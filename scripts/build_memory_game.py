"""Freeze Memory run sources and overlapping, pitch-aware excerpt difficulty.

python scripts/build_memory_game.py [--check]
No AI, downloads, Django, or changes to the original score collections.
"""
import bisect
from collections import Counter
from fractions import Fraction as F
import hashlib
import json
import math
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "frontend/IPadApp/IPadApp/Resources"
sys.path.insert(0, str(ROOT / "backend"))
from solfege.features import analyze_bytes, select_span
from solfege.features.musicxml import read_xml, parse_xml
from solfege.rhythm import current_sources, classical_label
from import_melody_library import inspect, compact

VERSION = "memory-run-v2"
DIFFICULTY = "memory-burden-v1"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def burden(record, first, bars):
    span = select_span(record, first, first + bars - 1)
    if span["external_ties"]:
        raise ValueError("external_tie")
    events = [e for e in record["events"] if first <= e["measure"] < first + bars]
    ids = {e["id"] for e in events}
    attacks = [a for a in record["attacks"] if a["id"] in ids]
    if len(attacks) < 2:
        raise ValueError("fewer_than_two_attacks")
    intervals = [i["semitones"] for i in record["intervals"] if i["from_event_id"] in ids and i["to_event_id"] in ids]
    n = len(attacks)
    mean = sum(abs(i) for i in intervals) / max(1, len(intervals))
    large = sum(abs(i) >= 7 for i in intervals) / max(1, len(intervals))
    tritone = sum(abs(i) % 12 == 6 for i in intervals) / max(1, len(intervals))
    chromatic = span["metrics"]["key_relative_alteration_count"] / n
    pitch_range = max(a["midi"] for a in attacks) - min(a["midi"] for a in attacks)
    motifs = [tuple(intervals[i:i+3]) for i in range(max(0, len(intervals)-2))]
    repeat = 1 - len(set(motifs)) / len(motifs) if motifs else 0
    measures = record["measures"][first-1:first+bars-1]
    qn = sum(F(m["actual_duration_qn"]) for m in measures)
    # These fallback meters are used only by this game experiment. Feature v1
    # leaves their unknown beat grouping unchanged.
    first_meter = measures[0]["meter"].split("/")
    numerator, denominator = map(int, first_meter)
    pulse = F(3, 2) if denominator == 8 and numerator in (6, 9, 12) else F(2) if denominator == 2 else F(1)
    density = n / float(qn / pulse)
    offbeat = sum((F(a["onset_qn"]) / pulse).denominator != 1 for a in attacks) / n
    tuplets = sum(e["tuplet_ratio"] != [1, 1] and e["id"] in {a["id"] for a in attacks} for e in events) / n
    pitch = .35*min(mean/7, 1) + .25*large + .20*min(chromatic, 1) + .10*min(pitch_range/24, 1) + .10*tritone
    memory = .55*min(n/(bars*8), 1) + .45*(1-repeat)
    rhythm = .45*offbeat + .35*min(density/4, 1) + .20*tuplets
    raw = .55*pitch + .30*memory + .15*rhythm
    fingerprint = sha(json.dumps([(a["midi"], str(F(a["absolute_onset_qn"])-F(attacks[0]["absolute_onset_qn"])), a["sounding_duration_qn"]) for a in attacks]).encode())
    return dict(raw=round(raw, 8), pitch=round(pitch, 6), memory=round(memory, 6), rhythm=round(rhythm, 6),
                attacks=n, pitchRange=pitch_range, durationQuarters=float(qn), motifRepeat=round(repeat, 6), fingerprint=fingerprint,
                meanInterval=round(mean, 6), largestInterval=max(map(abs, intervals), default=0),
                lowestMidi=min(a["midi"] for a in attacks), highestMidi=max(a["midi"] for a in attacks),
                chromaticShare=round(chromatic, 6), offbeatShare=round(offbeat, 6),
                shortestQuarter=float(min(F(a["sounding_duration_qn"]) for a in attacks)))


def build():
    sources, excerpts, generated, exceptions, groove_excluded = [], [], {}, [], []
    existing = json.loads((RES / "melody-catalog.json").read_text(encoding="utf-8"))
    candidates = [(dict(q, collection="library"), (RES / q["file"]).read_bytes(), None) for q in existing]
    for row in current_sources(ROOT / "backend/content", include_classical=True):
        m = row["metadata"]
        if m.get("collection") != "classical" and m.get("difficulty") != "intermediate":
            continue  # No high-difficulty dictation or beginner-training collection.
        raw = read_xml(ROOT / "backend/content" / row["main_path"])
        root = parse_xml(raw)
        # Exercise tempo belongs to the new game policy, never the exam policy.
        for measure in root.findall("part/measure"):
            for direction in list(measure.findall("direction")):
                measure.remove(direction)
        data = compact(root)
        try:
            _, info = inspect(data)
        except ValueError as error:
            exceptions.append(dict(sourceId=m["id"], title=m["title"], reason=str(error)))
            continue
        filename = f"memory--{m['id']}-v{m['version']}.xml"
        key = m["key_signature"]
        q = dict(id=m["id"], title=m["title"], file=filename, key=key["tonic"]+" "+key["mode"], **info,
                 sourceURL="", fifths=key["fifths"], mode=key["mode"], version=m["version"],
                 collection="classical" if m.get("collection") == "classical" else "intermediate",
                 sourceLabel=classical_label(m) if m.get("collection") == "classical" else m["title"],
                 originalXmlSha256=sha(raw))
        generated[filename] = data
        candidates.append((q, data, raw))
    for q, data, original in candidates:
        try:
            record = analyze_bytes(data, question_id=q["id"], question_version=q.get("version", 1))
        except ValueError as error:
            exceptions.append(dict(sourceId=q["id"], title=q["title"], reason=str(error)))
            continue
        q.update(sha256=sha(data), analysisKey=record["analysis_key"])
        accepted = []
        for bars in (2, 4):
            for first in range(1, 10-bars, bars):
                try:
                    metrics = burden(record, first, bars)
                    metrics["beginnerEligible"] = (bars == 2 and q.get("fifths") == 0 and q.get("mode") == "major"
                        and q["beatType"] == 4 and q["beats"] in (2, 3, 4)
                        and 3 <= metrics["attacks"] <= 8 and metrics["pitchRange"] <= 7
                        and metrics["lowestMidi"] >= 60 and metrics["highestMidi"] <= 72
                        and metrics["largestInterval"] <= 5 and metrics["meanInterval"] <= 3
                        and metrics["chromaticShare"] == 0 and metrics["shortestQuarter"] >= .5
                        and metrics["offbeatShare"] <= .34)
                    excerpt_id = f"{q['id']}:v{q.get('version',1)}:{first}:{bars}"
                    accepted.append(dict(id=excerpt_id, sourceId=q["id"], first=first, bars=bars, **metrics))
                    members = {e["id"]: e["measure"] for e in record["events"]}
                    if any(len({members[eid] for eid in a["member_event_ids"]}) > 1
                           for a in record["attacks"] if first <= members[a["id"]] < first+bars):
                        groove_excluded.append(excerpt_id)
                except ValueError as error:
                    exceptions.append(dict(sourceId=q["id"], title=q["title"], first=first, bars=bars, reason=str(error)))
        if accepted:
            sources.append(q)
            excerpts.extend(accepted)
    for bars in (2, 4):
        values = sorted(e["raw"] for e in excerpts if e["bars"] == bars)
        for e in excerpts:
            if e["bars"] == bars:
                e["score"] = round(100*(bisect.bisect_left(values, e["raw"])+bisect.bisect_right(values, e["raw"]))/2/len(values), 2)
    catalog = dict(version=VERSION, difficultyVersion=DIFFICULTY, sources=sources, excerpts=excerpts)
    catalog_bytes = (json.dumps(catalog, ensure_ascii=False, separators=(",", ":"))+"\n").encode()
    policy = dict(version="memory-groove-v1", catalogSha256=sha(catalog_bytes), excludedExcerptIds=sorted(groove_excluded))
    generated["memory-groove-v1.json"] = (json.dumps(policy, ensure_ascii=False, indent=2)+"\n").encode()
    report = dict(version=VERSION, sources=len(sources), excerpts=len(excerpts),
                  collections=dict(Counter(q["collection"] for q in sources)),
                  lengths=dict(Counter(e["bars"] for e in excerpts)),
                  beginnerExcerpts=sum(e["beginnerEligible"] for e in excerpts),
                  beginnerSources=len({e["sourceId"] for e in excerpts if e["beginnerEligible"]}),
                  grooveExcerpts=len(excerpts)-len(groove_excluded),
                  deferred=dict(Counter(e["reason"] for e in exceptions)), exceptions=exceptions)
    return catalog, generated, report


def main():
    catalog, generated, report = build()
    generated[VERSION+".json"] = (json.dumps(catalog, ensure_ascii=False, separators=(",", ":"))+"\n").encode()
    paths = {RES / name: data for name, data in generated.items()}
    paths[ROOT / "docs/memory-import-report.json"] = (json.dumps(report, ensure_ascii=False, indent=2)+"\n").encode()
    for path, data in paths.items():
        if "--check" in sys.argv:
            if not path.exists() or path.read_bytes() != data:
                raise SystemExit("Regenerate: "+str(path.relative_to(ROOT)))
        else:
            path.write_bytes(data)
    print(json.dumps({k: v for k, v in report.items() if k != "exceptions"}))


if __name__ == "__main__":
    main()
