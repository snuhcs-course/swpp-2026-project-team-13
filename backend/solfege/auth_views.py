"""Password login and signup with PostgreSQL-backed rolling attempt limits."""
import json
import logging
import math
import re
import unicodedata
from datetime import timedelta

from django.conf import settings
from django.contrib.auth import get_user_model
from django.contrib.auth.hashers import check_password, make_password
from django.contrib.auth.password_validation import validate_password
from django.core.exceptions import ValidationError
from django.db import IntegrityError, transaction
from django.db.models import Q
from django.utils import timezone
from django.views.decorators.debug import sensitive_post_parameters
from rest_framework.authtoken.models import Token
from rest_framework.exceptions import UnsupportedMediaType
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from .client_ip import client_ip_key
from .errors import ContractError
from .accounts import profile_body
from .models import LoginThrottle, UserProfile, locked_throttle, throttle_key, usernames_differing_by_case
from .presentation import absolute
from .views import GOALS

WINDOW_SECONDS = 300
DAY_SECONDS = 86400
USERNAME_FORMAT = re.compile(r"[a-z][a-z0-9_]{3,19}")
BIDI_CONTROLS = frozenset("؜‎‏‪‫‬‭‮⁦⁧⁨⁩")
SIGNUP_FIELD_RULES = {
    "username": "아이디는 영문 소문자로 시작하고 영문 소문자·숫자·_만 쓰는 4~20자여야 합니다.",
    "display_name": "표시 이름은 앞뒤 공백과 제어 문자 없이 1~20자여야 합니다.",
    "learning_goal": "학습 목표를 선택해 주세요.",
    "password": "비밀번호는 1~1024자의 문자열이어야 합니다.",
}

logger = logging.getLogger(__name__)


def purge_stale_throttles():
    # The longest counting window is 24 hours, so limit decisions cannot change.
    now = timezone.now()
    LoginThrottle.objects.filter(
        Q(blocked_until__isnull=True) | Q(blocked_until__lte=now),
        updated_at__lt=now - timedelta(seconds=DAY_SECONDS),
    ).delete()


def remaining(until, now):
    return max(0, math.ceil((until - now).total_seconds() * 1000)) if until else 0


def rate_limited(milliseconds, message="잠시 후 다시 로그인해 주세요."):
    return ContractError("RATE_LIMITED", message, 429, retry_after_ms=max(1, milliseconds))


def recent_events(events, window, now):
    return sorted(t for t in events if t > now.timestamp() - window)


def limit_wait(events, limit, window, now):
    """Milliseconds until the event count drops below limit, or 0 when it already is."""
    if len(events) < limit:
        return 0
    return max(1, math.ceil((events[len(events) - limit] + window - now.timestamp()) * 1000))


def is_json(request):
    return request.content_type.split(";")[0].strip().lower() == "application/json"


def username_from_body(request):
    # Used only to look up an existing block when the IP is already limited.
    if not is_json(request):
        return None
    try:
        data = json.loads(request.body)
        value = data.get("username") if isinstance(data, dict) else None
        if not isinstance(value, str) or not 1 <= len(value) <= 150:
            return None
        value.encode("utf-8")
        return value
    except (ValueError, RecursionError):
        return None


def count_request(kind, ip, limit):
    """Record one request unless the IP is over its limit; returns the wait in milliseconds."""
    with transaction.atomic():
        row = locked_throttle(kind, ip)
        now = timezone.now()
        row.events = recent_events(row.events, WINDOW_SECONDS, now)
        wait = limit_wait(row.events, limit, WINDOW_SECONDS, now)
        if wait:
            return wait
        row.events.append(now.timestamp())
        row.save(update_fields=["events", "updated_at"])
    return 0


def log_attempt(kind, ip):
    # Never the address itself; the prefix only tells networks apart in deployment tests.
    logger.info("%s request ip_key=%s", kind, throttle_key("ip", ip)[:8])


def text_error(data, name, maximum):
    """The first code of the order shared by every authentication API, up to UTF-8 validity."""
    if name not in data:
        return "required"
    value = data[name]
    if not isinstance(value, str):
        return "invalid"
    if not value:
        return "blank"
    if len(value) > maximum:
        return "max_length"
    try:
        value.encode("utf-8")
    except UnicodeError:
        return "invalid"
    return None


