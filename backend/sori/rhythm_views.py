import hashlib
import json
from functools import lru_cache
from django.conf import settings
from django.contrib.auth import get_user_model
from django.db import transaction
from django.shortcuts import get_object_or_404
from rest_framework.decorators import api_view, parser_classes
from rest_framework.parsers import JSONParser
from rest_framework.response import Response
from .errors import ContractError
from .features import FeatureError
from .features.registration import ensure_question_analysis
from .idempotency import run_idempotent
from .models import QuestionVersion, RhythmPlay
from .rhythm import digest
from .rhythm_records import validate_record


@lru_cache(maxsize=4)
def catalog_at(root, version="rhythm-puzzle-v1"):
    if version not in ("rhythm-puzzle-v1", "rhythm-puzzle-v2", "rhythm-puzzle-v3"):
        raise ValueError("catalog_version_mismatch")
    raw = (root / (version + ".json")).read_bytes()
    return json.loads(raw), hashlib.sha256(raw).hexdigest()


def present(row):
    return dict(id=str(row.id), client_play_id=str(row.client_play_id), round_id=row.round_id,
                catalog_sha256=row.catalog_sha256, result=row.result, created_at=row.created_at.isoformat())


@api_view(["GET", "POST"])
@parser_classes([JSONParser])
def plays(request):
    if request.method == "GET":
        try:
            page = int(request.query_params.get("page", "1"))
            if page < 1:
                raise ValueError
        except ValueError:
            raise ContractError("VALIDATION_ERROR", "페이지를 확인해 주세요.") from None
        rows = RhythmPlay.objects.filter(user=request.user).order_by("-created_at", "id")
        return Response(dict(count=rows.count(), results=[present(r) for r in rows[(page - 1) * 30:page * 30]]))
    if len(request.body) > 128 * 1024:
        raise ContractError("RECORD_TOO_LARGE", "연습 기록이 허용 크기를 초과했습니다.", 413)
    try:
        if not isinstance(request.data, dict):
            raise ValueError("invalid_record_fields")
        catalog, sha = catalog_at(settings.CONTENT_ROOT, request.data.get("game_version", "rhythm-puzzle-v1"))
        round_, result = validate_record(request.data, catalog, sha)
    except (ValueError, TypeError, KeyError, ZeroDivisionError) as error:
        code = "RHYTHM_CATALOG_MISMATCH" if str(error) == "catalog_version_mismatch" else "VALIDATION_ERROR"
        raise ContractError(code, "앱과 서버의 리듬 문제 버전 또는 연습 기록을 확인해 주세요.", 409 if code == "RHYTHM_CATALOG_MISMATCH" else 400) from None
    def operation():
        # Serialize with account deletion; the row cascades without PROTECT references to the user.
        get_object_or_404(get_user_model().objects.select_for_update(), pk=request.user.pk)
        fingerprint = digest(request.data)
        old = RhythmPlay.objects.filter(user=request.user, client_play_id=request.data["client_play_id"]).first()
        if old:
            if old.payload_sha256 != fingerprint:
                raise ContractError("RHYTHM_PLAY_CONFLICT", "이미 저장된 기록을 덮어쓸 수 없습니다.", 409)
            return present(old), 200, ""
        version = get_object_or_404(QuestionVersion, question_id=round_["question_id"], version=round_["question_version"])
        try:
            analysis = ensure_question_analysis(version)
        except (FeatureError, OSError):
            raise ContractError("QUESTION_ANALYSIS_UNAVAILABLE", "문제 분석을 확인할 수 없습니다.", 503) from None
        if analysis.analysis_key != round_["analysis_key"]:
            raise ContractError("RHYTHM_CATALOG_MISMATCH", "분석 버전을 확인해 주세요.", 409)
        row = RhythmPlay.objects.create(user=request.user, client_play_id=request.data["client_play_id"],
            question_version=version, feature_analysis=analysis, round_id=round_["id"], catalog_sha256=sha,
            payload_sha256=fingerprint, payload=request.data, result=result)
        return present(row), 201, ""
    return run_idempotent(request, request.data, operation)
