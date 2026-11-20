"""Short, evidence-linked coaching. History never enters the numeric grading call."""
import copy
from collections import Counter

PROMPT_VERSION = "exam-coach-b3-history-facts-1"
ERROR_TYPES = {"pitch_error", "rhythm_error", "missing_note", "extra_note", "notation_error"}


def object_schema(properties):
    return {"type": "object", "additionalProperties": False, "properties": properties, "required": list(properties)}


COACH_SCHEMA = object_schema({
    "headline": {"type": "string"}, "detail": {"type": "string"},
    "kind": {"type": "string", "enum": ["observation", "comparison", "pattern", "positive", "no_issue", "withheld"]},
    "scope": {"type": "string", "enum": ["current", "history"]}, "history_used": {"type": "boolean"},
    "evidence": {"type": "array", "items": object_schema({"measure": {"type": "integer", "minimum": 1, "maximum": 8}, "reason": {"type": "string"}})},
    "history_evidence_ids": {"type": "array", "items": {"type": "string"}},
    "evidence_warning": {"type": "array", "items": {"type": "string"}},
})


def summarize_history(records):
    """Only counts of AI observations; no prior prose, diagnoses or imported experiments."""
    summary = []
    for record in records[:8]:
        annotations = record.get("annotations") or []
        uncertain = {a.get("measure") for a in annotations if a.get("type") == "recognition_uncertain"}
        counts = Counter(a["type"] for a in annotations if a.get("type") in ERROR_TYPES
                         and a.get("measure") is not None and None not in uncertain and a["measure"] not in uncertain)
        summary.append({"job_id": str(record["id"]), "score": record["score"],
                        "difficulty": record.get("difficulty"), "difficulty_version": record.get("difficulty_version"),
                        "error_counts": dict(counts)})
    return {"available": bool(summary), "source": "completed_exam_ai_observations", "records": summary,
            "exam_count": len(summary), "note": "AI의 오류 관찰이며 원인이나 능력에 대한 진단이 아님"}


def freeze_for_job(attempt, answer):
    from django.conf import settings
    from django.db.models import F
    from .models import GradingJob
    previous = attempt.jobs.filter(answer=answer).exclude(coaching={}).order_by("created_at").first()
    if previous:
        return {k: copy.deepcopy(v) for k, v in previous.coaching.items() if k in ("prompt_version", "prompt_text", "history")}
    cutoff = attempt.submitted_at or attempt.created_at
    jobs = GradingJob.objects.filter(attempt__user_id=attempt.user_id, attempt__mode="exam", status="completed",
        attempt__current_job_id=F("id"), attempt__submitted_at__lt=cutoff, score__isnull=False).exclude(attempt=attempt).select_related("attempt").order_by("-attempt__submitted_at", "-created_at")[:8]
    records = [{"id": str(j.id), "score": j.score, "annotations": j.annotations,
                "difficulty": (j.attempt.exam_rating_snapshot or {}).get("difficulty_score"),
                "difficulty_version": (j.attempt.exam_rating_snapshot or {}).get("difficulty_version")} for j in jobs]
    return {"prompt_version": PROMPT_VERSION,
            "prompt_text": (settings.BASE_DIR / "solfege" / "coaching-prompt-b3-v1.txt").read_text(encoding="utf-8"),
            "history": summarize_history(records)}


