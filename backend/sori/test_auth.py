import io
import json
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from threading import Event
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.contrib.auth.hashers import make_password
from django.core.management import call_command
from django.db import close_old_connections, connection, transaction
from django.test import RequestFactory, TestCase, TransactionTestCase, override_settings
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from .auth_views import LogoutView, throttle_key
from .errors import RequestMiddleware
from .models import LoginThrottle, UserProfile

LOGIN = "/api/v1/auth/login/"
LOGOUT = "/api/v1/auth/logout/"
FAST_HASHERS = ["django.contrib.auth.hashers.MD5PasswordHasher"]


@override_settings(PASSWORD_HASHERS=FAST_HASHERS)
class LoginTests(TestCase):
    def setUp(self):
        self.user = get_user_model().objects.create_user(username="student01", password=" password ")
        self.client = APIClient()

    def login(self, username="student01", password=" password ", **kwargs):
        return self.client.post(LOGIN, {"username": username, "password": password}, format="json", **kwargs)

    def assert_error(self, response, status, code):
        self.assertEqual(response.status_code, status, getattr(response, "data", response.content))
        data = json.loads(response.content)
        self.assertEqual(data["error"]["code"], code)
        self.assertEqual(data["request_id"], response["X-Request-ID"])
        self.assertEqual(response["Cache-Control"], "private, no-store")
        if status == 401:
            self.assertEqual(response["WWW-Authenticate"], "Bearer")
        if status != 429:
            self.assertIsNone(data["error"]["retry_after_ms"])
        return data["error"]

    def test_login_ignores_stale_authorization_reuses_token_and_profile(self):
        self.client.credentials(HTTP_AUTHORIZATION="Bearer invalid-token")
        first = self.login()
        self.assertEqual(first.status_code, 200)
        self.assertEqual(set(first.data), {"access_token", "token_type", "user"})
        self.assertEqual(first.data["token_type"], "Bearer")
        second = self.login()
        self.assertEqual(first.data, second.data)
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + first.data["access_token"])
        me = self.client.get("/api/v1/me/")
        self.assertEqual(first.data["user"], me.data)
        self.assertEqual(UserProfile.objects.filter(user=self.user).count(), 1)
        self.assertEqual(Token.objects.filter(user=self.user).count(), 1)

    def test_all_invalid_credentials_have_same_error(self):
        inactive = get_user_model().objects.create_user(username="inactive", password="pw", is_active=False)
        unusable = get_user_model().objects.create_user(username="unusable")
        self.assertFalse(unusable.has_usable_password())
        for username, password in (("unknown", "pw"), ("student01", "wrong"),
                                   (inactive.username, "pw"), (unusable.username, "pw"),
                                   ("Student01", " password "), (" student01", " password ")):
            detail = self.assert_error(self.login(username, password), 401, "INVALID_CREDENTIALS")
            self.assertEqual(detail["message"], "아이디 또는 비밀번호를 확인해 주세요.")
            self.assertEqual(detail["fields"], [])

    def test_validation_does_not_coerce_or_trim_fields(self):
        cases = [[], None, {}, {"username": "student01"}, {"username": "x", "password": ""},
                 {"username": 123, "password": "x"}, {"username": "x", "password": False},
                 {"username": "x" * 151, "password": "x"}, {"username": "x", "password": "x" * 1025},
                 {"username": "x", "password": "x", "extra": True}]
        for data in cases:
            response = self.client.generic("POST", LOGIN, json.dumps(data), content_type="application/json")
            self.assert_error(response, 400, "VALIDATION_ERROR")
        response = self.client.post(LOGIN, {"username": "student01"}, format="json")
        self.assertEqual(response.data["error"]["fields"][0]["field"], "password")
        self.assertEqual(response.data["error"]["fields"][0]["code"], "required")
        self.assert_error(self.client.generic("POST", LOGIN, b'{"broken":', content_type="application/json"), 400, "VALIDATION_ERROR")
        self.assert_error(self.client.post(LOGIN, {"username": "x"}), 415, "UNSUPPORTED_MEDIA_TYPE")
        self.assertEqual(self.login().status_code, 200)

    def test_body_size_boundary_and_lengthless_requests_precede_throttling(self):
        body = json.dumps({"username": "student01", "password": " password "}).encode()
        self.assertEqual(self.client.generic("POST", LOGIN, body + b" " * (32768 - len(body)), content_type="application/json").status_code, 200)
        before = list(LoginThrottle.objects.values_list("key", "events"))
        for has_length in (True, False):
            request = RequestFactory().generic("POST", LOGIN, b" " * 32769, content_type="text/plain")
            if not has_length:
                request.META.pop("CONTENT_LENGTH", None)
            middleware = RequestMiddleware(lambda r: self.fail("Oversized body reached view"))
            response = middleware(request)
            detail = self.assert_error(response, 413, "REQUEST_TOO_LARGE")
            self.assertEqual(detail["fields"], [])
        self.assertEqual(before, list(LoginThrottle.objects.values_list("key", "events")))

    def test_username_limit_is_five_failures_then_fixed_five_minute_block(self):
        now = timezone.now()
        with patch("sori.auth_views.timezone.now", return_value=now):
            for _ in range(5):
                self.assert_error(self.login(password="wrong"), 401, "INVALID_CREDENTIALS")
            blocked = self.assert_error(self.login(), 429, "RATE_LIMITED")
            self.assertEqual(blocked["retry_after_ms"], 300000)
        with patch("sori.auth_views.timezone.now", return_value=now + timedelta(seconds=120)):
            response = self.login()
            self.assertEqual(response["Retry-After"], "180")
            self.assertEqual(response.data["error"]["retry_after_ms"], 180000)
        with patch("sori.auth_views.timezone.now", return_value=now + timedelta(seconds=300)):
            self.assertEqual(self.login().status_code, 200)
            self.assert_error(self.login(password="wrong"), 401, "INVALID_CREDENTIALS")
        row = LoginThrottle.objects.get(key=throttle_key("username", "student01"))
        self.assertEqual(len(row.events), 1)
        self.assertIsNone(row.blocked_until)

    def test_success_and_old_failures_reset_username_count(self):
        now = timezone.now()
        with patch("sori.auth_views.timezone.now", return_value=now):
            for _ in range(4):
                self.login(password="wrong")
            self.assertEqual(self.login().status_code, 200)
            self.login(password="wrong")
        with patch("sori.auth_views.timezone.now", return_value=now + timedelta(seconds=301)):
            for _ in range(4):
                self.assertEqual(self.login(password="wrong").status_code, 401)
            self.assertEqual(self.login().status_code, 200)

    def test_ip_limit_counts_validation_success_and_username_blocks(self):
        now = timezone.now()
        with patch("sori.auth_views.timezone.now", return_value=now):
            for _ in range(5):
                self.login("missing", "wrong")
            for _ in range(10):
                self.assertEqual(self.login("missing", "wrong").status_code, 429)
            for _ in range(10):
                self.assertEqual(self.login().status_code, 200)
            for _ in range(5):
                self.assertEqual(self.client.post(LOGIN, {}, format="json").status_code, 400)
            for content_type, body in (("application/json", b"{"), ("text/plain", b"x"), ("application/json", b"{}")):
                response = self.client.generic("POST", LOGIN, body, content_type=content_type, HTTP_X_FORWARDED_FOR="8.8.8.8")
                self.assert_error(response, 429, "RATE_LIMITED")
                self.assertEqual(response["Retry-After"], "300")
            row = LoginThrottle.objects.get(key=throttle_key("ip", "127.0.0.1"))
            self.assertEqual(len(row.events), 30)
            self.assertEqual(self.login(REMOTE_ADDR="127.0.0.2").status_code, 200)
        with patch("sori.auth_views.timezone.now", return_value=now + timedelta(seconds=300)):
            self.assertEqual(self.login().status_code, 200)

    def test_combined_limits_return_longer_wait_and_round_up(self):
        now = timezone.now()
        LoginThrottle.objects.create(key=throttle_key("ip", "127.0.0.1"), events=[now.timestamp() - 299] * 30)
        LoginThrottle.objects.create(key=throttle_key("username", "student01"), events=[], blocked_until=now + timedelta(seconds=10, milliseconds=1))
        with patch("sori.auth_views.timezone.now", return_value=now):
            response = self.login()
            self.assert_error(response, 429, "RATE_LIMITED")
            self.assertEqual(response.data["error"]["retry_after_ms"], 10001)
            self.assertEqual(response["Retry-After"], "11")
            response = self.client.generic("POST", LOGIN, b" " * 32769, content_type="application/json")
            self.assert_error(response, 413, "REQUEST_TOO_LARGE")

    def test_logout_revokes_only_token_and_preserves_user_data(self):
        first = self.login().data
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + first["access_token"])
        response = self.client.post(LOGOUT)
        self.assertEqual(response.status_code, 204)
        self.assertEqual(response.content, b"")
        self.assertEqual(response["Cache-Control"], "private, no-store")
        self.assertIn("X-Request-ID", response)
        self.assert_error(self.client.post(LOGOUT), 401, "AUTHENTICATION_REQUIRED")
        self.assert_error(self.client.get("/api/v1/me/"), 401, "AUTHENTICATION_REQUIRED")
        second = self.login().data
        self.assertNotEqual(first["access_token"], second["access_token"])
        self.assertEqual(first["user"], second["user"])

    def test_password_changes_and_deactivation_revoke_tokens(self):
        for change in ("password", "inactive"):
            first = self.login().data["access_token"]
            if change == "password":
                self.user.set_password("replacement")
                self.user.save(update_fields=["password"])
            else:
                get_user_model().objects.filter(pk=self.user.pk).update(is_active=False)
            self.assertFalse(Token.objects.filter(key=first).exists())
            self.client.credentials(HTTP_AUTHORIZATION="Bearer " + first)
            self.assert_error(self.client.get("/api/v1/me/"), 401, "AUTHENTICATION_REQUIRED")
            self.user.set_password(" password "); self.user.is_active = True
            self.user.save(update_fields=["password", "is_active"])
            self.assertFalse(Token.objects.filter(key=first).exists())

    @override_settings(PASSWORD_HASHERS=["django.contrib.auth.hashers.PBKDF2PasswordHasher"])
    def test_older_password_hash_login_keeps_existing_token(self):
        from django.contrib.auth.hashers import PBKDF2PasswordHasher
        old_hash = PBKDF2PasswordHasher().encode(" password ", "test-salt", iterations=1)
        get_user_model().objects.filter(pk=self.user.pk).update(password=old_hash)
        token = Token.objects.create(user=self.user)
        response = self.login()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["access_token"], token.key)

    def test_methods_and_protected_endpoints(self):
        self.assert_error(self.client.get(LOGIN), 405, "METHOD_NOT_ALLOWED")
        self.assert_error(self.client.post(LOGOUT), 401, "AUTHENTICATION_REQUIRED")
        self.assert_error(self.client.get("/api/v1/me/"), 401, "AUTHENTICATION_REQUIRED")
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + self.login().data["access_token"])
        self.assert_error(self.client.get(LOGOUT), 405, "METHOD_NOT_ALLOWED")

    @override_settings(AUTH_PASSWORD_VALIDATORS=[])
    def test_interactive_account_creation_and_password_reset_do_not_issue_tokens(self):
        output = io.StringIO()
        for password in ("initial password", "replacement password"):
            with patch("sori.management.commands.create_practice_user.getpass", side_effect=[password, password]):
                call_command("create_practice_user", "new-student", stdout=output)
            user = get_user_model().objects.get(username="new-student")
            self.assertTrue(user.check_password(password))
            self.assertFalse(Token.objects.filter(user=user).exists())
            self.assertNotIn(password, output.getvalue())
            Token.objects.create(user=user)