def json_body(request):
    if not is_json(request):
        raise UnsupportedMediaType(request.content_type)
    # DRF reads an empty body as {}, but an empty body is not valid JSON.
    if not request.body:
        return None
    try:
        return request.data
    except RecursionError:
        # Nesting that fits in 32 KiB can still exhaust the JSON decoder's stack.
        return None


def credentials(request):
    data = json_body(request)
    if not isinstance(data, dict) or set(data) - {"username", "password"}:
        raise ContractError("VALIDATION_ERROR", "아이디와 비밀번호만 보내 주세요.")
    errors = []
    for name, maximum in (("username", 150), ("password", 1024)):
        code = text_error(data, name, maximum)
        if code:
            errors.append({"field": name, "code": code, "message": f"{name}은 1~{maximum}자의 문자열이어야 합니다."})
    if errors:
        raise ContractError("VALIDATION_ERROR", "입력한 내용을 확인해 주세요.", fields=errors)
    return data["username"], data["password"]


class LoginView(APIView):
    authentication_classes = []
    permission_classes = [AllowAny]
    http_method_names = ["post", "options"]

    def post(self, request):
        ip = client_ip_key(request)
        log_attempt("login", ip)
        ip_wait = count_request("ip", ip, settings.LOGIN_MAX_REQUESTS_PER_IP)
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
                row.save(update_fields=["events", "blocked_until", "updated_at"])
                return self.error_response(request, ContractError(
                    "INVALID_CREDENTIALS", "아이디 또는 비밀번호를 확인해 주세요.", 401))
            row.events = []
            row.save(update_fields=["events", "blocked_until", "updated_at"])
            token, _ = Token.objects.get_or_create(user=user)
            profile, _ = UserProfile.objects.get_or_create(user=user)
            return Response(login_body(token, user, profile))

    def error_response(self, request, error):
        from .errors import exception_handler
        return exception_handler(error, {"request": request, "view": self})


def login_body(token, user, profile):
    return {"access_token": token.key, "token_type": "Bearer", "user": profile_body(user, profile)}


class LogoutView(APIView):
    http_method_names = ["post", "options"]

    def post(self, request):
        with transaction.atomic():
            get_user_model().objects.select_for_update().get(pk=request.user.pk)
            # A late logout must never delete a replacement token.
            Token.objects.filter(user=request.user, key=request.auth.key).delete()
        return Response(status=204)


def display_name_is_valid(value):
    # str.strip() also removes U+001C-U+001F, which are not White_Space but are Cc anyway.
    return value == value.strip() and not any(
        unicodedata.category(character) in ("Cc", "Zl", "Zp") or character in BIDI_CONTROLS for character in value
    )


def username_code(data):
    code = text_error(data, "username", 20)
    if code:
        return code
    if len(data["username"]) < 4:
        return "min_length"
    return None if USERNAME_FORMAT.fullmatch(data["username"]) else "invalid_format"


def signup_field_codes(data):
    codes = {
        "username": username_code(data),
        "display_name": text_error(data, "display_name", 20),
        # Optional: the app asks for the goal after the account exists.
        "learning_goal": text_error(data, "learning_goal", math.inf) if "learning_goal" in data else None,
        "password": text_error(data, "password", 1024),
    }
    if not codes["display_name"] and not display_name_is_valid(data["display_name"]):
        codes["display_name"] = "invalid_format"
    # The list has no encoding rule, so an unencodable value is simply not a choice.
    goal = data.get("learning_goal")
    if isinstance(goal, str) and goal and goal not in GOALS:
        codes["learning_goal"] = "invalid_choice"
    return codes


def signup_fields(data):
    """Every violated field once, in contract order; only password can repeat, once per policy."""
    codes = signup_field_codes(data)
    errors = [
        {"field": name, "code": code, "message": SIGNUP_FIELD_RULES[name]}
        for name, code in codes.items() if code
    ]
    if not codes["password"]:
        # Similarity to the username is checked only for a username that could exist.
        user = get_user_model()(username=data["username"]) if not codes["username"] else None
        try:
            validate_password(data["password"], user)
        except ValidationError as error:
            errors += [{"field": "password", "code": item.code, "message": " ".join(item.messages)} for item in error.error_list]
    return errors


def username_taken():
    return ContractError("USERNAME_TAKEN", "이미 사용 중인 아이디입니다.", 409, fields=[
        {"field": "username", "code": "taken", "message": "이미 사용 중인 아이디입니다."},
    ])


def signup_rate_limited(milliseconds):
    return rate_limited(milliseconds, "잠시 후 다시 가입해 주세요.")


