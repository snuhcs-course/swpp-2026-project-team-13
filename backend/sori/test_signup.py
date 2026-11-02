import hashlib
import hmac
import importlib
import io
import ipaddress
import json
import os
import subprocess
import sys
import tempfile
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from pathlib import Path
from threading import Barrier
from types import SimpleNamespace
from unittest.mock import patch

from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.handlers.wsgi import WSGIRequest
from django.core.management import call_command
from django.core.management.base import CommandError
from django.db import IntegrityError, close_old_connections, connection, transaction
from django.db.migrations.executor import MigrationExecutor
from django.test import Client, RequestFactory, SimpleTestCase, TestCase, TransactionTestCase, override_settings
from django.utils import timezone
from django.views.debug import ExceptionReporter
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from .auth_views import locked_throttle, login, purge_stale_throttles, signup, throttle_key
from .client_ip import client_ip_key
from .errors import RequestMiddleware
from .models import LoginThrottle, Question, UserProfile, usernames_differing_by_case

SIGNUP = "/api/v1/auth/signup/"
AVAILABILITY = "/api/v1/auth/signup-availability/"
LOGIN = "/api/v1/auth/login/"
FAST_HASHERS = ["django.contrib.auth.hashers.MD5PasswordHasher"]
PASSWORD = "quiet-lantern-48"
PROXIES = (ipaddress.ip_network("172.30.0.10/32"),)
VALID = {"username": "student01", "display_name": "청음 연습생", "learning_goal": "college_entrance", "password": PASSWORD}
User = get_user_model()


def form(**changes):
    return {**VALID, **changes}


def without(field):
    return {name: value for name, value in VALID.items() if name != field}


def post_json(client, body, path=SIGNUP, **kwargs):
    return client.generic("POST", path, json.dumps(body), content_type="application/json", **kwargs)


