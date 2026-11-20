"""Optional per-grading beta feedback. Never used as an exam score."""
import hashlib
import json
from django.conf import settings
from .models import AIFeedbackRating


def feedback_snapshot(job):
    return {"job_id": str(job.id), "grading_version": job.grading_version,
            "prompt_version": job.prompt_version, "model": job.model,
            "coaching_prompt_version": job.coaching.get("prompt_version"),
            "coaching_status": job.coaching.get("status"),
            "coaching_request_id": job.coaching.get("provider_request_id"),
            "score": job.score, "feedback": job.feedback, "annotations": job.annotations}


def feedback_id(job):
    data = json.dumps(feedback_snapshot(job), sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(data.encode("utf-8")).hexdigest()


def state(job):
    from .presentation import timestamp
    enabled = settings.AI_FEEDBACK_RATINGS_ENABLED and job.status == "completed" and job.attempt.mode == "exam"
    saved = AIFeedbackRating.objects.filter(job=job).first()
    return {"enabled": enabled, "feedback_id": feedback_id(job) if job.status == "completed" else None,
            "rating": ({"stars": saved.stars, "reason": saved.reason,
                        "updated_at": timestamp(saved.updated_at)} if saved else None)}