@override_settings(PASSWORD_HASHERS=FAST_HASHERS)
class LoginConcurrencyTests(TransactionTestCase):
    def setUp(self):
        self.user = get_user_model().objects.create_user(username="student01", password="pw")

    def in_connection(self, operation):
        close_old_connections()
        try:
            return operation()
        finally:
            connection.close()

    def login(self, password="pw"):
        return APIClient().post(LOGIN, {"username": "student01", "password": password}, format="json")

    def test_concurrent_logins_share_one_token_and_profile(self):
        with ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(lambda _: self.in_connection(self.login), range(6)))
        self.assertEqual([r.status_code for r in results], [200] * 6)
        self.assertEqual(len({r.data["access_token"] for r in results}), 1)
        self.assertEqual(len({r.data["user"]["id"] for r in results}), 1)
        self.assertEqual(Token.objects.count(), 1)
        self.assertEqual(UserProfile.objects.count(), 1)

    def test_concurrent_failures_and_ip_requests_are_atomic(self):
        with ThreadPoolExecutor(max_workers=8) as pool:
            responses = list(pool.map(lambda _: self.in_connection(lambda: self.login("wrong")), range(36)))
        self.assertEqual(sum(r.status_code == 401 for r in responses), 5)
        self.assertEqual(sum(r.status_code == 429 for r in responses), 31)
        self.assertEqual(len(LoginThrottle.objects.get(key=throttle_key("ip", "127.0.0.1")).events), 30)

    def test_credential_change_waits_for_login_then_revokes_issued_token(self):
        for change in ({"password": make_password("new")}, {"is_active": False}):
            get_user_model().objects.filter(pk=self.user.pk).update(password=make_password("pw"), is_active=True)
            checking, release, changing = Event(), Event(), Event()
            from .auth_views import check_password

            def held_check(password, encoded):
                checking.set()
                self.assertTrue(release.wait(5))
                return check_password(password, encoded)

            def mutate():
                changing.set()
                get_user_model().objects.filter(pk=self.user.pk).update(**change)

            with patch("sori.auth_views.check_password", held_check), ThreadPoolExecutor(max_workers=2) as pool:
                pending_login = pool.submit(self.in_connection, self.login)
                self.assertTrue(checking.wait(5))
                pending_change = pool.submit(self.in_connection, mutate)
                self.assertTrue(changing.wait(5))
                release.set()
                response = pending_login.result(10); pending_change.result(10)
            self.assertEqual(response.status_code, 200)
            self.assertFalse(Token.objects.filter(key=response.data["access_token"]).exists())

    def test_login_waits_for_credential_change_and_checks_committed_state(self):
        for change in ({"password": make_password("new")}, {"is_active": False}):
            get_user_model().objects.filter(pk=self.user.pk).update(password=make_password("pw"), is_active=True)
            changed, release, starting = Event(), Event(), Event()

            def mutate():
                with transaction.atomic():
                    get_user_model().objects.filter(pk=self.user.pk).update(**change)
                    changed.set()
                    self.assertTrue(release.wait(5))

            def login():
                starting.set()
                return self.login()

            with ThreadPoolExecutor(max_workers=2) as pool:
                pending_change = pool.submit(self.in_connection, mutate)
                self.assertTrue(changed.wait(5))
                pending_login = pool.submit(self.in_connection, login)
                self.assertTrue(starting.wait(5))
                release.set(); pending_change.result(10)
                response = pending_login.result(10)
            self.assertEqual(response.status_code, 401)
            self.assertFalse(Token.objects.filter(user=self.user).exists())

    def test_late_logout_does_not_revoke_relogin_token(self):
        old = self.login().data["access_token"]
        authenticated, release = Event(), Event()
        original = LogoutView.post

        def delayed(view, request):
            authenticated.set()
            self.assertTrue(release.wait(5))
            return original(view, request)

        def logout():
            client = APIClient(); client.credentials(HTTP_AUTHORIZATION="Bearer " + old)
            return client.post(LOGOUT)

        with patch.object(LogoutView, "post", delayed), ThreadPoolExecutor(max_workers=1) as pool:
            pending_logout = pool.submit(self.in_connection, logout)
            self.assertTrue(authenticated.wait(5))
            Token.objects.filter(key=old).delete()
            new = self.login().data["access_token"]
            self.assertNotEqual(old, new)
            release.set()
            self.assertEqual(pending_logout.result(10).status_code, 204)
        self.assertTrue(Token.objects.filter(key=new).exists())