def signup_success_wait(ip):
    row = LoginThrottle.objects.filter(key=throttle_key("signup-success", ip)).first()
    if row is None:
        return 0
    now = timezone.now()
    return limit_wait(recent_events(row.events, DAY_SECONDS, now), settings.SIGNUP_MAX_SUCCESSES_PER_IP, DAY_SECONDS, now)


class SignupAvailabilityView(APIView):
    authentication_classes = []
    permission_classes = [AllowAny]
    http_method_names = ["get", "options"]

    def get(self, request):
        return Response({"signup_enabled": settings.SIGNUP_ENABLED})


class UsernameCheckView(APIView):
    authentication_classes = []
    permission_classes = [AllowAny]
    http_method_names = ["post", "options"]

    def post(self, request):
        if not settings.SIGNUP_ENABLED:
            raise ContractError("SIGNUP_DISABLED", "현재 회원가입을 제공하지 않습니다.", 403)
        ip = client_ip_key(request)
        log_attempt("username-check", ip)
        # A separate counter: checking while typing must never use up the IP's signup attempts.
        wait = count_request("username-check", ip, settings.USERNAME_CHECK_MAX_REQUESTS_PER_IP)
        if wait:
            raise rate_limited(wait, "잠시 후 다시 확인해 주세요.")
        data = json_body(request)
        if not isinstance(data, dict) or set(data) - {"username"}:
            raise ContractError("VALIDATION_ERROR", "아이디만 보내 주세요.")
        code = username_code(data)
        if code:
            raise ContractError("VALIDATION_ERROR", "입력한 내용을 확인해 주세요.", fields=[
                {"field": "username", "code": code, "message": SIGNUP_FIELD_RULES["username"]},
            ])
        # Advisory: someone can still take the name before the signup, which then gets the 409.
        return Response({"available": not usernames_differing_by_case(data["username"]).exists()})


class SignupView(APIView):
    authentication_classes = []
    permission_classes = [AllowAny]
    http_method_names = ["post", "options"]

    def post(self, request):
        if not settings.SIGNUP_ENABLED:
            raise ContractError("SIGNUP_DISABLED", "현재 회원가입을 제공하지 않습니다.", 403)
        ip = client_ip_key(request)
        log_attempt("signup", ip)
        request_wait = count_request("signup", ip, settings.SIGNUP_MAX_REQUESTS_PER_IP)
        success_wait = signup_success_wait(ip)
        if request_wait or success_wait:
            raise signup_rate_limited(max(request_wait, success_wait))
        data = json_body(request)
        if not isinstance(data, dict) or set(data) - set(SIGNUP_FIELD_RULES):
            raise ContractError("VALIDATION_ERROR", "입력 항목을 확인해 주세요.")
        errors = signup_fields(data)
        if errors:
            raise ContractError("VALIDATION_ERROR", "입력한 내용을 확인해 주세요.", fields=errors)
        username = data["username"]
        if usernames_differing_by_case(username).exists():
            raise username_taken()
        # Hash first: holding the IP lock for it would queue that IP's signups behind each hash.
        password = make_password(data["password"])
        with transaction.atomic():
            # The check above is only a fast rejection; this one decides under the lock.
            row = locked_throttle("signup-success", ip)
            now = timezone.now()
            row.events = recent_events(row.events, DAY_SECONDS, now)
            wait = limit_wait(row.events, settings.SIGNUP_MAX_SUCCESSES_PER_IP, DAY_SECONDS, now)
            if wait:
                raise signup_rate_limited(wait)
            try:
                with transaction.atomic():
                    user = get_user_model().objects.create(username=username, password=password)
            except IntegrityError:
                raise username_taken() from None
            profile = UserProfile.objects.create(
                user=user, display_name=data["display_name"], learning_goal=data.get("learning_goal"), created_via="signup",
            )
            token = Token.objects.create(user=user)
            # Failures before the account existed must not lock the new account out.
            LoginThrottle.objects.filter(key=throttle_key("username", username)).delete()
            row.events.append(now.timestamp())
            row.save(update_fields=["events", "updated_at"])
        return Response(login_body(token, user, profile), status=201, headers={"Location": absolute(request, "/api/v1/me/")})


login = sensitive_post_parameters("password")(LoginView.as_view())
logout = LogoutView.as_view()
signup = sensitive_post_parameters("password")(SignupView.as_view())
signup_availability = SignupAvailabilityView.as_view()
username_check = UsernameCheckView.as_view()