class ErrorAssertions:
    def assert_error(self, response, status, code):
        self.assertEqual(response.status_code, status, response.content)
        data = json.loads(response.content)
        self.assertEqual(data["error"]["code"], code)
        self.assertEqual(data["request_id"], response["X-Request-ID"])
        self.assertEqual(response["Cache-Control"], "private, no-store")
        if status == 429:
            self.assertGreater(data["error"]["retry_after_ms"], 0)
            self.assertEqual(int(response["Retry-After"]), (data["error"]["retry_after_ms"] + 999) // 1000)
        else:
            self.assertIsNone(data["error"]["retry_after_ms"])
        return data["error"]

    def assert_nothing_created(self):
        self.assertFalse(User.objects.exists())
        self.assertFalse(UserProfile.objects.exists())
        self.assertFalse(Token.objects.exists())


@override_settings(PASSWORD_HASHERS=FAST_HASHERS, SIGNUP_ENABLED=True)
class SignupSuccessTests(ErrorAssertions, TestCase):
    def setUp(self):
        self.client = APIClient()

    def test_creates_account_profile_and_token_like_a_login(self):
        response = post_json(self.client, VALID)
        self.assertEqual(response.status_code, 201, response.content)
        self.assertEqual(set(response.data), {"access_token", "token_type", "user"})
        self.assertEqual(response.data["token_type"], "Bearer")
        self.assertEqual(response["Location"], "http://testserver/api/v1/me/")
        self.assertEqual(response["Cache-Control"], "private, no-store")
        self.assertIn("X-Request-ID", response)
        self.assertEqual(response["Content-Type"], "application/json")

        user = User.objects.get()
        self.assertEqual(user.username, "student01")
        self.assertTrue(user.is_active)
        self.assertFalse(user.is_staff or user.is_superuser)
        self.assertEqual((user.email, user.first_name, user.last_name), ("", "", ""))
        self.assertTrue(user.has_usable_password())
        self.assertTrue(user.check_password(PASSWORD))
        self.assertNotIn(PASSWORD, user.password)
        self.assertNotIn(PASSWORD, response.content.decode())

        profile = UserProfile.objects.get(user=user)
        self.assertEqual(profile.created_via, "signup")
        self.assertEqual(profile.display_name, "청음 연습생")
        self.assertEqual(profile.learning_goal, "college_entrance")
        self.assertEqual(response.data["user"], {"id": str(profile.id), "display_name": "청음 연습생", "learning_goal": "college_entrance"})
        self.assertEqual(Token.objects.get(user=user).key, response.data["access_token"])

    def test_token_works_at_once_and_login_returns_the_same_token_and_profile(self):
        created = post_json(self.client, VALID).data
        client = APIClient()
        client.credentials(HTTP_AUTHORIZATION="Bearer " + created["access_token"])
        me = client.get("/api/v1/me/")
        self.assertEqual(me.status_code, 200)
        self.assertEqual(me.data, created["user"])
        login = post_json(APIClient(), {"username": "student01", "password": PASSWORD}, path=LOGIN)
        self.assertEqual(login.status_code, 200)
        self.assertEqual(login.data, created)

    def test_signup_ignores_a_stale_authorization_header(self):
        self.client.credentials(HTTP_AUTHORIZATION="Bearer stale-token")
        self.assertEqual(post_json(self.client, VALID).status_code, 201)

    def test_learning_goal_is_stored_for_every_choice_without_defaulting(self):
        for index, goal in enumerate(["arts_school_entrance", "arts_school_student", "college_entrance", "teacher_exam", "other"]):
            response = post_json(self.client, form(username=f"goal{index}xx", learning_goal=goal))
            self.assertEqual(response.status_code, 201)
            self.assertEqual(response.data["user"]["learning_goal"], goal)
            self.assertEqual(UserProfile.objects.get(user__username=f"goal{index}xx").learning_goal, goal)

    def test_values_are_stored_without_normalization(self):
        # Decomposed Hangul must stay decomposed; the server never normalizes.
        name = "한 글"
        response = post_json(self.client, form(display_name=name))
        self.assertEqual(response.data["user"]["display_name"], name)
        self.assertEqual(UserProfile.objects.get().display_name, name)

    def test_duplicate_display_names_are_allowed(self):
        self.assertEqual(post_json(self.client, form(username="first_one")).status_code, 201)
        self.assertEqual(post_json(self.client, form(username="second_one")).status_code, 201)

    def test_content_type_parameters_are_still_json(self):
        response = self.client.generic("POST", SIGNUP, json.dumps(VALID), content_type="application/json; charset=utf-8")
        self.assertEqual(response.status_code, 201)

    def test_prior_login_failures_do_not_lock_out_the_new_account(self):
        for _ in range(5):
            self.assert_error(post_json(self.client, {"username": "student01", "password": "wrong"}, path=LOGIN), 401, "INVALID_CREDENTIALS")
        self.assert_error(post_json(self.client, {"username": "student01", "password": PASSWORD}, path=LOGIN), 429, "RATE_LIMITED")
        self.assertEqual(post_json(self.client, VALID).status_code, 201)
        self.assertEqual(post_json(self.client, {"username": "student01", "password": PASSWORD}, path=LOGIN).status_code, 200)

    def test_failed_signup_keeps_login_failures(self):
        for _ in range(5):
            post_json(self.client, {"username": "student01", "password": "wrong"}, path=LOGIN)
        self.assert_error(post_json(self.client, form(password="1234")), 400, "VALIDATION_ERROR")
        self.assertIsNotNone(LoginThrottle.objects.get(key=throttle_key("username", "student01")).blocked_until)

    def test_every_failure_after_the_account_row_leaves_nothing_behind(self):
        stages = ("sori.auth_views.UserProfile.objects.create", "sori.auth_views.Token.objects.create", "sori.auth_views.LoginThrottle.save")
        for stage in stages:
            with self.subTest(stage=stage), patch(stage, side_effect=RuntimeError("injected")):
                with self.assertRaises(RuntimeError):
                    post_json(self.client, VALID)
                self.assert_nothing_created()
                row = LoginThrottle.objects.filter(key=throttle_key("signup-success", "127.0.0.1")).first()
                self.assertEqual(row.events if row else [], [])

    def test_only_the_username_violation_becomes_a_conflict(self):
        with patch("sori.auth_views.Token.objects.create", side_effect=IntegrityError("other constraint")):
            with self.assertRaises(IntegrityError):
                post_json(self.client, VALID)
        self.assert_nothing_created()


@override_settings(PASSWORD_HASHERS=FAST_HASHERS, SIGNUP_ENABLED=True, SIGNUP_MAX_REQUESTS_PER_IP=1000)
class SignupValidationTests(ErrorAssertions, TestCase):
    def setUp(self):
        self.client = APIClient()

    def fields_for(self, body):
        detail = self.assert_error(post_json(self.client, body), 400, "VALIDATION_ERROR")
        self.assert_nothing_created()
        return [(item["field"], item["code"]) for item in detail["fields"]]

    def test_whole_body_errors_have_no_fields_and_skip_other_checks(self):
        cases = ([], None, 3, "text", True, form(extra=True), {"extra": True})
        for body in cases:
            with self.subTest(body=body):
                self.assertEqual(self.fields_for(body), [])
        for raw in (b" ", b"{", b'{"username":', b"\xff\xfe", b"NaN", b'{"username": "\xff"}'):
            with self.subTest(raw=raw):
                detail = self.assert_error(self.client.generic("POST", SIGNUP, raw, content_type="application/json"), 400, "VALIDATION_ERROR")
                self.assertEqual(detail["fields"], [])
        detail = self.assert_error(self.client.generic("POST", SIGNUP, b"", content_type="application/json", CONTENT_LENGTH="0"), 400, "VALIDATION_ERROR")
        self.assertEqual(detail["fields"], [])

    def test_deeply_nested_json_is_a_validation_error(self):
        for raw in (b"[" * 32000, b'{"a":' * 6000):
            detail = self.assert_error(self.client.generic("POST", SIGNUP, raw, content_type="application/json"), 400, "VALIDATION_ERROR")
            self.assertEqual(detail["fields"], [])

    def test_field_code_matrix(self):
        cases = [
            ("username", None, "required"), ("display_name", None, "required"), ("learning_goal", None, "required"), ("password", None, "required"),
            ("username", 1, "invalid"), ("display_name", ["x"], "invalid"), ("learning_goal", 1, "invalid"), ("learning_goal", {}, "invalid"), ("password", False, "invalid"),
            ("username", "", "blank"), ("display_name", "", "blank"), ("learning_goal", "", "blank"), ("password", "", "blank"),
            ("username", "a" * 21, "max_length"), ("display_name", "가" * 21, "max_length"), ("password", "a1-" * 342, "max_length"),
            ("username", "\ud800abc", "invalid"), ("display_name", "\ud800", "invalid"), ("password", "good-\udfffpassword", "invalid"),
            ("username", "abc", "min_length"), ("username", "Ab", "min_length"), ("username", "a", "min_length"),
            ("username", "1abc", "invalid_format"), ("username", "_abc", "invalid_format"), ("username", "Student01", "invalid_format"),
            ("username", "student01\n", "invalid_format"), ("username", "student01 ", "invalid_format"), ("username", " student", "invalid_format"),
            ("username", "stu-dent", "invalid_format"), ("username", "학생학생", "invalid_format"), ("username", "ｓｔｕｄｅｎｔ", "invalid_format"),
            ("username", "abc\u0000", "invalid_format"),
            ("display_name", " 이름", "invalid_format"), ("display_name", "이름 ", "invalid_format"), ("display_name", "　이름", "invalid_format"), ("display_name", "이름 ", "invalid_format"), ("display_name", " ", "invalid_format"),
            ("display_name", "이\n름", "invalid_format"), ("display_name", "이\u0000름", "invalid_format"), ("display_name", "이\u0085름", "invalid_format"), ("display_name", "이 름", "invalid_format"), ("display_name", "이 름", "invalid_format"),
            ("learning_goal", "unknown", "invalid_choice"), ("learning_goal", "OTHER", "invalid_choice"), ("learning_goal", "\ud800", "invalid_choice"),
        ]
        for field, value, code in cases:
            with self.subTest(field=field, value=repr(value), code=code):
                body = without(field) if value is None else form(**{field: value})
                self.assertEqual(self.fields_for(body), [(field, code)])

    def test_length_boundaries_count_code_points(self):
        accepted = [form(username="abcd"), form(username="a" * 20), form(username="a_1_", display_name="x"), form(username="emoji_name", display_name="🎵" * 20)]
        for body in accepted:
            with self.subTest(body=body):
                response = post_json(self.client, body)
                self.assertEqual(response.status_code, 201, response.content)
                User.objects.all().delete()
        long_password = ("Zq7-" * 256)[:1024]
        self.assertEqual(post_json(self.client, form(password=long_password)).status_code, 201)
        self.assertEqual(self.fields_for_after_reset(form(password=long_password + "x")), [("password", "max_length")])

    def fields_for_after_reset(self, body):
        User.objects.all().delete()
        return self.fields_for(body)

    def test_max_length_outranks_unencodable_text(self):
        self.assertEqual(self.fields_for(form(password="\ud800" + "x" * 1024)), [("password", "max_length")])
        self.assertEqual(self.fields_for(form(username="\ud800" + "x" * 20)), [("username", "max_length")])
        self.assertEqual(self.fields_for(form(display_name="\ud800" + "x" * 20)), [("display_name", "max_length")])

    def test_unencodable_outranks_short_username(self):
        self.assertEqual(self.fields_for(form(username="\ud800")), [("username", "invalid")])

    def test_bidi_controls_are_rejected_and_other_format_characters_allowed(self):
        for scalar in (0x061c, 0x200e, 0x200f, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e, 0x2066, 0x2067, 0x2068, 0x2069):
            with self.subTest(scalar=hex(scalar)):
                self.assertEqual(self.fields_for(form(display_name="이" + chr(scalar) + "름")), [("display_name", "invalid_format")])
        for index, name in enumerate(("👩‍🎓", "가​나", "é")):
            with self.subTest(name=repr(name)):
                self.assertEqual(post_json(self.client, form(username=f"format{index}", display_name=name)).status_code, 201)

    def test_every_violated_field_is_returned_in_one_response_with_one_code_each(self):
        body = {"username": "A", "display_name": " x", "learning_goal": "nope", "password": ""}
        self.assertEqual(self.fields_for(body), [
            ("username", "min_length"), ("display_name", "invalid_format"), ("learning_goal", "invalid_choice"), ("password", "blank"),
        ])
        self.assertEqual(self.fields_for({}), [
            ("username", "required"), ("display_name", "required"), ("learning_goal", "required"), ("password", "required"),
        ])

    def test_password_policy_returns_one_error_per_violation_in_policy_order(self):
        self.assertEqual(self.fields_for(form(password="1234")), [
            ("password", "password_too_short"), ("password", "password_too_common"), ("password", "password_entirely_numeric"),
        ])
        self.assertEqual(self.fields_for(form(password="short1x")), [("password", "password_too_short")])
        self.assertEqual(self.fields_for(form(password="password1")), [("password", "password_too_common")])
        self.assertEqual(self.fields_for(form(password="94817263550")), [("password", "password_entirely_numeric")])
        self.assertEqual(self.fields_for(form(password="student01")), [("password", "password_too_similar")])
        self.assertEqual(self.fields_for(form(username="qzxvk", password="qzxvk")), [
            ("password", "password_too_similar"), ("password", "password_too_short"),
        ])

    def test_password_similarity_needs_a_valid_username(self):
        self.assertEqual(self.fields_for(form(username="StudentName1", password="StudentName1")), [("username", "invalid_format")])

    def test_password_similarity_ignores_display_name(self):
        self.assertEqual(post_json(self.client, form(display_name="violetriver77", password="violetriver77")).status_code, 201)

    def test_password_policy_only_runs_after_shape_checks(self):
        with patch("sori.auth_views.validate_password") as policy:
            for password in (None, 1, "", "x" * 1025, "\ud800"):
                self.fields_for(without("password") if password is None else form(password=password))
            policy.assert_not_called()

    def test_password_is_not_trimmed(self):
        password = "  spaced out phrase 8  "
        self.assertEqual(post_json(self.client, form(password=password)).status_code, 201)
        self.assertTrue(User.objects.get().check_password(password))
        self.assertFalse(User.objects.get().check_password(password.strip()))

    def test_unsupported_media_type_and_method(self):
        self.assert_error(self.client.post(SIGNUP, VALID), 415, "UNSUPPORTED_MEDIA_TYPE")
        self.assert_error(self.client.generic("POST", SIGNUP, json.dumps(VALID), content_type="text/plain"), 415, "UNSUPPORTED_MEDIA_TYPE")
        self.assert_error(self.client.generic("POST", SIGNUP, json.dumps(VALID), content_type=""), 415, "UNSUPPORTED_MEDIA_TYPE")
        self.assert_error(self.client.get(SIGNUP), 405, "METHOD_NOT_ALLOWED")
        self.assert_error(self.client.put(SIGNUP, VALID, format="json"), 405, "METHOD_NOT_ALLOWED")
        self.assert_error(self.client.delete(SIGNUP), 405, "METHOD_NOT_ALLOWED")
        self.assert_nothing_created()

    def test_login_shares_the_field_code_order(self):
        cases = [
            ({"username": "x"}, [("password", "required")]),
            ({"username": "x", "password": 1}, [("password", "invalid")]),
            ({"username": "x", "password": ""}, [("password", "blank")]),
            ({"username": "x", "password": "y" * 1025}, [("password", "max_length")]),
            ({"username": "x", "password": "\ud800" + "y" * 1024}, [("password", "max_length")]),
            ({"username": "x", "password": "\ud800"}, [("password", "invalid")]),
            ({"username": "x" * 151, "password": "\ud800"}, [("username", "max_length"), ("password", "invalid")]),
        ]
        for body, expected in cases:
            with self.subTest(body=repr(body)):
                detail = self.assert_error(post_json(self.client, body, path=LOGIN), 400, "VALIDATION_ERROR")
                self.assertEqual([(item["field"], item["code"]) for item in detail["fields"]], expected)
        for raw in (b"{", b"[" * 32000):
            with self.subTest(raw=raw[:8]):
                detail = self.assert_error(self.client.generic("POST", LOGIN, raw, content_type="application/json"), 400, "VALIDATION_ERROR")
                self.assertEqual(detail["fields"], [])
        detail = self.assert_error(self.client.generic("POST", LOGIN, b"", content_type="application/json", CONTENT_LENGTH="0"), 400, "VALIDATION_ERROR")
        self.assertEqual(detail["fields"], [])


@override_settings(PASSWORD_HASHERS=FAST_HASHERS, SIGNUP_ENABLED=True)
class SignupConflictTests(ErrorAssertions, TestCase):
    def setUp(self):
        self.client = APIClient()

    def test_username_taken_shape(self):
        self.assertEqual(post_json(self.client, VALID).status_code, 201)
        detail = self.assert_error(post_json(self.client, form(password="another-pass-55")), 409, "USERNAME_TAKEN")
        self.assertEqual(detail["message"], "이미 사용 중인 아이디입니다.")
        self.assertEqual(detail["fields"], [{"field": "username", "code": "taken", "message": "이미 사용 중인 아이디입니다."}])
        self.assertEqual(User.objects.count(), 1)
        self.assertTrue(User.objects.get().check_password(PASSWORD))

    def test_case_only_differences_conflict_with_admin_accounts(self):
        User.objects.create_user(username="Student01", password="x")
        self.assert_error(post_json(self.client, VALID), 409, "USERNAME_TAKEN")
        self.assertEqual(User.objects.count(), 1)
        self.assertFalse(UserProfile.objects.exists())

    def test_validation_outranks_conflict(self):
        self.assertEqual(post_json(self.client, VALID).status_code, 201)
        detail = self.assert_error(post_json(self.client, form(password="1234")), 400, "VALIDATION_ERROR")
        self.assertEqual({item["field"] for item in detail["fields"]}, {"password"})
        self.assert_error(post_json(self.client, form(password="another-pass-55")), 409, "USERNAME_TAKEN")

    def test_conflict_does_not_hash_the_password(self):
        User.objects.create_user(username="student01", password="x")
        with patch("sori.auth_views.make_password") as hash_password:
            self.assert_error(post_json(self.client, VALID), 409, "USERNAME_TAKEN")
            hash_password.assert_not_called()

    def test_unique_index_race_after_the_precheck_is_a_conflict(self):
        User.objects.create_user(username="student01", password="x")
        with patch("sori.auth_views.usernames_differing_by_case") as check:
            check.return_value.exists.return_value = False
            self.assert_error(post_json(self.client, VALID), 409, "USERNAME_TAKEN")
        self.assertEqual(User.objects.count(), 1)
        self.assertFalse(UserProfile.objects.exists())
        self.assertFalse(Token.objects.exists())
        row = LoginThrottle.objects.filter(key=throttle_key("signup-success", "127.0.0.1")).first()
        self.assertEqual(row.events if row else [], [])

    def test_precheck_agrees_with_the_index_where_iexact_would_not(self):
        # An admin-made U+0131 name is a different account under lower(), so the index allows this.
        User.objects.create_user(username="ıstudent")
        self.assertEqual(post_json(self.client, form(username="istudent")).status_code, 201)

    def test_database_rejects_case_only_duplicates_on_every_path(self):
        User.objects.create_user(username="Student01")
        with self.assertRaises(IntegrityError), transaction.atomic():
            User.objects.create_user(username="student01")
        other = User.objects.create_user(username="other")
        other.username = "STUDENT01"
        with self.assertRaises(IntegrityError), transaction.atomic():
            other.save(update_fields=["username"])
        with self.assertRaises(IntegrityError), transaction.atomic():
            User.objects.filter(pk=other.pk).update(username="sTuDeNt01")

    def test_database_comparison_uses_lower_not_upper(self):
        # U+0131 uppercases to I but lowercases to itself, so iexact would call these equal.
        User.objects.create_user(username="ıstudent")
        self.assertTrue(User.objects.filter(username__iexact="istudent").exists())
        self.assertFalse(usernames_differing_by_case("istudent").exists())
        self.assertTrue(usernames_differing_by_case("ıSTUDENT").exists())
        User.objects.create_user(username="istudent")
        self.assertIn("LOWER", str(usernames_differing_by_case("student").query).upper())


@override_settings(PASSWORD_HASHERS=FAST_HASHERS, SIGNUP_ENABLED=True, SIGNUP_MAX_REQUESTS_PER_IP=30, SIGNUP_MAX_SUCCESSES_PER_IP=20)
class SignupLimitTests(ErrorAssertions, TestCase):
    def setUp(self):
        self.client = APIClient()

    def request_events(self, ip="127.0.0.1"):
        row = LoginThrottle.objects.filter(key=throttle_key("signup", ip)).first()
        return row.events if row else []

    def success_events(self, ip="127.0.0.1"):
        row = LoginThrottle.objects.filter(key=throttle_key("signup-success", ip)).first()
        return row.events if row else []

    def test_disabled_signup_is_403_and_not_counted(self):
        with override_settings(SIGNUP_ENABLED=False):
            detail = self.assert_error(post_json(self.client, VALID), 403, "SIGNUP_DISABLED")
            self.assertEqual(detail["fields"], [])
            self.assert_error(self.client.generic("POST", SIGNUP, b"{", content_type="text/plain"), 403, "SIGNUP_DISABLED")
        self.assertFalse(LoginThrottle.objects.exists())
        self.assert_nothing_created()

    def test_disabled_signup_keeps_login_available(self):
        User.objects.create_user(username="student01", password=PASSWORD)
        with override_settings(SIGNUP_ENABLED=False):
            self.assertEqual(post_json(self.client, {"username": "student01", "password": PASSWORD}, path=LOGIN).status_code, 200)

    def test_body_limit_outranks_everything_and_is_not_counted(self):
        padded = json.dumps(VALID).encode()
        response = self.client.generic("POST", SIGNUP, padded + b" " * (32768 - len(padded)), content_type="application/json")
        self.assertEqual(response.status_code, 201, response.content)
        self.assertEqual(len(self.request_events()), 1)
        for enabled in (True, False):
            for has_length in (True, False):
                with self.subTest(enabled=enabled, has_length=has_length), override_settings(SIGNUP_ENABLED=enabled):
                    request = RequestFactory().generic("POST", SIGNUP, b" " * 32769, content_type="text/plain")
                    if not has_length:
                        request.META.pop("CONTENT_LENGTH", None)
                        request.META["wsgi.input"] = io.BytesIO(b" " * 32769)
                    response = RequestMiddleware(lambda r: self.fail("Oversized body reached the view"))(request)
                    detail = self.assert_error(response, 413, "REQUEST_TOO_LARGE")
                    self.assertEqual(detail["fields"], [])
                    self.assertEqual(detail["message"], "요청 본문은 32 KiB 이하여야 합니다.")
        self.assertEqual(len(self.request_events()), 1)
        LoginThrottle.objects.all().delete()
        with override_settings(SIGNUP_ENABLED=False):
            self.assert_error(self.client.generic("POST", SIGNUP, b" " * 32769, content_type="application/json"), 413, "REQUEST_TOO_LARGE")
        now = timezone.now()
        LoginThrottle.objects.create(key=throttle_key("signup", "127.0.0.1"), events=[now.timestamp()] * 30)
        self.assert_error(self.client.generic("POST", SIGNUP, b" " * 32769, content_type="application/json"), 413, "REQUEST_TOO_LARGE")

    def test_oversized_bodies_are_drained_only_up_to_a_bound(self):
        for has_length in (True, False):
            with self.subTest(has_length=has_length):
                stream = io.BytesIO(b" " * (5 * 1024 * 1024))
                request = RequestFactory().generic("POST", SIGNUP, b"", CONTENT_TYPE="application/json")
                request.META["wsgi.input"] = stream
                request.META.pop("CONTENT_LENGTH", None)
                if has_length:
                    request = WSGIRequest({**request.META, "CONTENT_LENGTH": str(5 * 1024 * 1024)})
                response = RequestMiddleware(lambda r: self.fail("Oversized body reached the view"))(request)
                self.assert_error(response, 413, "REQUEST_TOO_LARGE")
                self.assertGreater(stream.tell(), 1024 * 1024)
                self.assertLess(stream.tell(), 1024 * 1024 + 200 * 1024)

    def test_lengthless_body_at_the_limit_reaches_the_view(self):
        padded = json.dumps(VALID).encode()
        request = RequestFactory().generic("POST", SIGNUP, b"", CONTENT_TYPE="application/json")
        request.META.pop("CONTENT_LENGTH", None)
        request.META["wsgi.input"] = io.BytesIO(padded + b" " * (32768 - len(padded)))
        response = RequestMiddleware(signup)(request)
        response.render()
        self.assertEqual(response.status_code, 201, response.content)

    def test_lengthless_login_reads_its_body(self):
        User.objects.create_user(username="student01", password=PASSWORD)
        request = RequestFactory().generic("POST", LOGIN, b"", CONTENT_TYPE="application/json")
        request.META.pop("CONTENT_LENGTH", None)
        request.META["wsgi.input"] = io.BytesIO(json.dumps({"username": "student01", "password": PASSWORD}).encode())
        response = RequestMiddleware(login)(request)
        response.render()
        self.assertEqual(response.status_code, 200, response.content)

    def test_request_limit_counts_every_allowed_outcome_then_releases(self):
        now = timezone.now()
        with patch("sori.auth_views.timezone.now", return_value=now):
            self.assertEqual(post_json(self.client, VALID).status_code, 201)
            self.assert_error(post_json(self.client, VALID), 409, "USERNAME_TAKEN")
            self.assert_error(post_json(self.client, {}), 400, "VALIDATION_ERROR")
            self.assert_error(self.client.generic("POST", SIGNUP, b"{", content_type="application/json"), 400, "VALIDATION_ERROR")
            self.assert_error(self.client.generic("POST", SIGNUP, b"x", content_type="text/plain"), 415, "UNSUPPORTED_MEDIA_TYPE")
            for _ in range(25):
                self.assert_error(post_json(self.client, {}), 400, "VALIDATION_ERROR")
            self.assertEqual(len(self.request_events()), 30)
            for body, content_type in ((json.dumps(VALID).encode(), "application/json"), (b"{", "application/json"), (b"x", "text/plain")):
                response = self.client.generic("POST", SIGNUP, body, content_type=content_type)
                detail = self.assert_error(response, 429, "RATE_LIMITED")
                self.assertEqual(detail["retry_after_ms"], 300000)
                self.assertEqual(response["Retry-After"], "300")
                self.assertEqual(detail["fields"], [])
            self.assertEqual(len(self.request_events()), 30)
            self.assertEqual(post_json(self.client, form(username="other_ip"), REMOTE_ADDR="10.0.0.9").status_code, 201)
        with patch("sori.auth_views.timezone.now", return_value=now + timedelta(seconds=120)):
            response = post_json(self.client, form(username="waiting"))
            self.assertEqual(response.data["error"]["retry_after_ms"], 180000)
        with patch("sori.auth_views.timezone.now", return_value=now + timedelta(seconds=300)):
            self.assertEqual(post_json(self.client, form(username="released")).status_code, 201)

    def test_blocked_requests_do_not_extend_the_window(self):
        now = timezone.now()
        LoginThrottle.objects.create(key=throttle_key("signup", "127.0.0.1"), events=[now.timestamp() - 200] * 30)
        with patch("sori.auth_views.timezone.now", return_value=now):
            for _ in range(5):
                self.assertEqual(post_json(self.client, VALID).data["error"]["retry_after_ms"], 100000)
        self.assertEqual(self.request_events(), [now.timestamp() - 200] * 30)

    def test_success_limit_blocks_valid_input_for_a_day_then_releases(self):
        now = timezone.now()
        with override_settings(SIGNUP_MAX_SUCCESSES_PER_IP=2), patch("sori.auth_views.timezone.now", return_value=now):
            self.assertEqual(post_json(self.client, form(username="first_one")).status_code, 201)
            self.assertEqual(post_json(self.client, form(username="second_one")).status_code, 201)
            response = post_json(self.client, form(username="third_one"))
            detail = self.assert_error(response, 429, "RATE_LIMITED")
            self.assertEqual(detail["retry_after_ms"], 86400000)
            self.assertEqual(response["Retry-After"], "86400")
            self.assertFalse(User.objects.filter(username="third_one").exists())
            # 400 and 415 also lose to the success limit, and all of them still count as requests.
            self.assert_error(post_json(self.client, {}), 429, "RATE_LIMITED")
            self.assert_error(self.client.generic("POST", SIGNUP, b"x", content_type="text/plain"), 429, "RATE_LIMITED")
            self.assertEqual(len(self.request_events()), 5)
            self.assertEqual(len(self.success_events()), 2)
        with override_settings(SIGNUP_MAX_SUCCESSES_PER_IP=2), patch("sori.auth_views.timezone.now", return_value=now + timedelta(seconds=86400)):
            self.assertEqual(post_json(self.client, form(username="third_one")).status_code, 201)

    def test_final_success_check_runs_under_the_lock_and_creates_nothing(self):
        now = timezone.now()
        LoginThrottle.objects.create(key=throttle_key("signup-success", "127.0.0.1"), events=[now.timestamp()] * 20)
        with patch("sori.auth_views.signup_success_wait", return_value=0):
            self.assert_error(post_json(self.client, VALID), 429, "RATE_LIMITED")
        self.assert_nothing_created()
        self.assertEqual(len(self.success_events()), 20)

    def test_failed_signups_do_not_count_as_successes(self):
        post_json(self.client, {})
        post_json(self.client, form(password="1234"))
        self.assertEqual(self.success_events(), [])
        self.assertEqual(post_json(self.client, VALID).status_code, 201)
        post_json(self.client, VALID)
        self.assertEqual(len(self.success_events()), 1)

    def test_overlapping_limits_return_the_longer_wait(self):
        now = timezone.now()
        LoginThrottle.objects.create(key=throttle_key("signup", "127.0.0.1"), events=[now.timestamp() - 299] * 30)
        LoginThrottle.objects.create(key=throttle_key("signup-success", "127.0.0.1"), events=[now.timestamp() - 3600] * 20)
        with patch("sori.auth_views.timezone.now", return_value=now):
            response = post_json(self.client, VALID)
        self.assert_error(response, 429, "RATE_LIMITED")
        self.assertEqual(response.data["error"]["retry_after_ms"], 82800000)
        self.assertEqual(response["Retry-After"], "82800")

    def test_overlapping_limits_can_also_favor_the_request_limit(self):
        now = timezone.now()
        LoginThrottle.objects.create(key=throttle_key("signup", "127.0.0.1"), events=[now.timestamp() - 1] * 30)
        LoginThrottle.objects.create(key=throttle_key("signup-success", "127.0.0.1"), events=[now.timestamp() - 86300] * 20)
        with patch("sori.auth_views.timezone.now", return_value=now):
            self.assertEqual(post_json(self.client, VALID).data["error"]["retry_after_ms"], 299000)

    def test_lowered_limit_follows_the_common_wait_rule(self):
        now = timezone.now()
        events = [now.timestamp() - age for age in (250, 200, 150, 100, 50)]
        LoginThrottle.objects.create(key=throttle_key("signup", "127.0.0.1"), events=events)
        for limit, wait in ((5, 50000), (3, 150000), (2, 200000), (1, 250000)):
            with self.subTest(limit=limit), override_settings(SIGNUP_MAX_REQUESTS_PER_IP=limit), patch("sori.auth_views.timezone.now", return_value=now):
                self.assertEqual(post_json(self.client, VALID).data["error"]["retry_after_ms"], wait)
        with override_settings(SIGNUP_MAX_REQUESTS_PER_IP=6), patch("sori.auth_views.timezone.now", return_value=now):
            self.assertEqual(post_json(self.client, VALID).status_code, 201)

    def test_lowered_success_limit_follows_the_common_wait_rule(self):
        now = timezone.now()
        LoginThrottle.objects.create(key=throttle_key("signup-success", "127.0.0.1"), events=[now.timestamp() - age for age in (4000, 3000, 2000, 1000)])
        for limit, age in ((4, 4000), (3, 3000), (2, 2000), (1, 1000)):
            with self.subTest(limit=limit), override_settings(SIGNUP_MAX_SUCCESSES_PER_IP=limit), patch("sori.auth_views.timezone.now", return_value=now):
                self.assertEqual(post_json(self.client, VALID).data["error"]["retry_after_ms"], (86400 - age) * 1000)
            LoginThrottle.objects.filter(key=throttle_key("signup", "127.0.0.1")).delete()

    def test_signup_and_login_limits_are_separate(self):
        now = timezone.now()
        LoginThrottle.objects.create(key=throttle_key("ip", "127.0.0.1"), events=[now.timestamp()] * 30)
        LoginThrottle.objects.create(key=throttle_key("username", "student01"), events=[now.timestamp()] * 5, blocked_until=now + timedelta(seconds=300))
        self.assertEqual(post_json(self.client, VALID).status_code, 201)
        self.assert_error(post_json(self.client, {"username": "other", "password": "x"}, path=LOGIN), 429, "RATE_LIMITED")
        LoginThrottle.objects.all().delete()
        LoginThrottle.objects.create(key=throttle_key("signup", "127.0.0.1"), events=[now.timestamp()] * 30)
        before = len(self.request_events())
        self.assertEqual(post_json(self.client, {"username": "student01", "password": PASSWORD}, path=LOGIN).status_code, 200)
        self.assertEqual(len(self.request_events()), before)
        self.assertEqual(len(LoginThrottle.objects.get(key=throttle_key("ip", "127.0.0.1")).events), 1)

    def test_signup_requests_are_not_login_attempts(self):
        post_json(self.client, form(password="1234"))
        post_json(self.client, form(password="another-pass-55"))
        post_json(self.client, form(password="another-pass-55"))
        self.assertFalse(LoginThrottle.objects.filter(key=throttle_key("ip", "127.0.0.1")).exists())
        self.assertFalse(LoginThrottle.objects.filter(key=throttle_key("username", "student01")).exists())

    def test_account_removal_does_not_reduce_the_success_count(self):
        self.assertEqual(post_json(self.client, VALID).status_code, 201)
        User.objects.all().delete()
        self.assertEqual(len(self.success_events()), 1)

    def test_rate_limited_message_is_about_signup(self):
        now = timezone.now()
        LoginThrottle.objects.create(key=throttle_key("signup", "127.0.0.1"), events=[now.timestamp()] * 30)
        self.assertEqual(post_json(self.client, VALID).data["error"]["message"], "잠시 후 다시 가입해 주세요.")


@override_settings(PASSWORD_HASHERS=FAST_HASHERS)
class LoginLimitSettingTests(TestCase):
    def setUp(self):
        self.client = APIClient()

    def attempt(self, **kwargs):
        return post_json(self.client, {"username": "nobody", "password": "x"}, path=LOGIN, **kwargs)

    def test_login_ip_limit_follows_the_setting(self):
        with override_settings(LOGIN_MAX_REQUESTS_PER_IP=2):
            self.assertEqual(self.attempt().status_code, 401)
            self.assertEqual(self.attempt().status_code, 401)
            self.assertEqual(self.attempt().status_code, 429)
        with override_settings(LOGIN_MAX_REQUESTS_PER_IP=3):
            self.assertEqual(self.attempt().status_code, 401)

    def test_login_ip_default_is_thirty(self):
        self.assertEqual(settings.LOGIN_MAX_REQUESTS_PER_IP, 30)
        now = timezone.now()
        LoginThrottle.objects.create(key=throttle_key("ip", "127.0.0.1"), events=[now.timestamp()] * 29)
        self.assertEqual(self.attempt().status_code, 401)
        self.assertEqual(self.attempt().status_code, 429)

    def test_lowered_login_limit_follows_the_common_wait_rule(self):
        now = timezone.now()
        LoginThrottle.objects.create(key=throttle_key("ip", "127.0.0.1"), events=[now.timestamp() - age for age in (250, 200, 150)])
        with override_settings(LOGIN_MAX_REQUESTS_PER_IP=2), patch("sori.auth_views.timezone.now", return_value=now):
            self.assertEqual(self.attempt().data["error"]["retry_after_ms"], 100000)


@override_settings(PASSWORD_HASHERS=FAST_HASHERS, SIGNUP_ENABLED=True, TRUSTED_PROXIES=PROXIES, CLIENT_IP_HEADER="CF-Connecting-IP")
class ClientIpTests(TestCase):
    def key(self, remote, **headers):
        request = RequestFactory().get("/", REMOTE_ADDR=remote, **headers)
        return client_ip_key(request)

    def test_trusted_proxy_header_is_used(self):
        self.assertEqual(self.key("172.30.0.10", HTTP_CF_CONNECTING_IP="203.0.113.7"), "203.0.113.7")
        self.assertEqual(self.key("172.30.0.10", HTTP_CF_CONNECTING_IP="  203.0.113.7 "), "203.0.113.7")

    def test_untrusted_connections_ignore_every_forwarding_header(self):
        self.assertEqual(self.key("198.51.100.1", HTTP_CF_CONNECTING_IP="203.0.113.7", HTTP_X_FORWARDED_FOR="203.0.113.8", HTTP_X_REAL_IP="203.0.113.9"), "198.51.100.1")
        self.assertEqual(self.key("172.30.0.11", HTTP_CF_CONNECTING_IP="203.0.113.7"), "172.30.0.11")

    def test_trusted_proxy_never_uses_x_forwarded_for(self):
        with self.assertLogs("sori.client_ip", "WARNING"):
            self.assertEqual(self.key("172.30.0.10", HTTP_X_FORWARDED_FOR="203.0.113.8"), "172.30.0.10")

    def test_trusted_proxy_with_missing_or_bad_header_uses_remote_addr_and_warns(self):
        for headers in ({}, {"HTTP_CF_CONNECTING_IP": ""}, {"HTTP_CF_CONNECTING_IP": "not-an-ip"}, {"HTTP_CF_CONNECTING_IP": "203.0.113.7, 203.0.113.8"}, {"HTTP_CF_CONNECTING_IP": "203.0.113.0/24"}):
            with self.subTest(headers=headers), self.assertLogs("sori.client_ip", "WARNING") as logs:
                self.assertEqual(self.key("172.30.0.10", **headers), "172.30.0.10")
            for value in headers.values():
                if value:
                    self.assertNotIn(value, "".join(logs.output))

    def test_ipv6_counts_by_64_network(self):
        self.assertEqual(self.key("2001:db8:1:2:aaaa::1"), "2001:db8:1:2::/64")
        self.assertEqual(self.key("2001:db8:1:2:bbbb::2"), "2001:db8:1:2::/64")
        self.assertNotEqual(self.key("2001:db8:1:3::1"), "2001:db8:1:2::/64")
        self.assertEqual(self.key("172.30.0.10", HTTP_CF_CONNECTING_IP="2001:db8:9:9:1::1"), "2001:db8:9:9::/64")

    def test_ipv4_mapped_addresses_count_as_ipv4(self):
        self.assertEqual(self.key("::ffff:198.51.100.1"), "198.51.100.1")
        self.assertEqual(self.key("172.30.0.10", HTTP_CF_CONNECTING_IP="::ffff:203.0.113.7"), "203.0.113.7")
        self.assertEqual(self.key("::ffff:172.30.0.10", HTTP_CF_CONNECTING_IP="203.0.113.7"), "203.0.113.7")

    def test_signup_and_login_count_by_the_resolved_client(self):
        now = timezone.now()
        for kind, limit in (("signup", 30), ("ip", 30)):
            LoginThrottle.objects.create(key=throttle_key(kind, "203.0.113.7"), events=[now.timestamp()] * limit)
        for path, body in ((SIGNUP, VALID), (LOGIN, {"username": "nobody", "password": "x"})):
            with self.subTest(path=path):
                client = APIClient()
                self.assertEqual(post_json(client, body, path=path, REMOTE_ADDR="172.30.0.10", HTTP_CF_CONNECTING_IP="203.0.113.7").status_code, 429)
                self.assertNotEqual(post_json(client, body, path=path, REMOTE_ADDR="172.30.0.10", HTTP_CF_CONNECTING_IP="203.0.113.8").status_code, 429)
                # A direct caller cannot borrow or dodge a limit by forging the header.
                self.assertNotEqual(post_json(client, form(username="directone") if path == SIGNUP else body, path=path, REMOTE_ADDR="198.51.100.1", HTTP_CF_CONNECTING_IP="203.0.113.7").status_code, 429)

    def test_ipv6_clients_share_a_limit_within_their_network(self):
        with override_settings(SIGNUP_MAX_REQUESTS_PER_IP=1):
            client = APIClient()
            self.assertEqual(post_json(client, VALID, REMOTE_ADDR="2001:db8:1:2::1").status_code, 201)
            self.assertEqual(post_json(client, form(username="neighbor"), REMOTE_ADDR="2001:db8:1:2::2").status_code, 429)
            self.assertEqual(post_json(client, form(username="elsewhere"), REMOTE_ADDR="2001:db8:1:3::1").status_code, 201)

    def test_keys_are_keyed_hmacs_of_kind_and_value(self):
        expected = hmac.new(settings.SECRET_KEY.encode(), b"ip\x00203.0.113.7", hashlib.sha256).hexdigest()
        self.assertEqual(throttle_key("ip", "203.0.113.7"), expected)
        self.assertNotEqual(throttle_key("ip", "203.0.113.7"), hashlib.sha256(b"ip\x00203.0.113.7").hexdigest())
        self.assertNotEqual(throttle_key("signup", "203.0.113.7"), expected)
        with override_settings(SECRET_KEY="another-key"):
            self.assertNotEqual(throttle_key("ip", "203.0.113.7"), expected)
        self.assertEqual(len(expected), LoginThrottle._meta.get_field("key").max_length)

    def test_logs_and_stored_rows_never_contain_raw_addresses_or_secrets(self):
        for path, body in ((SIGNUP, VALID), (LOGIN, {"username": "student01", "password": PASSWORD})):
            with self.subTest(path=path), self.assertLogs("sori.auth_views", "INFO") as logs:
                response = post_json(APIClient(), body, path=path, REMOTE_ADDR="172.30.0.10", HTTP_CF_CONNECTING_IP="203.0.113.7")
            output = "".join(logs.output)
            prefix = throttle_key("ip", "203.0.113.7")[:8]
            self.assertIn("ip_key=" + prefix, output)
            for secret in ("203.0.113.7", "172.30.0.10", PASSWORD, response.data["access_token"]):
                self.assertNotIn(secret, output)
        self.assertNotIn("203.0.113.7", json.dumps(list(LoginThrottle.objects.values_list("key", flat=True))))

    def test_different_networks_log_different_prefixes(self):
        self.assertNotEqual(throttle_key("ip", "203.0.113.7")[:8], throttle_key("ip", "203.0.113.8")[:8])


@override_settings(PASSWORD_HASHERS=FAST_HASHERS, SIGNUP_ENABLED=True, TRUSTED_PROXIES=PROXIES, CLIENT_IP_HEADER="CF-Connecting-IP", ALLOWED_HOSTS=["testserver", ".trycloudflare.com", "192.168.0.5"])
class ProxyRequestTests(TestCase):
    PROXY = {"REMOTE_ADDR": "172.30.0.10", "HTTP_CF_CONNECTING_IP": "203.0.113.7"}

    def test_admin_is_hidden_from_proxied_requests_only(self):
        client = Client()
        for path in ("/admin/", "/admin/login/", "/", "/private-media/x"):
            with self.subTest(path=path):
                self.assertEqual(client.get(path, **self.PROXY).status_code, 404)
        self.assertEqual(client.get("/admin/login/", REMOTE_ADDR="127.0.0.1").status_code, 200)
        self.assertEqual(client.get("/admin/login/", REMOTE_ADDR="172.30.0.11", HTTP_CF_CONNECTING_IP="203.0.113.7").status_code, 200)

    def test_proxied_determination_ignores_the_header(self):
        self.assertEqual(Client().get("/admin/login/", REMOTE_ADDR="172.30.0.10").status_code, 404)

    def test_api_and_assets_stay_reachable_through_the_proxy(self):
        client = Client()
        self.assertEqual(client.get("/api/health/", **self.PROXY).status_code, 200)
        self.assertEqual(client.get(AVAILABILITY, **self.PROXY).status_code, 200)
        self.assertEqual(client.get("/assets/sheets/staff-8bars-4-4-v2.png", **self.PROXY).status_code, 200)

    def test_location_and_absolute_urls_use_the_public_origin(self):
        response = post_json(APIClient(), VALID, HTTP_HOST="sori.trycloudflare.com", HTTP_X_FORWARDED_PROTO="https", **self.PROXY)
        self.assertEqual(response.status_code, 201, response.content)
        self.assertEqual(response["Location"], "https://sori.trycloudflare.com/api/v1/me/")
        response = post_json(APIClient(), form(username="direct_one"), HTTP_HOST="192.168.0.5:8000")
        self.assertEqual(response["Location"], "http://192.168.0.5:8000/api/v1/me/")

    def test_question_asset_urls_use_the_public_origin(self):
        call_command("seed_questions", verbosity=0)
        client = APIClient()
        token = post_json(client, VALID).data["access_token"]
        client.credentials(HTTP_AUTHORIZATION="Bearer " + token)
        question = Question.objects.first()
        response = client.get(f"/api/v1/questions/{question.id}/", HTTP_HOST="sori.trycloudflare.com", HTTP_X_FORWARDED_PROTO="https", **self.PROXY)
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.data["score_assets"]["main"]["url"].startswith("https://sori.trycloudflare.com/"))
        self.assertTrue(response.data["sheet_layout"]["template_png_url"].startswith("https://sori.trycloudflare.com/"))


