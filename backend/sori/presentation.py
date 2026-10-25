import copy
from django.utils import timezone
from .engraving import reference_asset

def timestamp(value):
    return value.isoformat().replace("+00:00", "Z") if value else None

def absolute(request, path):
    return request.build_absolute_uri(path)

def question_json(request, metadata):
    result = copy.deepcopy(metadata)
    question_id, version = result["id"], result["version"]
    result["sheet_layout"]["template_png_url"] = absolute(request, f'/assets/sheets/{result["sheet_layout"]["id"]}.png')
    for kind, asset in result["score_assets"].items():
        asset["url"] = absolute(request, f"/api/v1/questions/{question_id}/versions/{version}/scores/{kind}/")
    preview = reference_asset(metadata)
    if preview:
        preview.pop("resource")
        preview["url"] = absolute(request, f"/api/v1/questions/{question_id}/versions/{version}/display/")
        result["correct_score"] = preview
    return result

def answer_json(request, answer):
    return {"id": str(answer.id), "attempt_id": str(answer.attempt_id), "client_answer_id": str(answer.client_answer_id), "revision": answer.revision, "answer_format_version": answer.answer_format_version, "sheet_layout_id": answer.sheet_layout_id, "image_width": 2660, "image_height": 1692, "content_type": "image/png", "size_bytes": answer.size_bytes, "sha256": answer.sha256, "created_at": timestamp(answer.created_at), "image_url": absolute(request, f"/api/v1/attempts/{answer.attempt_id}/answers/{answer.id}/image/")}

def attempt_json(request, attempt):
    latest = attempt.answers.order_by("-revision").first()
    return {"id": str(attempt.id), "status": attempt.status, "grading_mode": attempt.grading_mode, "created_at": timestamp(attempt.created_at), "started_at": timestamp(attempt.started_at), "recommended_end_at": timestamp(attempt.recommended_end_at), "submitted_at": timestamp(attempt.submitted_at), "submitted_answer_id": str(attempt.submitted_answer_id) if attempt.submitted_answer_id else None, "latest_answer": answer_json(request, latest) if latest else None, "question": question_json(request, attempt.question_snapshot), "playback_plan": attempt.playback_plan, "server_time": timestamp(timezone.now())}

def grading_json(job):
    return {"attempt_id": str(job.attempt_id), "answer_id": str(job.answer_id), "job_id": str(job.id), "grading_mode": job.attempt.grading_mode, "grading_version": job.grading_version, "status": job.status, "stage": job.stage, "score": job.score, "pitch_accuracy": job.pitch_accuracy, "rhythm_accuracy": job.rhythm_accuracy, "feedback": job.feedback, "annotations": job.annotations, "failure": job.failure, "poll_after_ms": 2000 if job.status in ("queued", "processing") else 0, "created_at": timestamp(job.created_at), "updated_at": timestamp(job.updated_at), "server_time": timestamp(timezone.now())}