def validate_coach(value, result, history):
    if not isinstance(value, dict) or set(value) != set(COACH_SCHEMA["required"]):
        raise ValueError("invalid coaching shape")
    if any(not isinstance(value[k], str) or len(value[k]) > limit or "\n" in value[k]
           for k, limit in (("headline", 50), ("detail", 90))):
        raise ValueError("coaching must be short")
    if value["kind"] not in COACH_SCHEMA["properties"]["kind"]["enum"] or value["scope"] not in ("current", "history") or type(value["history_used"]) is not bool:
        raise ValueError("invalid coaching mode")
    for key in ("history_evidence_ids", "evidence_warning"):
        if not isinstance(value[key], list) or len(value[key]) > 8 or any(not isinstance(s, str) or len(s) > 300 for s in value[key]):
            raise ValueError("invalid coaching evidence")
    known = {r["job_id"] for r in history.get("records", [])}
    ids = set(value["history_evidence_ids"])
    if not ids <= known or (value["history_used"] and (not history.get("available") or not ids)):
        raise ValueError("unsupported history")
    if (value["scope"] == "history") != value["history_used"] or (ids and not value["history_used"]):
        raise ValueError("inconsistent history")
    if value["kind"] == "pattern" and len(ids) < 2:
        raise ValueError("a pattern needs distinct previous exams")
    if value["kind"] == "pattern":
        shared = {a["type"] for a in result["annotations"] if a["type"] in ERROR_TYPES}
        for record in history["records"]:
            if record["job_id"] in ids:
                shared &= {k for k, count in record["error_counts"].items() if count > 0}
        if not shared:
            raise ValueError("no repeated observed error type")
    evidence = value["evidence"]
    if not isinstance(evidence, list) or len(evidence) > 8 or any(not isinstance(e, dict) or set(e) != {"measure", "reason"}
        or type(e["measure"]) is not int or not 1 <= e["measure"] <= 8 or not isinstance(e["reason"], str) or len(e["reason"]) > 300 for e in evidence):
        raise ValueError("invalid current evidence")
    uncertain = {a.get("measure") for a in result["annotations"] if a["type"] == "recognition_uncertain"}
    if any(None in uncertain or e["measure"] in uncertain for e in evidence):
        raise ValueError("uncertain evidence")
    if value["kind"] == "no_issue" and (result["score"] != 100 or any(a["type"] in ERROR_TYPES | {"recognition_uncertain"} for a in result["annotations"])):
        raise ValueError("no-issue conflicts with grade")
    if value["kind"] == "withheld":
        if value["headline"] or value["detail"]:
            raise ValueError("withheld text")
    elif not value["headline"].strip() or (value["kind"] != "no_issue" and not evidence):
        raise ValueError("missing current evidence")
    return value


def fallback(result):
    errors = [a for a in result["annotations"] if a["type"] in ERROR_TYPES]
    uncertain = any(a["type"] == "recognition_uncertain" for a in result["annotations"])
    if result["score"] == 100 and not errors and not uncertain:
        headline = "이번에 따로 짚을 오류는 없어요."
    else:
        first = next((a for a in errors if a.get("measure")), None)
        headline = f'{first["measure"]}마디를 정답과 비교해보세요.' if first else "정답 악보와 내 악보를 비교해보세요."
    return {"headline": headline, "detail": "", "kind": "no_issue" if result["score"] == 100 and not errors and not uncertain else "observation",
            "scope": "current", "history_used": False, "evidence": [], "history_evidence_ids": [], "evidence_warning": []}


def generate_coach(job, result, reference, image, deadline):
    """A failed coaching call must never discard an already validated numeric grade."""
    import json
    import subprocess
    import sys
    import time
    from django.conf import settings
    metadata = copy.deepcopy(job.coaching)
    try:
        remaining = min(45, int(deadline - time.monotonic()))
        if remaining < 8:
            raise TimeoutError("coaching budget exhausted")
        history = metadata["history"]
        payload = {"model": job.model, "reasoning": {"effort": job.reasoning_effort}, "max_tokens": 2400,
            "provider": {"require_parameters": True},
            "response_format": {"type": "json_schema", "json_schema": {"name": "solfege_coach", "strict": True, "schema": COACH_SCHEMA}},
            "messages": [{"role": "system", "content": metadata["prompt_text"]},
                {"role": "user", "content": [{"type": "text", "text": json.dumps({"reference_musicxml": reference,
                    "current_grading": result, "history": history}, ensure_ascii=False)},
                    {"type": "image_url", "image_url": {"url": "data:image/png;base64," + image, "detail": "high"}}]}]}
        child = subprocess.run([sys.executable, "-m", "solfege.provider"], input=json.dumps({"key": settings.OPENROUTER_API_KEY,
            "timeout": remaining, "payload": payload}), text=True, encoding="utf-8", capture_output=True,
            timeout=remaining, cwd=settings.BASE_DIR, check=True)
        transport = json.loads(child.stdout)
        if "error_code" in transport:
            raise ValueError("coaching transport failure")
        response = transport["response"]
        metadata.update(usage=response.get("usage") or {}, provider_request_id=str(response.get("id") or ""), raw_response=response)
        choice = response["choices"][0]
        if choice.get("finish_reason") != "stop" or choice["message"].get("refusal"):
            raise ValueError("incomplete coaching")
        coach = validate_coach(json.loads(choice["message"]["content"]), result, history)
        metadata["status"] = "completed"
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, IndexError, TypeError):
        coach = fallback(result)
        metadata["status"] = "fallback"
    coach = {**coach, "prompt_version": metadata["prompt_version"]}
    metadata["result"] = coach
    return {**result["feedback"], "coach": coach}, metadata
