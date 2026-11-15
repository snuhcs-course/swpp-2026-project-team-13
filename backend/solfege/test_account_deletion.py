import io
import json
import tempfile
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Event
from types import SimpleNamespace
from unittest.mock import patch

from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.files.storage import default_storage
from django.core.management import call_command
from django.core.management.base import CommandError
from django.db import IntegrityError, close_old_connections, connection
from django.db.models import F
from django.test import RequestFactory, TestCase, TransactionTestCase, override_settings
from PIL import Image
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from .accounts import delete_account
from .errors import exception_handler
from .grading import execute_job
from .models import Answer, Attempt, GradingJob, IdempotencyRecord, LoginThrottle, QuestionVersion, SelfAssessmentRevision, UserProfile, throttle_key
from . import auth_views, views

ME = "/api/v1/me/"
FAST_HASHERS = ["django.contrib.auth.hashers.MD5PasswordHasher"]
User = get_user_model()


def png_bytes():
    buffer = io.BytesIO()
    Image.new("RGB", (2660, 1692), "white").save(buffer, "PNG")
    return buffer.getvalue()


PNG = png_bytes()


class TemporaryMedia:
    @classmethod
    def setUpClass(cls):
        cls.media_directory = tempfile.TemporaryDirectory(prefix="solfege-tests-", dir=settings.FILE_UPLOAD_TEMP_DIR)
        cls.media_override = override_settings(MEDIA_ROOT=cls.media_directory.name)
        cls.media_override.enable()
        super().setUpClass()

    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        cls.media_override.disable()
        cls.media_directory.cleanup()


class AccountFlow:
    def account(self, username="learner", **options):
        user = User.objects.create_user(username=username, **options)
        UserProfile.objects.create(user=user, created_via="signup")
        client = APIClient()
        client.credentials(HTTP_AUTHORIZATION="Bearer " + Token.objects.create(user=user).key)
        return user, client

    def post(self, client, path, data=None):
        return client.post("/api/v1/" + path, data, format="json", HTTP_IDEMPOTENCY_KEY=str(uuid.uuid4()))

    def started_attempt(self, client, mode="exam"):
        response = client.get("/api/v1/questions/" if mode == "practice" else "/api/v1/questions/recommended/")
        self.assertEqual(response.status_code, 200, response.data)
        question = response.data["results"][0] if mode == "practice" else response.data
        attempt = self.post(client, "attempts/", {"question_id": question["id"], "question_version": question["version"], "mode": mode})
        self.assertEqual(attempt.status_code, 201, attempt.data)
        self.assertEqual(self.post(client, f'attempts/{attempt.data["id"]}/start/').status_code, 200)
        return attempt.data

    def uploaded(self, client, attempt):
        file = io.BytesIO(PNG)
        file.name = "answer.png"
        answer = client.post(f'/api/v1/attempts/{attempt["id"]}/answers/', {
            "image": file, "client_answer_id": str(uuid.uuid4()), "answer_format_version": "1",
            "sheet_layout_id": attempt["question"]["sheet_layout"]["id"],
        }, format="multipart", HTTP_IDEMPOTENCY_KEY=str(uuid.uuid4()))
        self.assertEqual(answer.status_code, 201, answer.data)
        return answer.data

    def submitted(self, client):
        attempt = self.started_attempt(client)
        answer = self.uploaded(client, attempt)
        response = self.post(client, f'attempts/{attempt["id"]}/submit/', {"answer_id": answer["id"]})
        self.assertEqual(response.status_code, 202, response.data)
        return attempt, answer

    def assert_owns_nothing(self, user_id):
        self.assertFalse(User.objects.filter(pk=user_id).exists())
        self.assertFalse(UserProfile.objects.filter(user_id=user_id).exists())
        self.assertFalse(Token.objects.filter(user_id=user_id).exists())
        self.assertFalse(Attempt.objects.filter(user_id=user_id).exists())
        self.assertFalse(SelfAssessmentRevision.objects.filter(attempt__user_id=user_id).exists())
        self.assertFalse(IdempotencyRecord.objects.filter(user_id=user_id).exists())

    def assert_unauthorized(self, response):
        self.assertEqual(response.status_code, 401, getattr(response, "data", None))
        self.assertEqual(response.data["error"]["code"], "AUTHENTICATION_REQUIRED")
        self.assertEqual(response["WWW-Authenticate"], "Bearer")


