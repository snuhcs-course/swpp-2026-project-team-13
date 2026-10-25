import copy
import hashlib
import io
import uuid
from datetime import timedelta
from pathlib import Path
from django.conf import settings
from django.core.files.base import ContentFile
from django.core.files.storage import default_storage
from django.db import transaction
from django.db.models import Max
from django.http import FileResponse
from django.shortcuts import get_object_or_404
from django.utils import timezone
from PIL import Image, UnidentifiedImageError
from rest_framework.decorators import api_view, parser_classes, permission_classes, renderer_classes
from rest_framework.parsers import JSONParser, MultiPartParser
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.renderers import JSONRenderer
from .renderers import MXLRenderer, PNGRenderer
from .engraving import reference_asset
from .playback import make_playback_plan, timed_question
from .errors import ContractError
from .idempotency import run_idempotent, uuid_value
from .models import Answer, Attempt, GradingJob, Question, QuestionVersion, UserProfile
from .presentation import absolute, answer_json, attempt_json, grading_json, question_json

GOALS = {"arts_school_entrance", "arts_school_student", "college_entrance", "teacher_exam", "other"}

def fields(data, required, optional=()):
    if not isinstance(data, dict) or set(data) - set(required) - set(optional) or not set(required) <= set(data):
        raise ContractError("VALIDATION_ERROR", "필수 필드와 지원하는 필드를 확인해 주세요.")

def owned(request, attempt_id, lock=False):
    query = Attempt.objects.select_for_update() if lock else Attempt.objects.all()
    return get_object_or_404(query, id=attempt_id, user=request.user)

def result_location(request, attempt):
    return absolute(request, f"/api/v1/attempts/{attempt.id}/result/")

def new_job(attempt, answer):
    job = GradingJob.objects.create(attempt=attempt, answer=answer, grading_version=attempt.grading_version, model=settings.OPENROUTER_MODEL, reasoning_effort=settings.OPENROUTER_REASONING_EFFORT, prompt_version=settings.AI_PROMPT_VERSION, timeout_seconds=settings.AI_TIMEOUT_SECONDS, max_output_tokens=settings.AI_MAX_OUTPUT_TOKENS, prompt_text=(settings.BASE_DIR / "sori" / "grading-prompt-v2.txt").read_text(encoding="utf-8") + "\n" + (settings.BASE_DIR / "sori" / "notation-rules-v1.txt").read_text(encoding="utf-8"))
    attempt.current_job = job
    return job

@api_view(["GET", "PATCH"])
@parser_classes([JSONParser])
def me(request):
    profile, _ = UserProfile.objects.get_or_create(user=request.user)
    if request.method == "PATCH":
        fields(request.data, {"learning_goal"})
        if not isinstance(request.data["learning_goal"], str) or request.data["learning_goal"] not in GOALS:
            raise ContractError("VALIDATION_ERROR", "학습 목표를 확인해 주세요.")
        profile.learning_goal = request.data["learning_goal"]
        profile.save(update_fields=["learning_goal"])
    return Response({"id": str(profile.id), "display_name": profile.display_name, "learning_goal": profile.learning_goal})