class SignupAvailabilityTests(TestCase):
    def setUp(self):
        self.client = APIClient()

    def test_reflects_the_setting(self):
        for value in (True, False):
            with self.subTest(value=value), override_settings(SIGNUP_ENABLED=value):
                response = self.client.get(AVAILABILITY)
                self.assertEqual(response.status_code, 200)
                self.assertEqual(json.loads(response.content), {"signup_enabled": value})
                self.assertEqual(response["Cache-Control"], "private, no-store")
                self.assertIn("X-Request-ID", response)

    def test_ignores_a_bad_authorization_header(self):
        self.client.credentials(HTTP_AUTHORIZATION="Bearer invalid-token")
        self.assertEqual(self.client.get(AVAILABILITY).status_code, 200)

    def test_is_not_rate_limited_or_counted(self):
        for _ in range(40):
            self.assertEqual(self.client.get(AVAILABILITY).status_code, 200)
        self.assertFalse(LoginThrottle.objects.exists())

    def test_other_methods_are_405(self):
        for response in (self.client.post(AVAILABILITY, {}, format="json"), self.client.put(AVAILABILITY, {}, format="json"), self.client.delete(AVAILABILITY)):
            self.assertEqual(response.status_code, 405)
            self.assertEqual(json.loads(response.content)["error"]["code"], "METHOD_NOT_ALLOWED")


