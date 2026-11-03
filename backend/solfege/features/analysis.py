"""Feature v1 facts and evidence. Difficulty and learner diagnosis stay separate."""
import copy
import hashlib
import json
from collections import Counter
from fractions import Fraction as F

from .musicxml import FeatureError, LETTERS, decode, read_xml

SCHEMA_VERSION = "1.0.0"
EXTRACTOR_VERSION = "feature-v1.0.0"
CANDIDATES = ("offbeat_sustain_candidate", "cross_pulse_beam_candidate")
COUNT_FIELDS = {
    "large_up": "large_up_count", "large_down": "large_down_count",
    "tie_chain": "tie_chain_count", "explicit_accidental": "explicit_accidental_count",
    "cautionary_accidental": "cautionary_accidental_count", "editorial_accidental": "editorial_accidental_count",
    "key_relative_alteration": "key_relative_alteration_count",
    "short_sounding_attack": "short_sounding_attack_count",
    **{code: code + "_count" for code in CANDIDATES},
}


def canonical_json(value):
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"), allow_nan=False)


def analysis_key(record):
    identity = [record[k] for k in ("question_id", "question_version", "source_xml_sha256",
                                    "schema_version", "extractor_version", "config")]
    return hashlib.sha256(canonical_json(identity).encode("utf-8")).hexdigest()


def _config(config):
    supplied = copy.deepcopy(config) if config is not None else {}
    if not isinstance(supplied, dict) or set(supplied) - {"intervals_across_rests", "missing_key_policy", "beat_groupings"}:
        raise FeatureError("invalid_config")
    result = {"intervals_across_rests": True, "missing_key_policy": "unknown", **supplied}
    if type(result["intervals_across_rests"]) is not bool or result["missing_key_policy"] != "unknown":
        raise FeatureError("invalid_config")
    groupings = result.get("beat_groupings", {})
    if not isinstance(groupings, dict) or any(not isinstance(k, str) or not k.isdigit() or int(k) < 1 or str(int(k)) != k for k in groupings):
        raise FeatureError("invalid_config")
    if not groupings:
        result.pop("beat_groupings", None)
    return result


def _review(source_review):
    review = copy.deepcopy(source_review) if source_review is not None else dict(status="unreviewed", scope="not checked against source audio")
    if not isinstance(review, dict) or set(review) - {"status", "scope", "notes"} or review.get("status") not in ("unreviewed", "partially_reviewed", "reviewed") or not isinstance(review.get("scope"), str) or not review["scope"].strip():
        raise FeatureError("invalid_source_review")
    if "notes" in review and not isinstance(review["notes"], str):
        raise FeatureError("invalid_source_review")
    return review


def _add_feature(record, code, event_ids, *, kind="rule", scope=None, details=None):
    index = record["_index"]
    ids = sorted(set(event_ids), key=lambda i: index[i][0])
    measures = sorted({index[i][1]["measure"] for i in ids})
    record["features"].append(dict(code=code, kind=kind, scope=scope or ("local" if len(measures) == 1 else "connection"),
                                   event_ids=ids, measure_ids=measures, details=details or {}))


def _repeat_features(measures, events):
    first, result = {}, []
    for m in measures:
        signature = m["rhythm_pattern_canonical"]
        if signature in first:
            a = first[signature]
            ids = set(a["event_ids"] + m["event_ids"])
            result.append(dict(code="exact_rhythm_repeat", kind="rule", scope="context",
                               event_ids=[e["id"] for e in events if e["id"] in ids],
                               measure_ids=[a["number"], m["number"]],
                               details=dict(first_measure=a["number"], repeated_measure=m["number"], rhythm_pattern_id=m["rhythm_pattern_id"])))
        else:
            first[signature] = m
    return result


