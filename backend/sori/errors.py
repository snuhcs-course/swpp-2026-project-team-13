import uuid
from django.http import JsonResponse
from rest_framework.exceptions import APIException
from rest_framework.views import exception_handler as default_handler

class ContractError(APIException):
    def __init__(self, code, message, status=400, fields=None, retry_after_ms=None):
        self.status_code = status
        self.contract_code, self.contract_message = code, message
        self.fields, self.retry_after_ms = fields or [], retry_after_ms
        super().__init__(message)

def envelope(request, code, message, fields=None, retry_after_ms=None):
    return {"error": {"code": code, "message": message, "fields": fields or [], "retry_after_ms": retry_after_ms}, "request_id": getattr(request, "request_id", str(uuid.uuid4()))}

def exception_handler(exc, context):
    response = default_handler(exc, context)
    request = context["request"]
    if isinstance(exc, ContractError):
        response.data = envelope(request, exc.contract_code, exc.contract_message, exc.fields, exc.retry_after_ms)
        if exc.retry_after_ms is not None:
            response["Retry-After"] = str(max(1, (exc.retry_after_ms + 999) // 1000))
    elif response is not None:
        code, message = {401: ("AUTHENTICATION_REQUIRED", "유효한 개발 토큰이 필요합니다."), 403: ("PERMISSION_DENIED", "접근 권한이 없습니다."), 404: ("RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다."), 405: ("METHOD_NOT_ALLOWED", "지원하지 않는 요청입니다."), 415: ("UNSUPPORTED_MEDIA_TYPE", "요청 콘텐츠 형식을 확인해 주세요.")}.get(response.status_code, ("VALIDATION_ERROR", "요청 형식을 확인해 주세요."))
        response.data = envelope(request, code, message)
    return response

class RequestMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response
    def __call__(self, request):
        request.request_id = str(uuid.uuid4())
        try:
            too_large = int(request.META.get("CONTENT_LENGTH") or 0) > 11 * 1024 * 1024
        except ValueError:
            too_large = True
        if request.path.startswith("/api/v1/") and too_large:
            response = JsonResponse(envelope(request, "IMAGE_TOO_LARGE", "업로드 용량을 초과했습니다."), status=413)
        else:
            response = self.get_response(request)
        response["X-Request-ID"] = request.request_id
        if request.path.startswith("/api/v1/"):
            response["Cache-Control"] = "private, no-store"
        return response