@override_settings(PASSWORD_HASHERS=FAST_HASHERS, SIGNUP_ENABLED=True)
class SignupSecretTests(SimpleTestCase):
    databases = {"default"}

    def test_exception_reports_hide_signup_secrets(self):
        password = uuid.uuid4().hex + "-Secret"
        stages = (
            "rest_framework.parsers.JSONParser.parse",
            "sori.auth_views.validate_password",
            "sori.auth_views.make_password",
            "sori.auth_views.UserProfile.objects.create",
        )
        for debug in (False, True):
            for stage in stages:
                with self.subTest(debug=debug, stage=stage), override_settings(DEBUG=debug), transaction.atomic():
                    request = RequestFactory().post(SIGNUP, json.dumps(form(password=password)), content_type="application/json")
                    with patch(stage, side_effect=RuntimeError("injected signup failure")):
                        try:
                            RequestMiddleware(signup)(request)
                        except RuntimeError:
                            reporter = ExceptionReporter(request, *sys.exc_info())
                            for report in (reporter.get_traceback_html(), reporter.get_traceback_text()):
                                self.assertFalse(password in report, "A signup password was exposed in an exception report.")
                                self.assertIn("injected signup failure", report)
                        else:
                            self.fail("The injected signup exception did not reach the reporter.")
                    transaction.set_rollback(True)


