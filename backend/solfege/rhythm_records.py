"""Bounded client telemetry, independently regraded before database storage."""
from datetime import datetime
import uuid
from .rhythm import grade


def validate_record(payload, catalog, catalog_sha256):
    required = {"client_play_id", "catalog_sha256", "round_id", "game_version", "choice_order", "started_at", "finished_at",
                "outcome", "active_ms", "submissions", "listens", "interruptions", "prior_exposures", "prior_pattern_exposures"}
    if not isinstance(payload, dict) or not required <= set(payload) or set(payload) - required - {"skipped"}:
        raise ValueError("invalid_record_fields")
    skipped = payload.get("skipped", False)
    if type(skipped) is not bool:
        raise ValueError("invalid_skip")
    def ident(value):
        if not isinstance(value, str):
            raise ValueError("invalid_event_id")
        return uuid.UUID(value)
    ident(payload["client_play_id"])
    if payload["game_version"] != catalog["version"] or payload["catalog_sha256"] != catalog_sha256:
        raise ValueError("catalog_version_mismatch")
    r = next((r for r in catalog["rounds"] if r["id"] == payload["round_id"]), None)
    if r is None:
        raise ValueError("unknown_round")
    order = payload["choice_order"]
    if not isinstance(order, list) or len(order) != 12 or any(not isinstance(k, str) for k in order) or sorted(order) != sorted(r["choices"]):
        raise ValueError("invalid_choice_order")
    for key, cap in (("active_ms", 86_400_000), ("interruptions", 10000), ("prior_exposures", 1_000_000), ("prior_pattern_exposures", 1_000_000)):
        if type(payload[key]) is not int or not 0 <= payload[key] <= cap:
            raise ValueError("invalid_telemetry")
    times = []
    for key in ("started_at", "finished_at"):
        if not isinstance(payload[key], str) or len(payload[key]) > 40:
            raise ValueError("invalid_date")
        value = datetime.fromisoformat(payload[key].replace("Z", "+00:00"))
        if value.tzinfo is None:
            raise ValueError("date_requires_timezone")
        times.append(value)
    # A device clock adjustment does not invalidate monotonic active time.
    submissions, listens = payload["submissions"], payload["listens"]
    if not isinstance(submissions, list) or len(submissions) > 3 or not isinstance(listens, list) or len(listens) > 200:
        raise ValueError("too_many_events")
    ids, prior_ms, results, done = set(), 0, [], False
    tiles = {t["id"]: t for t in catalog["tiles"] if t["id"] in r["choices"]}
    for sub in submissions:
        if not isinstance(sub, dict) or set(sub) != {"id", "active_ms", "placements", "ties"} or done:
            raise ValueError("invalid_submission")
        event_id = ident(sub["id"])
        if event_id in ids or type(sub["active_ms"]) is not int or not prior_ms <= sub["active_ms"] <= payload["active_ms"]:
            raise ValueError("invalid_submission_order")
        ids.add(event_id)
        result = grade(r, sub, tiles)
        result.update(submission_id=str(event_id), hint_level_before=min(2, len(results)))
        results.append(result)
        prior_ms, done = sub["active_ms"], result["correct"]
    for listen in listens:
        if not isinstance(listen, dict) or set(listen) != {"id", "reason", "started_ms", "ended_ms", "completed"}:
            raise ValueError("invalid_listen")
        event_id = ident(listen["id"])
        if event_id in ids or listen["reason"] not in ("initial", "replay", "reference") or type(listen["completed"]) is not bool:
            raise ValueError("invalid_listen")
        ids.add(event_id)
        if type(listen["started_ms"]) is not int or type(listen["ended_ms"]) is not int or not 0 <= listen["started_ms"] <= listen["ended_ms"] <= payload["active_ms"]:
            raise ValueError("invalid_listen_time")
    if submissions and not any(l["completed"] and l["reason"] != "reference" and l["ended_ms"] <= submissions[0]["active_ms"] for l in listens):
        raise ValueError("submit_before_complete_listen")
    if skipped and (done or len(results) == 3):
        raise ValueError("skip_after_finished")
    expected = "correct" if done else "revealed" if len(results) == 3 else "skipped" if skipped else "abandoned"
    if payload["outcome"] != expected:
        raise ValueError("outcome_mismatch")
    # Hints and correction attempts never become independent unaided opportunities.
    return r, dict(source="deterministic", results=results, outcome=expected,
                   first_correct=results[0]["correct"] if results else None,
                   replay_started=sum(l["reason"] == "replay" for l in listens),
                   replay_completed=sum(l["reason"] == "replay" and l["completed"] for l in listens),
                   telemetry_source="client_reported", calibration_eligible=bool(results), skipped=skipped,
                   task={key: r[key] for key in ("question_id", "question_version", "analysis_key", "rhythm_key", "first_measure", "meter", "pulse", "tempo_bpm", "difficulty")})