class SelfAssessmentDeletionTests(AccountFlow, TemporaryMedia, TestCase):
    def setUp(self):
        call_command("seed_questions", verbosity=0)

    def test_account_with_practice_self_assessment_is_deleted(self):
        user, client = self.account()
        user_id = user.pk
        attempt = Attempt.objects.get(pk=self.started_attempt(client)["id"])
        SelfAssessmentRevision.objects.create(attempt=attempt, revision=1, errors=[], completed=False)
        response = client.delete(ME)
        self.assertEqual(response.status_code, 204, getattr(response, "data", None))
        self.assert_owns_nothing(user_id)


class AccountDeletionTests(AccountFlow, TemporaryMedia, TestCase):
    @classmethod
    def setUpTestData(cls):
        call_command("seed_questions", verbosity=0)

    def delete(self, client, *args, **kwargs):
        with self.captureOnCommitCallbacks(execute=True):
            return client.delete(ME, *args, **kwargs)

    def test_204_removes_the_account_records_and_image_files(self):
        user, client = self.account()
        attempt, answer = self.submitted(client)
        # Pending AI grading and a Practice draft may coexist; a second Exam may not.
        draft = self.started_attempt(client, mode="practice")
        self.uploaded(client, draft)
        self.assertEqual(draft["mode"], "practice")
        self.assertEqual(GradingJob.objects.get(attempt_id=attempt["id"]).status, "queued")
        names = list(Answer.objects.values_list("image", flat=True))
        self.assertEqual(len(names), 2)
        self.assertTrue(all(default_storage.exists(name) for name in names))
        LoginThrottle.objects.create(key=throttle_key("username", user.username), events=[1.0])
        user_id = user.pk
        response = self.delete(client)
        self.assertEqual(response.status_code, 204)
        self.assertEqual(response.content, b"")
        self.assertEqual(response["Cache-Control"], "private, no-store")
        self.assertTrue(response["X-Request-ID"])
        self.assert_owns_nothing(user_id)
        self.assertFalse(Answer.objects.exists())
        self.assertFalse(GradingJob.objects.exists())
        self.assertFalse(LoginThrottle.objects.filter(key=throttle_key("username", "learner")).exists())
        self.assertFalse(any(default_storage.exists(name) for name in names))

    def test_account_with_no_learning_records_is_deleted(self):
        user, client = self.account()
        user_id = user.pk
        self.assertEqual(self.delete(client).status_code, 204)
        self.assert_owns_nothing(user_id)

    def test_previous_token_is_rejected_after_deletion(self):
        _, client = self.account()
        self.assertEqual(self.delete(client).status_code, 204)
        for response in (client.get(ME), client.delete(ME), client.post("/api/v1/auth/logout/")):
            self.assert_unauthorized(response)

    def test_missing_or_invalid_token_deletes_nothing(self):
        user, _ = self.account()
        anonymous = APIClient()
        self.assert_unauthorized(anonymous.delete(ME))
        anonymous.credentials(HTTP_AUTHORIZATION="Bearer not-a-real-token")
        self.assert_unauthorized(anonymous.delete(ME))
        self.assertTrue(User.objects.filter(pk=user.pk).exists())

    def test_admin_accounts_are_refused_and_keep_everything(self):
        for name, options in (("staffer", {"is_staff": True}), ("rootuser", {"is_superuser": True})):
            with self.subTest(name):
                user, client = self.account(name, **options)
                attempt, _ = self.submitted(client)
                response = self.delete(client)
                self.assertEqual(response.status_code, 403)
                self.assertEqual(response.data["error"]["code"], "ACCOUNT_DELETION_NOT_ALLOWED")
                self.assertTrue(response["X-Request-ID"])
                self.assertTrue(Token.objects.filter(user=user).exists())
                self.assertTrue(Attempt.objects.filter(id=attempt["id"]).exists())
                self.assertEqual(client.get(ME).status_code, 200)

    def test_token_is_checked_before_the_admin_refusal(self):
        User.objects.create_user("staffer", is_staff=True)
        self.assert_unauthorized(APIClient().delete(ME))

    def test_body_and_content_type_are_ignored(self):
        cases = [
            (b"{broken", "application/json"),
            (b"[1, 2]", "application/json"),
            (b"plain", "text/plain"),
            (json.dumps({"password": "wrong"}).encode(), "application/json"),
            (b"x" * 40000, "application/octet-stream"),
        ]
        for index, (body, content_type) in enumerate(cases):
            with self.subTest(content_type=content_type, size=len(body)):
                user, client = self.account(f"learner{index}")
                user_id = user.pk
                with self.captureOnCommitCallbacks(execute=True):
                    response = client.generic("DELETE", ME, body, content_type=content_type)
                self.assertEqual(response.status_code, 204)
                self.assert_owns_nothing(user_id)

    def test_other_accounts_are_untouched(self):
        victim, victim_client = self.account("victim01")
        other, other_client = self.account("other001")
        attempt, _ = self.submitted(other_client)
        self.submitted(victim_client)
        throttle = LoginThrottle.objects.create(key=throttle_key("username", other.username), events=[1.0])
        image = Answer.objects.get(attempt_id=attempt["id"]).image.name
        self.assertEqual(self.delete(victim_client).status_code, 204)
        self.assertEqual(other_client.get(ME).status_code, 200)
        self.assertEqual(other_client.get(f'/api/v1/attempts/{attempt["id"]}/').status_code, 200)
        self.assertTrue(GradingJob.objects.filter(attempt_id=attempt["id"]).exists())
        self.assertTrue(default_storage.exists(image))
        throttle.refresh_from_db()
        self.assertEqual(throttle.events, [1.0])

    @override_settings(PASSWORD_HASHERS=FAST_HASHERS, SIGNUP_ENABLED=True, SIGNUP_MAX_SUCCESSES_PER_IP=20, SIGNUP_MAX_REQUESTS_PER_IP=30)
    def test_username_can_sign_up_again_with_a_new_identity(self):
        form = {"username": "student01", "display_name": "연습생", "learning_goal": "other", "password": "quiet-lantern-48"}
        first = APIClient().post("/api/v1/auth/signup/", form, format="json")
        self.assertEqual(first.status_code, 201, first.data)
        client = APIClient()
        client.credentials(HTTP_AUTHORIZATION="Bearer " + first.data["access_token"])
        self.submitted(client)
        self.assertEqual(self.delete(client).status_code, 204)
        login = APIClient().post("/api/v1/auth/login/", {"username": "student01", "password": form["password"]}, format="json")
        self.assertEqual(login.status_code, 401)
        second = APIClient().post("/api/v1/auth/signup/", form, format="json")
        self.assertEqual(second.status_code, 201, second.data)
        self.assertNotEqual(second.data["user"]["id"], first.data["user"]["id"])
        self.assertNotEqual(second.data["access_token"], first.data["access_token"])
        fresh = APIClient()
        fresh.credentials(HTTP_AUTHORIZATION="Bearer " + second.data["access_token"])
        self.assertEqual(fresh.get("/api/v1/attempts/" + str(uuid.uuid4()) + "/").status_code, 404)
        self.assertFalse(Attempt.objects.exists())

    @override_settings(SIGNUP_ENABLED=True, PASSWORD_HASHERS=FAST_HASHERS, SIGNUP_MAX_SUCCESSES_PER_IP=1, SIGNUP_MAX_REQUESTS_PER_IP=30)
    def test_deletion_does_not_give_back_a_signup_success(self):
        form = {"username": "student01", "display_name": "연습생", "learning_goal": "other", "password": "quiet-lantern-48"}
        first = APIClient().post("/api/v1/auth/signup/", form, format="json")
        client = APIClient()
        client.credentials(HTTP_AUTHORIZATION="Bearer " + first.data["access_token"])
        self.assertEqual(self.delete(client).status_code, 204)
        self.assertEqual(APIClient().post("/api/v1/auth/signup/", form, format="json").status_code, 429)

    def test_account_without_a_usable_password_can_be_deleted_with_its_token(self):
        # Created this way because changing a password revokes the token.
        user, client = self.account(password=None)
        self.assertFalse(user.has_usable_password())
        user_id = user.pk
        self.assertEqual(self.delete(client).status_code, 204)
        self.assert_owns_nothing(user_id)

    def test_other_methods_on_me_still_use_the_contract_error(self):
        _, client = self.account()
        response = client.post(ME, {}, format="json")
        self.assertEqual(response.status_code, 405)
        self.assertEqual(response.data["error"]["code"], "METHOD_NOT_ALLOWED")
        self.assertIn("DELETE", response["Allow"])
        self.assertEqual(client.get(ME).status_code, 200)
        self.assertEqual(client.patch(ME, {"learning_goal": "other"}, format="json").status_code, 200)

    def test_failure_partway_leaves_everything_in_place(self):
        user, client = self.account()
        attempt, _ = self.submitted(client)
        image = Answer.objects.get().image.name
        client.raise_request_exception = False
        with patch("solfege.accounts.throttle_key", side_effect=RuntimeError("boom")), self.captureOnCommitCallbacks(execute=True) as callbacks:
            response = client.delete(ME)
        self.assertEqual(response.status_code, 500)
        self.assertEqual(callbacks, [])
        self.assertTrue(User.objects.filter(pk=user.pk).exists())
        refreshed = Attempt.objects.get(id=attempt["id"])
        self.assertIsNotNone(refreshed.current_job_id)
        self.assertIsNotNone(refreshed.submitted_answer_id)
        self.assertEqual(GradingJob.objects.count(), 1)
        self.assertTrue(default_storage.exists(image))
        self.assertEqual(client.get(ME).status_code, 200)

    def test_image_deletion_failure_keeps_204_and_logs_the_request_and_path(self):
        user, client = self.account()
        self.submitted(client)
        image = Answer.objects.get().image.name
        user_id = user.pk
        with patch("solfege.accounts.default_storage.delete", side_effect=OSError("disk")), self.assertLogs("solfege.accounts", "ERROR") as logs:
            response = self.delete(client)
        self.assertEqual(response.status_code, 204)
        self.assert_owns_nothing(user_id)
        output = "\n".join(logs.output)
        self.assertIn(image, output)
        self.assertIn(response["X-Request-ID"], output)

    def test_image_files_outlive_the_transaction(self):
        _, client = self.account()
        self.submitted(client)
        image = Answer.objects.get().image.name
        with self.captureOnCommitCallbacks() as callbacks:
            self.assertEqual(client.delete(ME).status_code, 204)
        self.assertTrue(default_storage.exists(image))
        self.assertEqual(len(callbacks), 1)
        callbacks[0]()
        self.assertFalse(default_storage.exists(image))

    def test_second_deletion_reports_false(self):
        user, _ = self.account()
        stale = User.objects.get(pk=user.pk)
        self.assertTrue(delete_account(user))
        self.assertFalse(delete_account(stale))

    def test_deletion_lost_to_another_request_is_401(self):
        _, client = self.account()
        with patch("solfege.views.delete_account", return_value=False):
            self.assert_unauthorized(client.delete(ME))

    def test_proxied_requests_can_delete(self):
        user, client = self.account()
        user_id = user.pk
        self.assertEqual(self.delete(client, REMOTE_ADDR="172.30.0.10").status_code, 204)
        self.assert_owns_nothing(user_id)