@override_settings(PASSWORD_HASHERS=FAST_HASHERS)
class ThrottlePurgeTests(TestCase):
    def age(self, key, hours, blocked_until=None):
        row = LoginThrottle.objects.create(key=key, blocked_until=blocked_until)
        LoginThrottle.objects.filter(key=key).update(updated_at=timezone.now() - timedelta(hours=hours))
        return row

    def test_purge_removes_only_old_unblocked_rows(self):
        now = timezone.now()
        self.age("old", 25)
        self.age("old-expired-block", 25, now - timedelta(minutes=1))
        self.age("old-active-block", 25, now + timedelta(minutes=1))
        self.age("recent", 23)
        purge_stale_throttles()
        self.assertEqual(set(LoginThrottle.objects.values_list("key", flat=True)), {"old-active-block", "recent"})

    def test_worker_loop_purges(self):
        self.age("old", 25)
        # Closing the connection would end this test's transaction.
        with patch("sori.management.commands.run_grading_worker.close_old_connections"):
            call_command("run_grading_worker", "--once", stdout=io.StringIO())
        self.assertFalse(LoginThrottle.objects.filter(key="old").exists())

    def test_saving_a_row_refreshes_updated_at_on_every_counting_path(self):
        client = APIClient()
        with override_settings(SIGNUP_ENABLED=True):
            post_json(client, VALID)
            post_json(client, {"username": "student01", "password": "wrong"}, path=LOGIN)
        LoginThrottle.objects.update(updated_at=timezone.now() - timedelta(hours=25))
        with override_settings(SIGNUP_ENABLED=True):
            post_json(client, form(username="student02"))
            post_json(client, {"username": "student01", "password": "wrong"}, path=LOGIN)
        purge_stale_throttles()
        keys = set(LoginThrottle.objects.values_list("key", flat=True))
        for kind, value in (("signup", "127.0.0.1"), ("signup-success", "127.0.0.1"), ("ip", "127.0.0.1"), ("username", "student01")):
            self.assertIn(throttle_key(kind, value), keys)

    def test_locked_throttle_recreates_a_row_purged_between_its_queries(self):
        original = LoginThrottle.objects.get_or_create
        calls = []

        def purge_after_lookup(**kwargs):
            result = original(**kwargs)
            if not calls:
                LoginThrottle.objects.filter(**kwargs).delete()
            calls.append(kwargs)
            return result

        with patch.object(LoginThrottle.objects, "get_or_create", side_effect=purge_after_lookup), transaction.atomic():
            row = locked_throttle("ip", "203.0.113.7")
        self.assertEqual(len(calls), 2)
        self.assertEqual(row.key, throttle_key("ip", "203.0.113.7"))
        self.assertTrue(LoginThrottle.objects.filter(key=row.key).exists())