def _extract_features(record):
    events, attacks, measures = record["events"], record["attacks"], record["measures"]
    index = record["_index"]
    for a, b in zip(attacks, attacks[1:]):
        aa, bb = index[a["id"]][1], index[b["id"]][1]
        semis = b["midi"] - a["midi"]
        generic = abs((bb["octave"] * 7 + LETTERS.index(bb["step"])) - (aa["octave"] * 7 + LETTERS.index(aa["step"]))) + 1
        across_rest = F(a["absolute_onset_qn"]) + F(a["sounding_duration_qn"]) < F(b["absolute_onset_qn"])
        if across_rest and not record["config"]["intervals_across_rests"]:
            continue
        iv = dict(from_event_id=a["id"], to_event_id=b["id"], semitones=semis, generic=generic,
                  direction="up" if semis > 0 else "down" if semis < 0 else "same", across_rest=across_rest,
                  scope="local" if aa["measure"] == bb["measure"] else "connection")
        record["intervals"].append(iv)
        if generic >= 5 and semis:
            _add_feature(record, "large_up" if semis > 0 else "large_down", [a["id"], b["id"]], details=dict(semitones=semis, generic=generic, across_rest=across_rest))
    for e in events:
        ids = [e["id"]]
        if e["kind"] == "rest":
            _add_feature(record, "rest", ids)
        if e["dots"]:
            _add_feature(record, "dotted", ids, details=dict(dots=e["dots"]))
        if e["tuplet_ratio"][0] != e["tuplet_ratio"][1]:
            _add_feature(record, "tuplet", ids, details=dict(ratio=e["tuplet_ratio"]))
        acc = e["accidental"]
        if acc is not None:
            _add_feature(record, "explicit_accidental", ids, details=acc)
            for flag in ("cautionary", "editorial"):
                if acc[flag]:
                    _add_feature(record, flag + "_accidental", ids, details=acc)
    for a in attacks:
        e = index[a["id"]][1]
        ids = a["member_event_ids"]
        if len(ids) > 1:
            _add_feature(record, "tie_chain", ids, details=dict(attack_id=a["id"], sounding_duration_qn=a["sounding_duration_qn"]))
        if F(a["sounding_duration_qn"]) <= F(1, 4):
            _add_feature(record, "short_sounding_attack", ids)
        key = measures[e["measure"] - 1]["key_signature"]
        if key is not None:
            fifths = key["fifths"]
            changed = ("FCGDAEB" if fifths >= 0 else "BEADGCF")[:abs(fifths)]
            expected = (1 if fifths >= 0 else -1) if e["step"] in changed else 0
            if e["alter"] != expected:
                _add_feature(record, "key_relative_alteration", [e["id"]], details=dict(fifths=fifths, expected_alter=expected, actual_alter=e["alter"]))
    _candidates(record)
    record["features"].extend(_repeat_features(measures, events))


