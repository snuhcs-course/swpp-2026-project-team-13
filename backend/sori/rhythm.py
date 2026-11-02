"""Rhythm Puzzle: exact score-derived pieces and sounding-time grading, no AI."""
import copy
import hashlib
import json
import math
from collections import Counter
from fractions import Fraction as F
from pathlib import Path

from .features import analyze, select_span, FeatureError
from .features.musicxml import parse_xml, read_xml

VERSION = "rhythm-puzzle-v1"
DIFFICULTY_VERSION = "rhythm-burden-v1"
CATALOG_FILES = ("catalog.json", "additional-practice-catalog.json", "sheet-revisions.json")


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()


def fraction(value):
    if not isinstance(value, str) or len(value) > 32:
        raise ValueError("invalid_fraction")
    result = F(value)
    if str(result) != value or abs(result) > 128 or result.denominator > 10000:
        raise ValueError("invalid_fraction")
    return result


def current_sources(root):
    latest = {}
    for name in CATALOG_FILES:
        for row in json.loads((root / name).read_text(encoding="utf-8")):
            m = row["metadata"]
            if m["id"] not in latest or m["version"] > latest[m["id"]]["metadata"]["version"]:
                latest[m["id"]] = row
    return sorted(latest.values(), key=lambda q: (q["order"], q["metadata"]["id"]))


def tile(symbols):
    # No source pitch, beam or external tie state can disclose a tile's position.
    result = dict(duration=str(sum((F(n["duration"]) for n in symbols), F(0))), symbols=symbols)
    result["id"] = digest(result)
    return result


def source_symbols(record, raw):
    """Preserve an explicitly bracketed tuplet as one atomic piece, including 2-beat groups."""
    nodes = parse_xml(raw).findall("part/measure/note")
    if len(nodes) != len(record["events"]):
        raise ValueError("source_event_count_mismatch")
    result, opened, group = {}, None, 0
    for event, node in zip(record["events"], nodes):
        markers = node.findall("notations/tuplet")
        starts = [n for n in markers if n.get("type") == "start"]
        stops = [n for n in markers if n.get("type") == "stop"]
        if len(starts) > 1 or len(stops) > 1 or (starts and opened is not None):
            raise ValueError("nested_tuplet_requires_review")
        if starts:
            group += 1
            opened = (starts[0].get("number", "1"), group)
        ratio = event["tuplet_ratio"]
        if ratio != [1, 1] and opened is None:
            raise ValueError("tuplet_group_not_explicit")
        symbol = dict(duration=event["duration_qn"], rest=event["kind"] == "rest",
                      type=event["type"], dots=event["dots"], actual=ratio[0], normal=ratio[1],
                      group=opened[1] if opened else 0, tie_next=event["tie_start"],
                      group_end=bool(stops))
        result[event["id"]] = symbol
        if stops:
            if opened is None or stops[0].get("number", "1") != opened[0]:
                raise ValueError("tuplet_group_unbalanced")
            opened = None
    if opened:
        raise ValueError("tuplet_group_unbalanced")
    return result