@override_settings(PASSWORD_HASHERS=FAST_HASHERS, AUTH_PASSWORD_VALIDATORS=[])
class AdminPathTests(TestCase):
    def setUp(self):
        self.admin = User.objects.create_superuser(username="root_admin", password="x")
        self.client = Client()
        self.client.force_login(self.admin)

    def change_form(self, user, username):
        return self.client.post(f"/admin/auth/user/{user.pk}/change/", {
            "username": username, "date_joined_0": "2026-01-01", "date_joined_1": "00:00:00",
            "is_active": "on",
        })

    def test_change_form_reports_case_conflicts_instead_of_500(self):
        User.objects.create_user(username="student01")
        other = User.objects.create_user(username="other_user")
        response = self.change_form(other, "Student01")
        self.assertEqual(response.status_code, 200)
        self.assertIn("대소문자만 다른 아이디가 이미 있습니다.", response.content.decode())
        other.refresh_from_db()
        self.assertEqual(other.username, "other_user")

    def test_change_form_allows_changing_own_case_and_free_names(self):
        user = User.objects.create_user(username="other_user")
        self.assertEqual(self.change_form(user, "Other_User").status_code, 302)
        user.refresh_from_db()
        self.assertEqual(user.username, "Other_User")
        self.assertEqual(self.change_form(user, "brand_new").status_code, 302)

    def test_add_form_reports_case_conflicts(self):
        User.objects.create_user(username="student01")
        response = self.client.post("/admin/auth/user/add/", {
            "username": "STUDENT01", "usable_password": "false", "password1": "", "password2": "",
        })
        self.assertEqual(response.status_code, 200)
        self.assertIn("대소문자만 다른 아이디가 이미 있습니다.", response.content.decode())
        self.assertFalse(User.objects.filter(username="STUDENT01").exists())

    def test_profile_list_can_filter_by_how_the_account_was_created(self):
        signup_user = User.objects.create_user(username="joined_user")
        UserProfile.objects.create(user=signup_user, created_via="signup", display_name="가입자")
        admin_user = User.objects.create_user(username="made_by_admin")
        UserProfile.objects.create(user=admin_user, display_name="관리계정")
        response = self.client.get("/admin/sori/userprofile/?created_via__exact=signup")
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "joined_user")
        self.assertNotContains(response, "made_by_admin")

    def test_deactivating_a_signup_account_revokes_login_and_token(self):
        client = APIClient()
        with override_settings(SIGNUP_ENABLED=True):
            created = post_json(client, VALID).data
        user = User.objects.get(username="student01")
        response = self.client.post(f"/admin/auth/user/{user.pk}/change/", {
            "username": "student01", "date_joined_0": "2026-01-01", "date_joined_1": "00:00:00",
        })
        self.assertEqual(response.status_code, 302)
        self.assertFalse(Token.objects.filter(key=created["access_token"]).exists())
        self.assertEqual(post_json(APIClient(), {"username": "student01", "password": PASSWORD}, path=LOGIN).status_code, 401)
        client.credentials(HTTP_AUTHORIZATION="Bearer " + created["access_token"])
        self.assertEqual(client.get("/api/v1/me/").status_code, 401)