def _candidates(record):
    measures, index = record["measures"], record["_index"]
    by_measure = {m["number"]: [index[i][1] for i in m["event_ids"]] for m in measures}
    reasons = record["unavailable_reasons"]

    def unavailable(m, code, reason):
        path = f"measures[{m['number'] - 1}].features.{code}"
        values = reasons.setdefault(path, [])
        if reason not in values:
            values.append(reason)

    for m in measures:
        for code in CANDIDATES:
            if m["pulse_qn"] is None:
                reason = "needs_beat_grouping" if m["meter"] == "7/8" and m["beat_grouping"] is None else "unsupported_meter"
                unavailable(m, code, reason)
            if m["actual_duration_qn"] != m["expected_duration_qn"]:
                unavailable(m, code, "incomplete_measure")
    for a in record["attacks"]:
        e = index[a["id"]][1]
        m = measures[e["measure"] - 1]
        if m["pulse_qn"] is None or m["actual_duration_qn"] != m["expected_duration_qn"]:
            continue
        pulse, onset = F(m["pulse_qn"]), F(e["onset_qn"])
        if not onset % pulse:
            continue
        boundary = (onset // pulse + 1) * pulse
        end = onset + F(a["sounding_duration_qn"])
        if end <= boundary:
            continue
        target = m
        target_onset = boundary
        if boundary == F(m["actual_duration_qn"]):
            if m["number"] == len(measures):
                continue
            target = measures[m["number"]]
            target_onset = F(0)
            if target["meter"] != m["meter"] or target["actual_duration_qn"] != target["expected_duration_qn"]:
                unavailable(m, CANDIDATES[0], "meter_boundary_not_supported" if target["meter"] != m["meter"] else "incomplete_measure")
                continue
        _add_feature(record, CANDIDATES[0], a["member_event_ids"], kind="candidate",
                     details=dict(crossed_measure=target["number"], crossed_onset_qn=str(target_onset)))
    for m in measures:
        if m["pulse_qn"] is None or m["actual_duration_qn"] != m["expected_duration_qn"]:
            continue
        group, pulse = [], F(m["pulse_qn"])
        for e in by_measure[m["number"]]:
            level = [b["value"] for b in e["beams"] if b["number"] == "1"]
            value = level[0] if len(level) == 1 else None
            if len(level) > 1:
                unavailable(m, CANDIDATES[1], "invalid_beam_group")
            if value == "begin":
                if group:
                    unavailable(m, CANDIDATES[1], "invalid_beam_group")
                group = [e]
            elif value in ("continue", "end"):
                if not group:
                    unavailable(m, CANDIDATES[1], "invalid_beam_group")
                    continue
                group.append(e)
                if value == "end":
                    if len({F(x["onset_qn"]) // pulse for x in group}) > 1:
                        _add_feature(record, CANDIDATES[1], [x["id"] for x in group], kind="candidate")
                    group = []
            else:
                if group:
                    unavailable(m, CANDIDATES[1], "invalid_beam_group")
                    group = []
                if value not in (None, "forward hook", "backward hook"):
                    unavailable(m, CANDIDATES[1], "invalid_beam_group")
        if group:
            unavailable(m, CANDIDATES[1], "invalid_beam_group")


def _summary(record, first, last):
    measures = record["measures"][first - 1:last]
    ee = [e for e in record["events"] if first <= e["measure"] <= last]
    ids = {e["id"] for e in ee}
    aa = [a for a in record["attacks"] if a["id"] in ids]
    ivs = [i for i in record["intervals"] if i["from_event_id"] in ids and i["to_event_id"] in ids]
    features = [copy.deepcopy(f) for f in record["features"] if f["code"] != "exact_rhythm_repeat"
                and set(f["event_ids"]) <= ids and all(first <= m <= last for m in f["measure_ids"])]
    features.extend(_repeat_features(measures, ee))
    counts = Counter(f["code"] for f in features)
    notes = [e for e in ee if e["kind"] == "note"]
    metrics = dict(written_note_count=len(notes), rest_event_count=len(ee) - len(notes), attack_count=len(aa),
                   interval_count=len(ivs), mean_abs_semitones=sum(abs(i["semitones"]) for i in ivs) / len(ivs) if ivs else None,
                   pitch_range_semitones=max(e["midi"] for e in notes) - min(e["midi"] for e in notes) if notes else None,
                   dotted_event_count=sum(e["dots"] > 0 for e in ee),
                   tuplet_event_count=sum(e["tuplet_ratio"][0] != e["tuplet_ratio"][1] for e in ee),
                   tuplet_attack_share=sum(record["events_by_id"][a["id"]]["tuplet_ratio"][0] != record["events_by_id"][a["id"]]["tuplet_ratio"][1] for a in aa) / len(aa) if aa else None,
                   exact_rhythm_repeat_fraction=(len(measures) - len({m["rhythm_pattern_canonical"] for m in measures})) / len(measures))
    metrics.update({field: counts[code] for code, field in COUNT_FIELDS.items()})
    reasons = {}
    for field, condition, reason in (("mean_abs_semitones", not ivs, "no_intervals"),
                                     ("pitch_range_semitones", not notes, "no_notes"),
                                     ("tuplet_attack_share", not aa, "no_attacks")):
        if condition:
            reasons[f"metrics.{field}"] = [reason]
    if any(m["key_signature"] is None for m in measures):
        metrics["key_relative_alteration_count"] = None
        reasons["metrics.key_relative_alteration_count"] = ["missing_key_signature"]
    pulse_reasons = sorted({"needs_beat_grouping" if m["meter"] == "7/8" and m["beat_grouping"] is None else "unsupported_meter"
                            for m in measures if m["pulse_qn"] is None})
    if pulse_reasons:
        metrics.update(duration_pulses=None, attacks_per_pulse=None)
        for field in ("duration_pulses", "attacks_per_pulse"):
            reasons[f"metrics.{field}"] = pulse_reasons
    else:
        duration = sum((F(m["actual_duration_qn"]) / F(m["pulse_qn"]) for m in measures), F(0))
        metrics.update(duration_pulses=str(duration), attacks_per_pulse=float(len(aa) / duration) if duration else None)
        if not duration:
            reasons["metrics.attacks_per_pulse"] = ["no_duration"]
    for code in CANDIDATES:
        missing = sorted({reason for m in measures for reason in record["unavailable_reasons"].get(f"measures[{m['number'] - 1}].features.{code}", [])})
        if missing:
            field = COUNT_FIELDS[code]
            metrics[field] = None
            reasons[f"metrics.{field}"] = missing
    external = [dict(attack_id=a["id"], required_event_ids=a["member_event_ids"])
                for a in record["attacks"] if ids.intersection(a["member_event_ids"]) and not set(a["member_event_ids"]) <= ids]
    return dict(first_measure=first, last_measure=last, event_ids=[e["id"] for e in ee],
                features=features, metrics=metrics, unavailable_reasons=reasons,
                standalone_status="requires_tie_adaptation" if external else "ready", external_ties=external)


def select_span(record, first, last):
    """A view referencing the original analysis, with fresh span-only evidence."""
    if record.get("schema_version") != SCHEMA_VERSION or type(first) is not int or type(last) is not int or not 1 <= first <= last <= len(record["measures"]):
        raise FeatureError("invalid_span")
    # Indexes are local to this operation. Never add them to the caller's record.
    working = dict(record, events_by_id={e["id"]: e for e in record["events"]})
    result = _summary(working, first, last)
    return dict(schema_version=SCHEMA_VERSION, source_analysis_key=record["analysis_key"], **result)


def analyze_bytes(raw, *, question_id, question_version=1, config=None, source_review=None):
    if not isinstance(raw, bytes) or not isinstance(question_id, str) or not question_id or type(question_version) is not int or question_version < 1:
        raise FeatureError("invalid_analysis_identity")
    config = _config(config)
    measures, events, attacks, diagnostics = decode(raw, question_id, config.get("beat_groupings", {}))
    record = dict(schema_version=SCHEMA_VERSION, extractor_version=EXTRACTOR_VERSION,
                  question_id=question_id, question_version=question_version,
                  source_xml_sha256=hashlib.sha256(raw).hexdigest(), config=config, source_review=_review(source_review),
                  written_order=True, measures=measures, events=events, attacks=attacks, intervals=[], features=[],
                  metrics={}, unavailable_reasons={}, experimental={}, diagnostics=diagnostics)
    record["analysis_key"] = analysis_key(record)
    record["_index"] = {e["id"]: (i, e) for i, e in enumerate(events)}
    record["events_by_id"] = {e["id"]: e for e in events}
    for m in measures:
        signature = [m["meter"], m["beat_grouping"], m["actual_duration_qn"],
                     [["R" if e["kind"] == "rest" else "T" if e["tie_stop"] else "N", e["onset_qn"], e["duration_qn"]]
                      for e in (record["events_by_id"][i] for i in m["event_ids"])]]
        canonical = canonical_json(signature)
        m.update(rhythm_pattern_canonical=canonical, rhythm_pattern_id=hashlib.sha256(canonical.encode("utf-8")).hexdigest())
    _extract_features(record)
    repeats = {f["details"]["repeated_measure"]: f["details"]["first_measure"] for f in record["features"] if f["code"] == "exact_rhythm_repeat"}
    for m in measures:
        span = _summary(record, m["number"], m["number"])
        m.update(metrics=span["metrics"], repeat_of=repeats.get(m["number"]), standalone_status=span["standalone_status"])
        record["unavailable_reasons"].update({f"measures[{m['number'] - 1}].{k}": v for k, v in span["unavailable_reasons"].items()})
    full = _summary(record, 1, len(measures))
    record["metrics"] = full["metrics"]
    record["unavailable_reasons"].update(full["unavailable_reasons"])
    not_applicable = {"no_intervals", "no_notes", "no_attacks"}
    partial = any(reason not in not_applicable for values in record["unavailable_reasons"].values() for reason in values)
    partial = partial or any(d["code"] in ("missing_note_type", "incomplete_measure") for d in diagnostics)
    record["analysis_status"] = "partial" if partial else "complete"
    del record["_index"], record["events_by_id"]
    return record


def analyze(path, **options):
    return analyze_bytes(read_xml(path), **options)