class ExceptionTranslationTests(TestCase):
    def context(self, user):
        return {"request": SimpleNamespace(user=user, request_id="test"), "view": None}

    def test_only_a_deleted_requester_turns_database_errors_into_401(self):
        user = User.objects.create_user("learner")
        self.assertIsNone(exception_handler(IntegrityError("fk"), self.context(user)))
        self.assertIsNone(exception_handler(OSError("disk"), self.context(user)))
        self.assertIsNone(exception_handler(ValueError("bug"), self.context(SimpleNamespace(is_authenticated=True, pk=-1))))
        gone = SimpleNamespace(is_authenticated=True, pk=user.pk + 1000)
        for error in (IntegrityError("fk"), Attempt.DoesNotExist(), OSError("file")):
            response = exception_handler(error, self.context(gone))
            self.assertEqual(response.status_code, 401)
            self.assertEqual(response.data["error"]["code"], "AUTHENTICATION_REQUIRED")
            self.assertEqual(response["WWW-Authenticate"], "Bearer")

    def test_anonymous_requests_are_not_translated(self):
        anonymous = SimpleNamespace(is_authenticated=False, pk=None)
        self.assertIsNone(exception_handler(IntegrityError("fk"), self.context(anonymous)))


class WorkerDeletionTests(AccountFlow, TemporaryMedia, TestCase):
    @classmethod
    def setUpTestData(cls):
        call_command("seed_questions", verbosity=0)

    def claimed(self):
        user, client = self.account()
        self.submitted(client)
        job = GradingJob.objects.get()
        job.status = "processing"
        job.save(update_fields=["status"])
        return user, GradingJob.objects.get(pk=job.pk)

    def run_worker(self, job):
        output = io.StringIO()
        # close_old_connections would end the transaction that wraps a TestCase.
        with patch("solfege.management.commands.run_grading_worker.claim_job", return_value=job), patch("solfege.management.commands.run_grading_worker.close_old_connections"):
            call_command("run_grading_worker", "--once", stdout=output)
        return output.getvalue()

    def test_worker_survives_a_job_deleted_before_execution(self):
        for key in ("", "test-not-a-real-key"):
            with self.subTest(key=bool(key)), self.settings(OPENROUTER_API_KEY=key), patch("solfege.grading.subprocess.run") as provider:
                user, job = self.claimed()
                self.assertTrue(delete_account(user))
                self.assertIn(f"job={job.id} deleted", self.run_worker(job))
                provider.assert_not_called()
                self.assertFalse(GradingJob.objects.exists())

    def test_result_arriving_after_deletion_is_not_stored(self):
        user, job = self.claimed()
        def delete_during_provider_call(*args, **kwargs):
            self.assertTrue(delete_account(user))
            raise OSError("provider gone")
        with self.settings(OPENROUTER_API_KEY="test-not-a-real-key"), patch("solfege.grading.subprocess.run", side_effect=delete_during_provider_call):
            self.assertEqual(execute_job(job), 0)
        self.assertFalse(GradingJob.objects.filter(pk=job.pk).exists())