@override_settings(PASSWORD_HASHERS=FAST_HASHERS)
class ManagementCommandTests(TestCase):
    def create(self, username, password="new-secure-phrase-7", display_name=None):
        options = {"display_name": display_name} if display_name else {}
        with patch("sori.management.commands.create_practice_user.getpass", side_effect=[password, password]) as prompt:
            call_command("create_practice_user", username, stdout=io.StringIO(), **options)
        return prompt

    def test_records_admin_and_can_still_reset_admin_accounts(self):
        self.create("teacher01")
        profile = UserProfile.objects.get(user__username="teacher01")
        self.assertEqual(profile.created_via, "admin")
        self.create("teacher01", password="another-secure-phrase-8", display_name="새 이름")
        profile.refresh_from_db()
        self.assertEqual(profile.display_name, "새 이름")
        self.assertTrue(User.objects.get(username="teacher01").check_password("another-secure-phrase-8"))

    def test_issue_dev_token_records_admin(self):
        with tempfile.TemporaryDirectory() as directory:
            call_command("issue_dev_token", "--username", "ipad-dev", "--output", str(Path(directory) / "c.txt"), stdout=io.StringIO())
        self.assertEqual(UserProfile.objects.get(user__username="ipad-dev").created_via, "admin")

    def test_refuses_to_reset_a_signup_account(self):
        with override_settings(SIGNUP_ENABLED=True):
            created = post_json(APIClient(), VALID).data
        with patch("sori.management.commands.create_practice_user.getpass") as prompt, self.assertRaises(CommandError):
            call_command("create_practice_user", "student01", "--display-name", "탈취", stdout=io.StringIO())
        prompt.assert_not_called()
        user = User.objects.get(username="student01")
        self.assertTrue(user.check_password(PASSWORD))
        self.assertEqual(UserProfile.objects.get(user=user).display_name, "청음 연습생")
        self.assertTrue(Token.objects.filter(key=created["access_token"]).exists())

    def test_refuses_case_only_duplicates(self):
        self.create("Teacher01")
        with self.assertRaises(CommandError):
            self.create("teacher01")
        self.assertEqual(User.objects.count(), 1)

    def test_signup_winning_the_race_after_the_first_check_is_still_refused(self):
        def signup_during_prompt(prompt):
            if prompt == "비밀번호: ":
                with override_settings(SIGNUP_ENABLED=True):
                    self.assertEqual(post_json(APIClient(), VALID).status_code, 201)
            return "new-secure-phrase-7"

        with patch("sori.management.commands.create_practice_user.getpass", side_effect=signup_during_prompt), self.assertRaises(CommandError):
            call_command("create_practice_user", "student01", stdout=io.StringIO())
        self.assertTrue(User.objects.get(username="student01").check_password(PASSWORD))


class MigrationCheckTests(TestCase):
    def test_refuses_case_duplicates_and_explains_the_fix(self):
        migration = importlib.import_module("sori.migrations.0003_signup")
        with connection.cursor() as cursor:
            cursor.execute("DROP INDEX sori_auth_user_username_lower")
        User.objects.create_user(username="Student01")
        User.objects.create_user(username="student01")
        with self.assertRaises(CommandError) as raised:
            migration.refuse_case_duplicates(None, SimpleNamespace(connection=connection))
        message = str(raised.exception)
        self.assertIn("Student01", message)
        self.assertIn("student01", message)
        self.assertIn("admin에서 한쪽 아이디를 바꾼 뒤 다시 시작하세요", message)

    def test_passes_without_duplicates(self):
        migration = importlib.import_module("sori.migrations.0003_signup")
        User.objects.create_user(username="Student01")
        User.objects.create_user(username="other")
        migration.refuse_case_duplicates(None, SimpleNamespace(connection=connection))


class MigrationUpgradeTests(TransactionTestCase):
    def tearDown(self):
        executor = MigrationExecutor(connection)
        executor.migrate(executor.loader.graph.leaf_nodes())

    def before(self):
        executor = MigrationExecutor(connection)
        executor.migrate([("sori", "0002_login"), ("auth", "0012_alter_user_first_name_max_length")])
        return executor.loader.project_state([("sori", "0002_login"), ("auth", "0012_alter_user_first_name_max_length")]).apps

    def latest(self):
        executor = MigrationExecutor(connection)
        executor.migrate(executor.loader.graph.leaf_nodes())

    def test_existing_profiles_become_admin_and_the_index_appears(self):
        apps = self.before()
        OldUser = apps.get_model("auth", "User")
        user = OldUser.objects.create(username="legacy", password="x")
        apps.get_model("sori", "UserProfile").objects.create(user=user, display_name="기존 사용자")
        apps.get_model("sori", "LoginThrottle").objects.create(key="legacy-row")
        self.latest()
        self.assertEqual(UserProfile.objects.get(user__username="legacy").created_via, "admin")
        self.assertIsNotNone(LoginThrottle.objects.get(key="legacy-row").updated_at)
        with self.assertRaises(IntegrityError), transaction.atomic():
            User.objects.create_user(username="LEGACY")

    def test_upgrade_stops_on_case_duplicates_and_leaves_no_partial_change(self):
        apps = self.before()
        OldUser = apps.get_model("auth", "User")
        OldUser.objects.create(username="Student01", password="x")
        OldUser.objects.create(username="student01", password="x")
        with self.assertRaises(CommandError):
            self.latest()
        with connection.cursor() as cursor:
            columns = [column.name for column in connection.introspection.get_table_description(cursor, "sori_userprofile")]
        self.assertNotIn("created_via", columns)
        OldUser.objects.filter(username="Student01").update(username="student02")
        self.latest()
        with connection.cursor() as cursor:
            columns = [column.name for column in connection.introspection.get_table_description(cursor, "sori_userprofile")]
        self.assertIn("created_via", columns)