@api_view(["GET"])
def questions(request):
    try:
        page = int(request.query_params.get("page", "1"))
        size = int(request.query_params.get("page_size", "20"))
        if str(page) != request.query_params.get("page", "1") or page < 1 or not 1 <= size <= 50:
            raise ValueError
    except ValueError:
        raise ContractError("INVALID_PAGE", "페이지 범위를 확인해 주세요.") from None
    items = Question.objects.filter(published=True)
    count = items.count()
    if page > max(1, (count + size - 1) // size):
        raise ContractError("INVALID_PAGE", "없는 페이지입니다.")
    # Select exactly the advertised current version, even when old versions remain for existing attempts.
    result = []
    for question in items[(page - 1) * size:page * size]:
        version = QuestionVersion.objects.get(question=question, version=question.current_version)
        metadata = timed_question(version.metadata)
        result.append({k: metadata[k] for k in ("id", "version", "title", "source", "key_signature", "time_signature", "measure_count", "recommended_duration_seconds", "tempo")})
    def url(p):
        return absolute(request, f"/api/v1/questions/?page={p}&page_size={size}")
    return Response({"count": count, "next": url(page + 1) if page * size < count else None, "previous": url(page - 1) if page > 1 else None, "results": result})

@api_view(["GET"])
def question_detail(request, question_id):
    question = get_object_or_404(Question, id=question_id, published=True)
    version = get_object_or_404(QuestionVersion, question=question, version=question.current_version)
    return Response(question_json(request, timed_question(version.metadata)))

@api_view(["POST"])
@parser_classes([JSONParser])
def create_attempt(request):
    fields(request.data, {"question_id", "question_version"})
    question_id = uuid_value(request.data["question_id"], "question_id")
    version_number = request.data["question_version"]
    if type(version_number) is not int or version_number < 1:
        raise ContractError("VALIDATION_ERROR", "question_version은 양의 정수여야 합니다.")
    def operation():
        question = get_object_or_404(Question.objects.select_for_update(), id=question_id, published=True)
        if question.current_version != version_number:
            raise ContractError("QUESTION_VERSION_MISMATCH", "문제 버전이 변경되었습니다.", 409)
        version = get_object_or_404(QuestionVersion, question=question, version=version_number)
        snapshot = timed_question(version.metadata)
        plan = make_playback_plan(snapshot)
        attempt = Attempt.objects.create(user=request.user, question_version=version, question_snapshot=snapshot, playback_plan=plan)
        return attempt_json(request, attempt), 201, absolute(request, f"/api/v1/attempts/{attempt.id}/")
    return run_idempotent(request, dict(request.data), operation)

@api_view(["GET"])
def attempt_detail(request, attempt_id):
    return Response(attempt_json(request, owned(request, attempt_id)))

@api_view(["POST"])
@parser_classes([JSONParser])
def start_attempt(request, attempt_id):
    if request.body:
        raise ContractError("VALIDATION_ERROR", "시작 요청은 본문을 보내지 않습니다.")
    with transaction.atomic():
        attempt = owned(request, attempt_id, lock=True)
        if attempt.status == "submitted":
            raise ContractError("ATTEMPT_ALREADY_SUBMITTED", "이미 제출한 응시입니다.", 409)
        if attempt.status == "ready":
            attempt.started_at = timezone.now()
            attempt.recommended_end_at = attempt.started_at + timedelta(seconds=attempt.question_snapshot["recommended_duration_seconds"])
            attempt.status = "in_progress"
            attempt.save(update_fields=["status", "started_at", "recommended_end_at"])
        return Response(attempt_json(request, attempt))

@api_view(["POST"])
@parser_classes([MultiPartParser])
def upload_answer(request, attempt_id):
    owned(request, attempt_id)
    fields(request.data, {"image", "client_answer_id", "answer_format_version", "sheet_layout_id"})
    if any(len(values) != 1 for _, values in request.data.lists()):
        raise ContractError("VALIDATION_ERROR", "중복 multipart 필드입니다.")
    image = request.FILES.get("image")
    if image is None or image.size > 10 * 1024 * 1024:
        raise ContractError("IMAGE_TOO_LARGE", "PNG는 10 MiB 이하여야 합니다.", 413)
    if image.content_type != "image/png" or request.data["answer_format_version"] != "1":
        raise ContractError("INVALID_IMAGE_FORMAT", "PNG와 answer_format_version=1이 필요합니다.", 422)
    client_id = uuid_value(request.data["client_answer_id"], "client_answer_id")
    layout_id = request.data["sheet_layout_id"]
    image_bytes = image.read()
    digest = hashlib.sha256(image_bytes).hexdigest()
    if len(image_bytes) < 33 or image_bytes[:8] != b"\x89PNG\r\n\x1a\n" or image_bytes[24] != 8:
        raise ContractError("INVALID_IMAGE_FORMAT", "8비트 PNG 파일이 필요합니다.", 422)
    try:
        with Image.open(io.BytesIO(image_bytes)) as decoded:
            if decoded.format != "PNG" or decoded.size != (2660, 1692):
                raise ContractError("IMAGE_DIMENSIONS_MISMATCH", "답안은 2660 × 1692 PNG여야 합니다.", 422)
            decoded.load()
            if decoded.mode not in ("RGB", "RGBA") or getattr(decoded, "n_frames", 1) != 1 or (decoded.mode == "RGBA" and decoded.getchannel("A").getextrema() != (255, 255)):
                raise ContractError("INVALID_IMAGE_FORMAT", "불투명한 8비트 RGB/RGBA PNG가 필요합니다.", 422)
    except (UnidentifiedImageError, OSError, ValueError):
        raise ContractError("INVALID_IMAGE_FORMAT", "PNG 파일을 읽지 못했습니다.", 422) from None
    saved_name = None
    def operation():
        nonlocal saved_name
        attempt = owned(request, attempt_id, lock=True)
        if layout_id != attempt.question_snapshot["sheet_layout"]["id"]:
            raise ContractError("SHEET_LAYOUT_MISMATCH", "응시의 오선 템플릿과 다릅니다.", 422)
        old = attempt.answers.filter(client_answer_id=client_id).first()
        if old:
            if old.sha256 != digest or old.sheet_layout_id != layout_id:
                raise ContractError("ANSWER_ID_REUSED", "이 답안 ID는 다른 이미지에 사용되었습니다.", 409)
            return answer_json(request, old), 201, absolute(request, f"/api/v1/attempts/{attempt.id}/answers/{old.id}/image/")
        if attempt.status != "in_progress":
            raise ContractError("ATTEMPT_ALREADY_SUBMITTED" if attempt.status == "submitted" else "ATTEMPT_NOT_STARTED", "시작한 응시에만 업로드할 수 있습니다.", 409)
        answer_id = uuid.uuid4()
        saved_name = default_storage.save(f"answers/{request.user.pk}/{attempt.id}/{answer_id}.png", ContentFile(image_bytes))
        revision = (attempt.answers.aggregate(value=Max("revision"))["value"] or 0) + 1
        answer = Answer.objects.create(id=answer_id, attempt=attempt, client_answer_id=client_id, revision=revision, image=saved_name, sheet_layout_id=layout_id, sha256=digest, size_bytes=len(image_bytes))
        return answer_json(request, answer), 201, absolute(request, f"/api/v1/attempts/{attempt.id}/answers/{answer.id}/image/")
    try:
        return run_idempotent(request, {"client_answer_id": str(client_id), "answer_format_version": 1, "sheet_layout_id": layout_id, "sha256": digest}, operation)
    except Exception:
        if saved_name and not Answer.objects.filter(image=saved_name).exists():
            default_storage.delete(saved_name)
        raise

@api_view(["GET"])
@renderer_classes([JSONRenderer, PNGRenderer])
def answer_image(request, attempt_id, answer_id):
    attempt = owned(request, attempt_id)
    answer = get_object_or_404(Answer, id=answer_id, attempt=attempt)
    return FileResponse(answer.image.open("rb"), content_type="image/png")

@api_view(["POST"])
@parser_classes([JSONParser])
def submit_attempt(request, attempt_id):
    owned(request, attempt_id)
    fields(request.data, {"answer_id"})
    answer_id = uuid_value(request.data["answer_id"], "answer_id")
    def operation():
        attempt = owned(request, attempt_id, lock=True)
        answer = get_object_or_404(Answer, id=answer_id, attempt=attempt)
        if attempt.status == "submitted":
            if attempt.submitted_answer_id != answer.id:
                raise ContractError("ATTEMPT_ALREADY_SUBMITTED", "다른 답안으로 이미 제출했습니다.", 409)
            return grading_json(attempt.current_job), 202, result_location(request, attempt)
        if attempt.status != "in_progress":
            raise ContractError("ATTEMPT_NOT_STARTED", "아직 시작하지 않은 응시입니다.", 409)
        attempt.status, attempt.submitted_at, attempt.submitted_answer = "submitted", timezone.now(), answer
        job = new_job(attempt, answer)
        attempt.save(update_fields=["status", "submitted_at", "submitted_answer", "current_job"])
        return grading_json(job), 202, result_location(request, attempt)
    return run_idempotent(request, {"answer_id": str(answer_id)}, operation)

@api_view(["GET"])
def result(request, attempt_id):
    attempt = owned(request, attempt_id)
    if not attempt.current_job_id:
        raise ContractError("NOT_SUBMITTED", "아직 제출하지 않았습니다.", 409)
    return Response(grading_json(attempt.current_job))

@api_view(["POST"])
@parser_classes([JSONParser])
def retry_grading(request, attempt_id):
    owned(request, attempt_id)
    if request.body:
        raise ContractError("VALIDATION_ERROR", "재시도 요청은 본문을 보내지 않습니다.")
    def operation():
        attempt = owned(request, attempt_id, lock=True)
        previous = attempt.current_job
        if previous is None:
            raise ContractError("NOT_SUBMITTED", "아직 제출하지 않았습니다.", 409)
        if previous.status in ("queued", "processing"):
            raise ContractError("GRADING_IN_PROGRESS", "채점이 진행 중입니다.", 409)
        if previous.status != "failed" or not (previous.failure or {}).get("retryable"):
            raise ContractError("GRADING_NOT_RETRYABLE", "재시도할 수 없는 결과입니다.", 409)
        if attempt.jobs.count() >= settings.AI_MAX_JOBS_PER_ATTEMPT:
            raise ContractError("GRADING_NOT_RETRYABLE", "이 답안의 채점 재시도 한도에 도달했습니다.", 409)
        job = new_job(attempt, attempt.submitted_answer)
        attempt.save(update_fields=["current_job"])
        return grading_json(job), 202, result_location(request, attempt)
    return run_idempotent(request, {}, operation)

@api_view(["GET"])
@renderer_classes([JSONRenderer, MXLRenderer])
def score_asset(request, question_id, version, kind):
    if kind not in ("main", "scale"):
        raise ContractError("RESOURCE_NOT_FOUND", "악보를 찾을 수 없습니다.", 404)
    item = get_object_or_404(QuestionVersion, question_id=question_id, version=version)
    visible = item.question.published and item.question.current_version == version
    if not visible and not Attempt.objects.filter(user=request.user, question_version=item).exists():
        raise ContractError("RESOURCE_NOT_FOUND", "악보를 찾을 수 없습니다.", 404)
    path = settings.CONTENT_ROOT / getattr(item, f"{kind}_path")
    return FileResponse(path.open("rb"), content_type="application/vnd.recordare.musicxml")

@api_view(["GET"])
@permission_classes([AllowAny])
@renderer_classes([JSONRenderer, PNGRenderer])
def sheet_asset(request, layout_id):
    # Names come from a fixed manifest, never from a filesystem path supplied by the client.
    import json
    manifest = json.loads((settings.CONTENT_ROOT / "catalog.json").read_text(encoding="utf-8"))
    allowed = {item["metadata"]["sheet_layout"]["id"] for item in manifest}
    if layout_id not in allowed:
        raise ContractError("RESOURCE_NOT_FOUND", "오선 템플릿을 찾을 수 없습니다.", 404)
    return FileResponse((settings.CONTENT_ROOT / "sheets" / f"{layout_id}.png").open("rb"), content_type="image/png")

@api_view(["GET"])
@renderer_classes([JSONRenderer, PNGRenderer])
def score_display(request, question_id, version):
    item = get_object_or_404(QuestionVersion, question_id=question_id, version=version)
    visible = item.question.published and item.question.current_version == version
    if not visible and not Attempt.objects.filter(user=request.user, question_version=item).exists():
        raise ContractError("RESOURCE_NOT_FOUND", "악보를 찾을 수 없습니다.", 404)
    asset = reference_asset(item.metadata)
    if asset is None:
        raise ContractError("RESOURCE_NOT_FOUND", "정답 이미지가 준비되지 않았습니다.", 404)
    response = FileResponse((settings.CONTENT_ROOT / "engraving" / (asset["resource"] + ".png")).open("rb"), content_type="image/png")
    response["ETag"] = '"' + asset["sha256"] + '"'
    response["Cache-Control"] = "private, max-age=86400"
    return response