class DeletePracticeUserTests(AccountFlow, TemporaryMedia, TestCase):
    @classmethod
    def setUpTestData(cls):
        call_command("seed_questions", verbosity=0)

    def run_command(self, username, typed):
        output = io.StringIO()
        with patch("builtins.input", side_effect=typed if isinstance(typed, BaseException) else [typed]) as prompt:
            call_command("delete_practice_user", username, stdout=output)
        return prompt

    def test_retyped_username_deletes_records_and_files(self):
        user, client = self.account()
        self.submitted(client)
        image = Answer.objects.get().image.name
        user_id = user.pk
        with self.captureOnCommitCallbacks(execute=True):
            self.run_command("learner", "learner")
        self.assert_owns_nothing(user_id)
        self.assertFalse(default_storage.exists(image))

    def test_admin_and_passwordless_accounts_can_be_deleted(self):
        for name, options in (("rootuser", {"is_superuser": True, "is_staff": True}), ("nopasswd", {})):
            with self.subTest(name):
                user = User.objects.create_user(name, **options)
                self.run_command(name, name)
                self.assertFalse(User.objects.filter(pk=user.pk).exists())

    def test_mismatch_or_cancel_keeps_the_account(self):
        user, _ = self.account()
        for typed in ("Learner", "learner ", "", EOFError(), KeyboardInterrupt()):
            with self.subTest(repr(typed)), self.assertRaises(CommandError):
                self.run_command("learner", typed)
            self.assertTrue(User.objects.filter(pk=user.pk).exists())

    def test_unknown_username_never_prompts(self):
        with patch("builtins.input") as prompt, self.assertRaises(CommandError):
            call_command("delete_practice_user", "nobody01")
        prompt.assert_not_called()


