import base64
import json
import subprocess
import sys
import zipfile
from datetime import timedelta
from django.conf import settings
from django.db import transaction
from django.utils import timezone
from .models import GradingJob

from .assessment import ANNOTATION_TYPES, RESULT_SCHEMA, validate_result


def claim_job():
    now = timezone.now()
    # A terminated worker or HTTP child cannot leave the UI polling forever. No automatic paid replay.
    GradingJob.objects.filter(status="processing", lease_expires_at__lt=now).update(status="failed", failure={"code": "RECOGNITION_TIMEOUT", "message": "채점 작업이 중단되었습니다. 같은 답안으로 재시도할 수 있습니다.", "retryable": True}, updated_at=now)
    with transaction.atomic():
        job = GradingJob.objects.select_for_update(skip_locked=True).filter(status="queued").order_by("created_at").first()
        if job is None:
            return None
        job.status, job.stage, job.started_at = "processing", "recognizing", now
        job.lease_expires_at = now + timedelta(seconds=job.timeout_seconds + 30)
        job.save(update_fields=["status", "stage", "started_at", "lease_expires_at", "updated_at"])
        return job

def execute_job(job):
    updates = {"updated_at": timezone.now()}
    try:
        if not settings.OPENROUTER_API_KEY:
            updates.update(status="failed", failure={"code": "ENGINE_UNAVAILABLE", "message": "서버의 OpenRouter API 키가 설정되지 않았습니다.", "retryable": True})
        else:
            with job.answer.image.open("rb") as source:
                image = base64.b64encode(source.read()).decode("ascii")
            with zipfile.ZipFile(settings.CONTENT_ROOT / job.attempt.question_version.main_path) as archive:
                reference = archive.read("score.xml").decode("utf-8")
            payload = {"model": job.model, "reasoning": {"effort": job.reasoning_effort}, "max_tokens": job.max_output_tokens, "provider": {"require_parameters": True}, "response_format": {"type": "json_schema", "json_schema": {"name": "sori_assessment", "strict": True, "schema": RESULT_SCHEMA}}, "messages": [{"role": "system", "content": job.prompt_text}, {"role": "user", "content": [{"type": "text", "text": "정답 MusicXML (비교 기준):\n" + reference}, {"type": "image_url", "image_url": {"url": "data:image/png;base64," + image, "detail": "high"}}]}]}
            child = subprocess.run([sys.executable, "-m", "sori.provider"], input=json.dumps({"key": settings.OPENROUTER_API_KEY, "timeout": job.timeout_seconds, "payload": payload}), text=True, encoding="utf-8", capture_output=True, timeout=job.timeout_seconds, cwd=settings.BASE_DIR, check=True)
            transport = json.loads(child.stdout)
            if "error_code" in transport:
                updates.update(status="failed", failure={"code": transport["error_code"], "message": transport["error_message"], "retryable": transport["retryable"]})
            else:
                response = transport["response"]
                updates.update(raw_response=response, usage=response.get("usage") or {}, provider_request_id=str(response.get("id") or ""))
                choice = response["choices"][0]
                if choice.get("finish_reason") != "stop" or choice["message"].get("refusal"):
                    raise ValueError("incomplete or refused response")
                result = validate_result(json.loads(choice["message"]["content"]), job.attempt.question_snapshot["sheet_layout"])
                updates.update(status=result["status"], stage="done" if result["status"] == "completed" else "recognizing", score=result["score"], pitch_accuracy=result["pitch_accuracy"], rhythm_accuracy=result["rhythm_accuracy"], feedback=result["feedback"], annotations=result["annotations"], recognized_musicxml=result["recognized_musicxml"])
    except subprocess.TimeoutExpired:
        updates.update(status="failed", failure={"code": "RECOGNITION_TIMEOUT", "message": "AI 평가 시간이 초과되었습니다. 제출한 답안은 보관되어 있습니다.", "retryable": True})
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, IndexError, TypeError, zipfile.BadZipFile):
        updates.update(status="failed", failure={"code": "GRADING_INTERNAL_ERROR", "message": "AI 평가 결과를 검증하지 못했습니다. 같은 답안으로 재시도할 수 있습니다.", "retryable": True})
    updates["updated_at"] = timezone.now()
    # A late response from an expired attempt never overwrites a newer job or terminal state.
    return GradingJob.objects.filter(id=job.id, status="processing", attempt__current_job_id=job.id).update(**updates)