class SettingsValidationTests(SimpleTestCase):
    BASE = {
        "DJANGO_SECRET_KEY": "settings-test-key", "DJANGO_DEBUG": "false",
        "SIGNUP_ENABLED": "", "LOGIN_MAX_REQUESTS_PER_IP": "", "SIGNUP_MAX_REQUESTS_PER_IP": "", "SIGNUP_MAX_SUCCESSES_PER_IP": "",
        "AI_MAX_JOBS_PER_USER_PER_DAY": "", "AI_MAX_JOBS_PER_DAY": "", "TRUSTED_PROXIES": "", "CLIENT_IP_HEADER": "",
    }

    def load(self, **values):
        code = (
            "import json, config.settings as s; print(json.dumps({"
            "'signup': s.SIGNUP_ENABLED, 'login': s.LOGIN_MAX_REQUESTS_PER_IP, 'requests': s.SIGNUP_MAX_REQUESTS_PER_IP,"
            "'successes': s.SIGNUP_MAX_SUCCESSES_PER_IP, 'user': s.AI_MAX_JOBS_PER_USER_PER_DAY, 'day': s.AI_MAX_JOBS_PER_DAY,"
            "'proxies': [str(p) for p in s.TRUSTED_PROXIES], 'header': s.CLIENT_IP_HEADER}))"
        )
        return subprocess.run([sys.executable, "-c", code], cwd=settings.BASE_DIR, env={**os.environ, **self.BASE, **values}, capture_output=True, text=True)

    def assert_refused(self, name, **values):
        result = self.load(**values)
        self.assertNotEqual(result.returncode, 0, values)
        self.assertIn("ImproperlyConfigured", result.stderr)
        self.assertIn(name, result.stderr)

    def test_defaults(self):
        result = self.load()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"signup": False, "login": 30, "requests": 30, "successes": 20, "user": None, "day": None, "proxies": [], "header": ""})

    def test_signup_enabled_accepts_only_case_insensitive_true(self):
        for value, expected in (("true", True), ("TRUE", True), ("True", True), ("1", False), ("yes", False), ("on", False), ("", False), ("false", False)):
            with self.subTest(value=value):
                result = self.load(SIGNUP_ENABLED=value, AI_MAX_JOBS_PER_USER_PER_DAY="1", AI_MAX_JOBS_PER_DAY="1")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["signup"], expected)

    def test_signup_requires_both_ai_limits(self):
        self.assert_refused("AI_MAX_JOBS_PER_USER_PER_DAY", SIGNUP_ENABLED="true")
        self.assert_refused("AI_MAX_JOBS_PER_USER_PER_DAY", SIGNUP_ENABLED="true", AI_MAX_JOBS_PER_DAY="30")
        self.assert_refused("AI_MAX_JOBS_PER_DAY", SIGNUP_ENABLED="true", AI_MAX_JOBS_PER_USER_PER_DAY="10")
        self.assert_refused("AI_MAX_JOBS_PER_DAY", SIGNUP_ENABLED="true", AI_MAX_JOBS_PER_USER_PER_DAY="10", AI_MAX_JOBS_PER_DAY="0")
        self.assertEqual(self.load(SIGNUP_ENABLED="true", AI_MAX_JOBS_PER_USER_PER_DAY="10", AI_MAX_JOBS_PER_DAY="30").returncode, 0)

    def test_counts_must_be_integers_of_at_least_one(self):
        for name in ("LOGIN_MAX_REQUESTS_PER_IP", "SIGNUP_MAX_REQUESTS_PER_IP", "SIGNUP_MAX_SUCCESSES_PER_IP", "AI_MAX_JOBS_PER_USER_PER_DAY", "AI_MAX_JOBS_PER_DAY"):
            for value in ("0", "-1", "abc", "1.5", "1_000", "٣"):
                with self.subTest(name=name, value=value):
                    self.assert_refused(name, **{name: value})

    def test_blank_counts_use_defaults_and_values_apply(self):
        result = self.load(LOGIN_MAX_REQUESTS_PER_IP=" ", SIGNUP_MAX_REQUESTS_PER_IP="7", SIGNUP_MAX_SUCCESSES_PER_IP="1")
        values = json.loads(result.stdout)
        self.assertEqual((values["login"], values["requests"], values["successes"]), (30, 7, 1))

    def test_trusted_proxy_settings_are_validated_and_paired(self):
        result = self.load(TRUSTED_PROXIES="172.30.0.10/32, 2001:db8::/64", CLIENT_IP_HEADER="CF-Connecting-IP")
        self.assertEqual(json.loads(result.stdout)["proxies"], ["172.30.0.10/32", "2001:db8::/64"])
        self.assert_refused("TRUSTED_PROXIES", TRUSTED_PROXIES="not-a-cidr", CLIENT_IP_HEADER="CF-Connecting-IP")
        self.assert_refused("TRUSTED_PROXIES", TRUSTED_PROXIES="172.30.0.10/33", CLIENT_IP_HEADER="CF-Connecting-IP")
        self.assert_refused("TRUSTED_PROXIES", TRUSTED_PROXIES="172.30.0.10/32")
        self.assert_refused("TRUSTED_PROXIES", CLIENT_IP_HEADER="CF-Connecting-IP")


@override_settings(PASSWORD_HASHERS=FAST_HASHERS, SIGNUP_ENABLED=True)
class SignupConcurrencyTests(TransactionTestCase):
    def in_connection(self, operation):
        close_old_connections()
        try:
            return operation()
        finally:
            connection.close()

    def test_same_username_from_many_addresses_has_one_winner(self):
        barrier = Barrier(8)

        def attempt(index):
            barrier.wait(10)
            return post_json(APIClient(), VALID, REMOTE_ADDR=f"10.0.0.{index + 1}")

        with ThreadPoolExecutor(max_workers=8) as pool:
            responses = list(pool.map(lambda index: self.in_connection(lambda: attempt(index)), range(8)))
        self.assertEqual(sorted(r.status_code for r in responses), [201] + [409] * 7)
        self.assertEqual(User.objects.count(), 1)
        self.assertEqual(UserProfile.objects.count(), 1)
        self.assertEqual(Token.objects.count(), 1)
        winner = next(r for r in responses if r.status_code == 201)
        self.assertEqual(Token.objects.get().key, winner.data["access_token"])
        for response in responses:
            if response.status_code == 409:
                self.assertEqual(response.data["error"]["fields"][0]["code"], "taken")

    def test_case_variant_cannot_slip_in_concurrently(self):
        User.objects.create_user(username="Student01")
        with ThreadPoolExecutor(max_workers=4) as pool:
            responses = list(pool.map(lambda _: self.in_connection(lambda: post_json(APIClient(), VALID)), range(4)))
        self.assertEqual([r.status_code for r in responses], [409] * 4)
        self.assertEqual(User.objects.count(), 1)

    @override_settings(SIGNUP_MAX_SUCCESSES_PER_IP=3, SIGNUP_MAX_REQUESTS_PER_IP=1000)
    def test_same_ip_cannot_exceed_the_success_limit_concurrently(self):
        barrier = Barrier(10)

        def attempt(index):
            barrier.wait(10)
            return post_json(APIClient(), form(username=f"racer{index:02d}"))

        with ThreadPoolExecutor(max_workers=10) as pool:
            responses = list(pool.map(lambda index: self.in_connection(lambda: attempt(index)), range(10)))
        self.assertEqual(sorted(r.status_code for r in responses), [201] * 3 + [429] * 7)
        self.assertEqual(User.objects.count(), 3)
        self.assertEqual(UserProfile.objects.count(), 3)
        self.assertEqual(Token.objects.count(), 3)
        self.assertEqual(len(LoginThrottle.objects.get(key=throttle_key("signup-success", "127.0.0.1")).events), 3)

    @override_settings(SIGNUP_MAX_REQUESTS_PER_IP=5)
    def test_request_counter_is_atomic(self):
        barrier = Barrier(8)

        def attempt(_):
            barrier.wait(10)
            return post_json(APIClient(), {})

        with ThreadPoolExecutor(max_workers=8) as pool:
            responses = list(pool.map(lambda index: self.in_connection(lambda: attempt(index)), range(8)))
        self.assertEqual(sorted(r.status_code for r in responses), [400] * 5 + [429] * 3)
        self.assertEqual(len(LoginThrottle.objects.get(key=throttle_key("signup", "127.0.0.1")).events), 5)

    def test_login_racing_a_signup_of_that_username_never_errors(self):
        barrier = Barrier(6)

        def signup_once():
            barrier.wait(10)
            return post_json(APIClient(), VALID)

        def login_once():
            barrier.wait(10)
            return post_json(APIClient(), {"username": "student01", "password": PASSWORD}, path=LOGIN)

        with ThreadPoolExecutor(max_workers=6) as pool:
            futures = [pool.submit(self.in_connection, signup_once)] + [pool.submit(self.in_connection, login_once) for _ in range(5)]
            responses = [future.result(20) for future in futures]
        self.assertEqual(responses[0].status_code, 201)
        for response in responses[1:]:
            self.assertIn(response.status_code, (200, 401))
        self.assertEqual(post_json(APIClient(), {"username": "student01", "password": PASSWORD}, path=LOGIN).data["access_token"], responses[0].data["access_token"])