class DeletionConcurrencyTests(AccountFlow, TemporaryMedia, TransactionTestCase):
    def setUp(self):
        call_command("seed_questions", verbosity=0)

    def in_connection(self, operation):
        close_old_connections()
        try:
            return operation()
        finally:
            connection.close()

    def test_attempt_created_during_deletion_gets_401_and_leaves_nothing(self):
        user, client = self.account()
        user_id = user.pk
        from .recommendation import current_versions
        question = current_versions("exam").first().metadata
        inserted, deleted = Event(), Event()
        original = views.attempt_json

        def hold_uncommitted_attempt(*args, **kwargs):
            inserted.set()
            self.assertTrue(deleted.wait(20))
            return original(*args, **kwargs)

        with patch("solfege.views.attempt_json", side_effect=hold_uncommitted_attempt), ThreadPoolExecutor(max_workers=1) as pool:
            creating = pool.submit(self.in_connection, lambda: self.post(client, "attempts/", {"question_id": question["id"], "question_version": question["version"]}))
            self.assertTrue(inserted.wait(20))
            self.assertTrue(delete_account(user))
            deleted.set()
            response = creating.result(20)
        self.assert_unauthorized(response)
        self.assert_owns_nothing(user_id)

    def test_attempt_committed_after_the_first_scan_is_also_deleted(self):
        user, client = self.account()
        user_id = user.pk
        from .recommendation import current_versions
        question = current_versions("exam").first().metadata
        original = get_user_model

        def commit_attempt_before_the_user_lock():
            with ThreadPoolExecutor(max_workers=1) as pool:
                response = pool.submit(self.in_connection, lambda: self.post(client, "attempts/", {"question_id": question["id"], "question_version": question["version"]})).result(20)
            self.assertEqual(response.status_code, 201)
            return original()

        with patch("solfege.accounts.get_user_model", side_effect=commit_attempt_before_the_user_lock):
            self.assertTrue(delete_account(user))
        self.assert_owns_nothing(user_id)

    def test_deletion_waits_for_a_running_submit_then_removes_its_job(self):
        user, client = self.account()
        user_id = user.pk
        attempt = self.started_attempt(client)
        answer = self.uploaded(client, attempt)
        image = Answer.objects.get().image.name
        locked, finish = Event(), Event()
        original = views.new_job

        def hold_attempt_lock(*args, **kwargs):
            locked.set()
            self.assertTrue(finish.wait(20))
            return original(*args, **kwargs)

        with patch("solfege.views.new_job", side_effect=hold_attempt_lock), ThreadPoolExecutor(max_workers=2) as pool:
            submit = pool.submit(self.in_connection, lambda: self.post(client, f'attempts/{attempt["id"]}/submit/', {"answer_id": answer["id"]}))
            self.assertTrue(locked.wait(20))
            deletion = pool.submit(self.in_connection, lambda: client.delete(ME))
            with self.assertRaises(TimeoutError):
                deletion.result(1)
            finish.set()
            submitted = submit.result(20)
            removed = deletion.result(20)
        self.assertEqual(submitted.status_code, 202, submitted.data)
        self.assertEqual(removed.status_code, 204)
        self.assert_owns_nothing(user_id)
        self.assertFalse(GradingJob.objects.exists())
        self.assertFalse(default_storage.exists(image))

    def test_submit_and_upload_waiting_on_a_deletion_get_404_not_500(self):
        user, client = self.account()
        attempt = self.started_attempt(client)
        answer = self.uploaded(client, attempt)
        locked, finish = Event(), Event()

        def hold_locks(*args, **kwargs):
            locked.set()
            self.assertTrue(finish.wait(20))
            return "released"

        client.raise_request_exception = False
        with patch("solfege.accounts.throttle_key", side_effect=hold_locks), ThreadPoolExecutor(max_workers=3) as pool:
            deletion = pool.submit(self.in_connection, lambda: delete_account(user))
            self.assertTrue(locked.wait(20))
            submit = pool.submit(self.in_connection, lambda: self.post(client, f'attempts/{attempt["id"]}/submit/', {"answer_id": answer["id"]}))
            upload = pool.submit(self.in_connection, lambda: self.uploaded_response(client, attempt))
            with self.assertRaises(TimeoutError):
                submit.result(1)
            finish.set()
            self.assertTrue(deletion.result(20))
            responses = (submit.result(20), upload.result(20))
        self.assertEqual([response.status_code for response in responses], [404, 404])
        self.assertEqual(list(Path(settings.MEDIA_ROOT).rglob("*.png")), [])

    @override_settings(PASSWORD_HASHERS=FAST_HASHERS)
    def test_login_holding_its_throttle_row_does_not_deadlock_with_deletion(self):
        user, _ = self.account(password="correct-horse-battery")
        user_id = user.pk
        locked, finish = Event(), Event()
        original = auth_views.remaining

        def hold_after_throttle_lock(*args, **kwargs):
            locked.set()
            self.assertTrue(finish.wait(20))
            return original(*args, **kwargs)

        login_client = APIClient()
        login_client.raise_request_exception = False
        with patch("solfege.auth_views.remaining", side_effect=hold_after_throttle_lock), ThreadPoolExecutor(max_workers=2) as pool:
            login = pool.submit(self.in_connection, lambda: login_client.post(
                "/api/v1/auth/login/", {"username": "learner", "password": "correct-horse-battery"}, format="json"))
            self.assertTrue(locked.wait(20))
            deletion = pool.submit(self.in_connection, lambda: delete_account(user))
            # The deletion must wait for the throttle row instead of taking the user row.
            with self.assertRaises(TimeoutError):
                deletion.result(1)
            finish.set()
            self.assertEqual(login.result(20).status_code, 200)
            self.assertTrue(deletion.result(20))
        self.assert_owns_nothing(user_id)

    def uploaded_response(self, client, attempt):
        file = io.BytesIO(PNG)
        file.name = "answer.png"
        return client.post(f'/api/v1/attempts/{attempt["id"]}/answers/', {
            "image": file, "client_answer_id": str(uuid.uuid4()), "answer_format_version": "1",
            "sheet_layout_id": attempt["question"]["sheet_layout"]["id"],
        }, format="multipart", HTTP_IDEMPOTENCY_KEY=str(uuid.uuid4()))

    def test_profile_change_losing_its_row_to_a_deletion_is_401(self):
        user, client = self.account()
        client.raise_request_exception = False
        original = views.fields

        def delete_first(*args, **kwargs):
            self.assertTrue(delete_account(user))
            return original(*args, **kwargs)

        with patch("solfege.views.fields", side_effect=delete_first):
            self.assert_unauthorized(client.patch(ME, {"learning_goal": "other"}, format="json"))

    def test_answer_image_losing_its_file_to_a_deletion_is_401(self):
        user, client = self.account()
        attempt = self.started_attempt(client)
        answer = self.uploaded(client, attempt)
        client.raise_request_exception = False
        original = views.get_object_or_404

        def delete_after_lookup(*args, **kwargs):
            found = original(*args, **kwargs)
            if isinstance(found, Answer):
                self.assertTrue(delete_account(user))
            return found

        with patch("solfege.views.get_object_or_404", side_effect=delete_after_lookup):
            response = client.get(f'/api/v1/attempts/{attempt["id"]}/answers/{answer["id"]}/image/', HTTP_ACCEPT="image/png")
        self.assert_unauthorized(response)

    def test_parallel_deletions_have_one_winner(self):
        user, client = self.account()
        self.submitted(client)
        user_id = user.pk
        with ThreadPoolExecutor(max_workers=6) as pool:
            responses = list(pool.map(lambda _: self.in_connection(lambda: client.delete(ME)), range(6)))
        codes = sorted(response.status_code for response in responses)
        self.assertEqual(codes.count(204), 1, codes)
        self.assertEqual(set(codes) - {204, 401}, set(), codes)
        self.assert_owns_nothing(user_id)