def pieces_for_span(record, symbols, first, last):
    span = select_span(record, first, last)
    if span["external_ties"]:
        raise ValueError("external_tie")
    measures = record["measures"][first - 1:last]
    if any(m["pulse_qn"] is None for m in measures):
        raise ValueError("needs_beat_grouping")
    if any(m["meter"] != measures[0]["meter"] or m["actual_duration_qn"] != m["expected_duration_qn"] for m in measures):
        raise ValueError("incomplete_or_changing_meter")
    events = [e for e in record["events"] if first <= e["measure"] <= last]
    if any(e["type"] is None for e in events):
        raise ValueError("missing_note_type")
    # The current MIDI transport uses 480 PPQ. Never silently round a new tuplet.
    if any((F(e[k]) * 480).denominator != 1 for e in events for k in ("onset_qn", "duration_qn")):
        raise ValueError("audio_resolution_requires_review")
    origin = F(events[0]["absolute_onset_qn"])
    pulse = F(measures[0]["pulse_qn"])
    placements, tiles, ties = [], {}, []
    for m in measures:
        chunk, chunk_start, local_end = [], None, F(0)
        for e in [e for e in events if e["measure"] == m["number"]]:
            n = copy.deepcopy(symbols[e["id"]])
            if chunk_start is None:
                chunk_start = F(e["absolute_onset_qn"]) - origin
            chunk.append(n)
            local_end = F(e["onset_qn"]) + F(e["duration_qn"])
            in_tuplet = n["group"] != 0 and not n["group_end"]
            # Stop at or after the next pulse boundary, never cut a written note/group.
            start_local = chunk_start - (m["number"] - first) * F(m["actual_duration_qn"])
            boundary = (start_local // pulse + 1) * pulse
            if not in_tuplet and (local_end >= boundary or local_end == F(m["actual_duration_qn"])):
                end_tie = chunk[-1]["tie_next"]
                chunk[-1]["tie_next"] = False
                groups = {}
                for s in chunk:
                    if s["group"]:
                        s["group"] = groups.setdefault(s["group"], len(groups) + 1)
                t = tile(chunk)
                tiles[t["id"]] = t
                placements.append(dict(tile_id=t["id"], start=str(chunk_start)))
                if end_tie:
                    ties.append(str(chunk_start + F(t["duration"])))
                chunk, chunk_start = [], None
        if chunk:
            raise ValueError("tuplet_crosses_measure_requires_review")
    return span, placements, tiles, ties


def sounding(placements, ties, tiles, total, bar=None):
    """Validate geometry and tie endpoints; return attacks with exact durations."""
    if not isinstance(placements, list) or not 1 <= len(placements) <= 64 or not isinstance(ties, list) or len(ties) > 63:
        raise ValueError("invalid_answer")
    flat, occupied, seen = [], [], set()
    for p in placements:
        if not isinstance(p, dict) or set(p) != {"tile_id", "start"} or p["tile_id"] not in tiles:
            raise ValueError("invalid_piece")
        t, start = tiles[p["tile_id"]], fraction(p["start"])
        end = start + F(t["duration"])
        if start < 0 or end > total or any(start < b and a < end for a, b in occupied):
            raise ValueError("overlapping_or_outside_piece")
        if bar is not None and start // bar != (end - F(1, 1000000)) // bar:
            raise ValueError("piece_crosses_barline")
        occupied.append((start, end))
        cursor = start
        for n in t["symbols"]:
            flat.append(dict(onset=cursor, duration=F(n["duration"]), rest=n["rest"], tie_next=n["tie_next"], piece_end=False))
            cursor += F(n["duration"])
        flat[-1]["piece_end"] = True
    occupied.sort()
    if occupied[0][0] != 0 or occupied[-1][1] != total or any(a[1] != b[0] for a, b in zip(occupied, occupied[1:])):
        raise ValueError("incomplete_answer")
    for value in ties:
        time = fraction(value)
        if time in seen:
            raise ValueError("duplicate_tie")
        seen.add(time)
        found = [i for i, n in enumerate(flat) if n["piece_end"] and n["onset"] + n["duration"] == time]
        if len(found) != 1:
            raise ValueError("invalid_tie_boundary")
        flat[found[0]]["tie_next"] = True
    flat.sort(key=lambda n: n["onset"])
    attacks, continuing = [], False
    for i, n in enumerate(flat):
        if continuing:
            if n["rest"]:
                raise ValueError("tie_into_rest")
            attacks[-1]["duration"] = str(F(attacks[-1]["duration"]) + n["duration"])
        elif not n["rest"]:
            attacks.append(dict(onset=str(n["onset"]), duration=str(n["duration"])))
        if n["tie_next"] and (n["rest"] or i + 1 == len(flat) or flat[i + 1]["rest"]):
            raise ValueError("invalid_tie_endpoint")
        continuing = n["tie_next"]
    return attacks


def grade(round_, answer, tiles):
    actual = sounding(answer["placements"], answer["ties"], tiles, F(round_["total_duration"]), F(round_["measure_duration"]))
    expected = round_["rhythm"]
    # Diagnostic positions are never exposed on the first wrong submission.
    a = {F(n["onset"]): F(n["duration"]) for n in actual}
    b = {F(n["onset"]): F(n["duration"]) for n in expected}
    positions = sorted({t + min(a[t], b[t]) if t in a and t in b else t for t in set(a) | set(b) if a.get(t) != b.get(t)})
    return dict(correct=actual == expected, positions=[str(p) for p in positions], source="deterministic")


def rhythm_burden(attacks, pulse, bar, total, tuplet_share=0):
    """Provisional rhythmic burden: beat contradiction outweighs note density."""
    pulse, bar, total = F(pulse), F(bar), F(total)
    def strength(t):
        if t % bar == 0:
            return 4
        if t % pulse == 0:
            return 3 if bar == 4 and t % bar == 2 else 2
        if (t / pulse).denominator in (2, 3):
            return 1
        return 0
    displacement, grids, off = 0, [], 0
    for n in attacks:
        start, end = F(n["onset"]), F(n["onset"]) + F(n["duration"])
        off += start % pulse != 0
        candidates = [F(i) * pulse / 12 for i in range(int(total / pulse * 12) + 1) if start < F(i) * pulse / 12 < end]
        displacement += max([0] + [strength(t) - strength(start) for t in candidates])
    for i in range(int(total / pulse)):
        starts = [(F(n["onset"]) / pulse) - i for n in attacks if i * pulse <= F(n["onset"]) < (i + 1) * pulse]
        grids.append(math.lcm(*(s.denominator for s in starts)) if starts else 0)
    switches = sum(a != b for a, b in zip(grids, grids[1:])) / max(1, len(grids) - 1)
    # Sounding pulse patterns, including continuation through the pulse start.
    patterns = []
    for i in range(int(total / pulse)):
        a, b = i * pulse, (i + 1) * pulse
        patterns.append(tuple((str(max(F(n["onset"]), a) - a), str(min(F(n["onset"]) + F(n["duration"]), b) - max(F(n["onset"]), a)), F(n["onset"]) < a)
                              for n in attacks if F(n["onset"]) < b and F(n["onset"]) + F(n["duration"]) > a))
    novelty = len(set(patterns)) / max(1, len(patterns))
    components = dict(displacement=displacement / max(1, len(grids)), offbeat=off / max(1, len(attacks)),
                      grid_switches=switches, tuplet_share=tuplet_share, pattern_variety=novelty,
                      density=len(attacks) / max(1, len(grids)))
    raw = 4 * components["displacement"] + 0.25 * components["offbeat"] + switches + tuplet_share + 0.5 * novelty + 0.05 * components["density"]
    return dict(raw=round(raw, 6), components=components)


def build_catalog(root):
    root = Path(root)
    rounds, all_tiles, exceptions = [], {}, []
    for row in current_sources(root):
        m = row["metadata"]
        level = m.get("difficulty", "intermediate" if row["order"] <= 3 else "advanced")
        if level not in ("intermediate", "advanced") or m.get("collection") == "classical":
            continue
        path = root / row["main_path"]
        data = path.read_bytes()
        if digest_bytes(data) != m["score_assets"]["main"]["sha256"]:
            raise ValueError("source_asset_mismatch")
        raw = read_xml(path)
        record = analyze(path, question_id=m["id"], question_version=m["version"])
        try:
            symbols = source_symbols(record, raw)
        except ValueError as error:
            for first in (1, 3, 5, 7):
                exceptions.append(dict(question_id=m["id"], title=m["title"], first_measure=first, reason=str(error)))
            continue
        for first in (1, 3, 5, 7):
            try:
                span, placements, tiles, ties = pieces_for_span(record, symbols, first, first + 1)
                bar = record["measures"][first - 1]
                total = F(bar["actual_duration_qn"]) * 2
                origin = sum((F(a["actual_duration_qn"]) for a in record["measures"][:first - 1]), F(0))
                audio = [dict(onset=str(F(a["absolute_onset_qn"]) - origin), duration=a["sounding_duration_qn"], midi=a["midi"])
                         for a in record["attacks"] if a["id"] in span["event_ids"]]
                rhythm = sounding(placements, ties, tiles, total, F(bar["actual_duration_qn"]))
                if rhythm != [{k: a[k] for k in ("onset", "duration")} for a in audio]:
                    raise ValueError("sound_roundtrip_mismatch")
                if len(tiles) > 10:
                    raise ValueError("more_than_ten_required_choices")
                meter = m["time_signature"]
                policies = json.loads((root / "playback-settings.json").read_text(encoding="utf-8"))["meters"]
                policy = policies[f'{meter["numerator"]}/{meter["denominator"]}']
                bpm = policy["default_bpm"] * (1.5 if policy["beat_unit"] == "dotted_quarter" else 2 if policy["beat_unit"] == "half" else 1)
                round_ = dict(id=digest([VERSION, record["analysis_key"], first]), question_id=m["id"], question_version=m["version"],
                              analysis_key=record["analysis_key"], source_xml_sha256=record["source_xml_sha256"],
                              title=m["title"], level=level, first_measure=first, meter=meter, pulse=bar["pulse_qn"],
                              measure_duration=bar["actual_duration_qn"], total_duration=str(total), tempo_bpm=bpm,
                              display_bpm=policy["default_bpm"], beat_unit=policy["beat_unit"],
                              solution=placements, solution_ties=ties, rhythm=rhythm, audio=audio,
                              features=span["features"], difficulty=rhythm_burden(rhythm, bar["pulse_qn"], bar["actual_duration_qn"], total,
                                  sum(e["tuplet_ratio"] != [1, 1] for e in record["events"] if e["id"] in span["event_ids"] and not e["tie_stop"] and e["kind"] == "note") / max(1, len(audio))))
                all_tiles.update(tiles)
                round_["rhythm_key"] = digest([meter, bar["pulse_qn"], rhythm])
                rounds.append(round_)
            except (ValueError, FeatureError) as error:
                exceptions.append(dict(question_id=m["id"], title=m["title"], first_measure=first, reason=str(error)))
    # Freeze a same-meter reference cohort. A score is a relative rank, not a success probability.
    for r in rounds:
        cohort = [q["difficulty"]["raw"] for q in rounds if q["meter"] == r["meter"]]
        raw = r["difficulty"]["raw"]
        r["difficulty"].update(score=round(100 * (sum(x < raw for x in cohort) + 0.5 * sum(x == raw for x in cohort)) / len(cohort)),
                                version=DIFFICULTY_VERSION, cohort_size=len(cohort))
        required = list(dict.fromkeys(p["tile_id"] for p in r["solution"]))
        # Similar lengths first; deterministic order, shuffled only when a play starts.
        wanted = {all_tiles[k]["duration"] for k in required}
        candidates = sorted((t for t in all_tiles.values() if t["id"] not in required and F(t["duration"]) <= F(r["measure_duration"])),
                            key=lambda t: (t["duration"] not in wanted, abs(float(F(t["duration"]) - F(r["pulse"]))), digest([r["id"], t["id"]])))
        r["choices"] = required + [t["id"] for t in candidates[:12 - len(required)]]
        if len(r["choices"]) != 12:
            raise ValueError("not_enough_choices")
    return dict(version=VERSION, difficulty_version=DIFFICULTY_VERSION, tiles=sorted(all_tiles.values(), key=lambda t: t["id"]),
                rounds=rounds, exceptions=exceptions, source_count=len({r["question_id"] for r in rounds}))


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()
