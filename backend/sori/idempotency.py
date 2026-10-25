import hashlib
import json
import uuid
from django.db import connection, transaction
from rest_framework.response import Response
from .errors import ContractError
from .models import IdempotencyRecord

def uuid_value(value, field):
    if not isinstance(value, str):
        raise ContractError("VALIDATION_ERROR", f"{field}는 UUID 문자열이어야 합니다.")
    try:
        return uuid.UUID(value)
    except ValueError:
        raise ContractError("VALIDATION_ERROR", f"{field}의 UUID 형식을 확인해 주세요.") from None

def run_idempotent(request, payload, operation):
    key = uuid_value(request.headers.get("Idempotency-Key"), "Idempotency-Key")
    scope = {"user": request.user, "method": request.method, "path": request.path, "key": key}
    fingerprint = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
    with transaction.atomic():
        lock_name = f"{request.user.pk}:{request.method}:{request.path}:{key}"
        lock_id = int.from_bytes(hashlib.blake2b(lock_name.encode(), digest_size=8).digest(), "big", signed=True)
        with connection.cursor() as cursor:
            cursor.execute("SELECT pg_try_advisory_xact_lock(%s)", [lock_id])
            if not cursor.fetchone()[0]:
                raise ContractError("REQUEST_IN_PROGRESS", "같은 요청을 처리 중입니다.", 409, retry_after_ms=1000)
        prior = IdempotencyRecord.objects.filter(**scope).first()
        if prior:
            if prior.request_hash != fingerprint:
                raise ContractError("IDEMPOTENCY_KEY_REUSED", "이 키는 다른 요청에 사용되었습니다.", 409)
            response = Response(prior.response_body, status=prior.response_status)
            response["Idempotency-Replayed"] = "true"
            if prior.location:
                response["Location"] = prior.location
            return response
        body, status, location = operation()
        IdempotencyRecord.objects.create(**scope, request_hash=fingerprint, response_status=status, response_body=body, location=location)
        response = Response(body, status=status)
        if location:
            response["Location"] = location
        return response
