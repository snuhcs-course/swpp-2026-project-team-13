"""Password login with PostgreSQL-backed rolling attempt limits."""
import hashlib
import json
import math
from datetime import timedelta

from django.contrib.auth import get_user_model
from django.contrib.auth.hashers import check_password
from django.db import transaction
from django.utils import timezone
from django.views.decorators.debug import sensitive_post_parameters
from rest_framework.authtoken.models import Token
from rest_framework.exceptions import UnsupportedMediaType
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from .errors import ContractError
from .models import LoginThrottle, UserProfile

WINDOW_SECONDS = 300


def throttle_key(kind, value):
    return hashlib.sha256((kind + "\0" + value).encode("utf-8")).hexdigest()


def locked_throttle(kind, value):
    key = throttle_key(kind, value)
    LoginThrottle.objects.get_or_create(key=key)
    return LoginThrottle.objects.select_for_update().get(key=key)


def remaining(until, now):
    return max(0, math.ceil((until - now).total_seconds() * 1000)) if until else 0


def rate_limited(milliseconds):
    return ContractError("RATE_LIMITED", "잠시 후 다시 로그인해 주세요.", 429,
                         retry_after_ms=max(1, milliseconds))


def username_from_body(request):
    # Used only to look up an existing block when the IP is already limited.
    if request.content_type != "application/json":
        return None
    try:
        data = json.loads(request.body)
        value = data.get("username") if isinstance(data, dict) else None
        return value if isinstance(value, str) and 1 <= len(value) <= 150 else None
    except (ValueError, UnicodeError):
        return None


def count_ip(request):
    # Deliberately ignore X-Forwarded-For and similar untrusted headers.
    with transaction.atomic():
        row = locked_throttle("ip", request.META.get("REMOTE_ADDR", ""))
        now = timezone.now()
        row.events = [t for t in row.events if t > now.timestamp() - WINDOW_SECONDS]
        if len(row.events) >= 30:
            return max(1, math.ceil((row.events[0] + WINDOW_SECONDS - now.timestamp()) * 1000))
        row.events.append(now.timestamp())
        row.save(update_fields=["events"])
    return 0


def credentials(request):
    if request.content_type != "application/json":
        raise UnsupportedMediaType(request.content_type)
    data = request.data
    if not isinstance(data, dict) or set(data) - {"username", "password"}:
        raise ContractError("VALIDATION_ERROR", "아이디와 비밀번호만 보내 주세요.")
    errors = []
    for name, maximum in (("username", 150), ("password", 1024)):
        value = data.get(name)
        if name not in data:
            code = "required"
        elif not isinstance(value, str):
            code = "invalid"
        elif not value:
            code = "blank"
        elif len(value) > maximum:
            code = "max_length"
        else:
            try:
                value.encode("utf-8")
            except UnicodeError:
                code = "invalid"
            else:
                continue
        errors.append({"field": name, "code": code, "message": f"{name}은 1~{maximum}자의 문자열이어야 합니다."})
    if errors:
        raise ContractError("VALIDATION_ERROR", "입력한 내용을 확인해 주세요.", fields=errors)
    return data["username"], data["password"]


class LoginView(APIView):
    authentication_classes = []
    permission_classes = [AllowAny]
    http_method_names = ["post", "options"]

    def post(self, request):
        ip_wait = count_ip(request)
        if ip_wait:
            username = username_from_body(request)
            row = LoginThrottle.objects.filter(key=throttle_key("username", username)).first() if username is not None else None
            raise rate_limited(max(ip_wait, remaining(row.blocked_until, timezone.now()) if row else 0))
        username, password = credentials(request)
        # Return errors after committing the failure counter, rather than
        # rolling it back by raising inside atomic().
        with transaction.atomic():
            row = locked_throttle("username", username)
            now = timezone.now()
            wait = remaining(row.blocked_until, now)
            if wait:
                return self.error_response(request, rate_limited(wait))
            if row.blocked_until is not None:
                row.events = []
                row.blocked_until = None
            row.events = [t for t in row.events if t > now.timestamp() - WINDOW_SECONDS]
            User = get_user_model()
            user = User.objects.select_for_update().filter(username=username).first() if "\0" not in username else None
            # Django's missing/unusable password path performs a dummy hash.
            if user is None:
                User().set_password(password)
                valid = False
            else:
                # Verification must not save an automatic hash upgrade: it is
                # not a password change and must preserve an existing token.
                valid = check_password(password, user.password) and user.is_active
            if not valid:
                now = timezone.now()
                row.events = [t for t in row.events if t > now.timestamp() - WINDOW_SECONDS]
                row.events.append(now.timestamp())
                if len(row.events) >= 5:
                    row.blocked_until = now + timedelta(seconds=WINDOW_SECONDS)
                row.save(update_fields=["events", "blocked_until"])
                return self.error_response(request, ContractError(
                    "INVALID_CREDENTIALS", "아이디 또는 비밀번호를 확인해 주세요.", 401))
            row.events = []
            row.save(update_fields=["events", "blocked_until"])
            token, _ = Token.objects.get_or_create(user=user)
            profile, _ = UserProfile.objects.get_or_create(user=user)
            return Response({"access_token": token.key, "token_type": "Bearer", "user": {
                "id": str(profile.id), "display_name": profile.display_name, "learning_goal": profile.learning_goal,
            }})

    def error_response(self, request, error):
        from .errors import exception_handler
        return exception_handler(error, {"request": request, "view": self})


class LogoutView(APIView):
    http_method_names = ["post", "options"]

    def post(self, request):
        with transaction.atomic():
            get_user_model().objects.select_for_update().get(pk=request.user.pk)
            # A late logout must never delete a replacement token.
            Token.objects.filter(user=request.user, key=request.auth.key).delete()
        return Response(status=204)


login = sensitive_post_parameters("password")(LoginView.as_view())
logout = LogoutView.as_view()
