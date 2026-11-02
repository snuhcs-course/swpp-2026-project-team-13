import copy
import io
import json
import uuid
from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.test import TestCase
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient
from .accounts import delete_account
from .models import GradingJob, RhythmPlay
from .rhythm import digest_bytes
from .tests_rhythm import record_for


class RhythmAPITests(TestCase):
    @classmethod
    def setUpTestData(cls):
        call_command("seed_questions", stdout=io.StringIO())
        cls.user = get_user_model().objects.create_user(username="rhythm-learner")
        cls.other = get_user_model().objects.create_user(username="rhythm-other")
        cls.token = Token.objects.create(user=cls.user)
        data = (settings.CONTENT_ROOT / "rhythm-puzzle-v1.json").read_bytes()
        cls.catalog, cls.sha = json.loads(data), digest_bytes(data)

    def setUp(self):
        self.client = APIClient()
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + self.token.key)
        self.payload = record_for(self.catalog, self.sha)
        self.url = "/api/v1/drills/rhythm/plays/"

    def send(self, key=None):
        return self.client.post(self.url, self.payload, format="json", HTTP_IDEMPOTENCY_KEY=key or self.payload["client_play_id"])

    def test_saves_verified_feature_snapshot_without_any_ai_job(self):
        before = GradingJob.objects.count()
        response = self.send()
        self.assertEqual(response.status_code, 201, response.data)
        row = RhythmPlay.objects.get()
        self.assertEqual(row.feature_analysis.analysis_key, self.catalog["rounds"][0]["analysis_key"])
        self.assertEqual(row.result["first_correct"], True)
        self.assertEqual(row.result["source"], "deterministic")
        self.assertEqual(GradingJob.objects.count(), before)

    def test_v2_beginner_and_existing_v1_clients_both_save_against_their_frozen_catalog(self):
        self.assertEqual(self.send().status_code, 201)
        data = (settings.CONTENT_ROOT / "rhythm-puzzle-v2.json").read_bytes()
        catalog = json.loads(data)
        question = next(r for r in catalog["rounds"] if r["level"] == "beginner")
        self.payload = record_for(catalog, digest_bytes(data), question)
        response = self.send()
        self.assertEqual(response.status_code, 201, response.data)
        self.assertEqual(RhythmPlay.objects.count(), 2)
        row = RhythmPlay.objects.get(client_play_id=self.payload["client_play_id"])
        self.assertEqual(row.payload["game_version"], "rhythm-puzzle-v2")
        self.assertEqual(row.feature_analysis.analysis_key, question["analysis_key"])

    def test_non_object_record_is_an_input_error_instead_of_a_catalog_mismatch(self):
        response = self.client.post(self.url, [], format="json", HTTP_IDEMPOTENCY_KEY=str(uuid.uuid4()))
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.data["error"]["code"], "VALIDATION_ERROR")
        self.assertFalse(RhythmPlay.objects.exists())

    def test_receipt_replay_and_new_transport_key_do_not_duplicate_a_round(self):
        first = self.send()
        second = self.send()
        self.assertEqual(first.data, second.data)
        self.assertEqual(second["Idempotency-Replayed"], "true")
        third = self.send(key=str(uuid.uuid4()))
        self.assertEqual(third.status_code, 200)
        self.assertEqual(third.data, first.data)
        self.assertEqual(RhythmPlay.objects.count(), 1)
        self.payload["interruptions"] = 1
        self.assertEqual(self.send(key=str(uuid.uuid4())).status_code, 409)

    def test_only_the_owner_sees_a_record_and_authentication_is_required(self):
        self.assertEqual(self.send().status_code, 201)
        self.assertEqual(self.client.get(self.url).data["count"], 1)
        self.client.force_authenticate(self.other)
        self.assertEqual(self.client.get(self.url).data["count"], 0)
        self.client.force_authenticate(None)
        self.client.credentials()
        self.assertEqual(self.client.get(self.url).status_code, 401)

    def test_account_deletion_cascades_to_drill_records(self):
        self.assertEqual(self.send().status_code, 201)
        delete_account(self.user)
        self.assertFalse(RhythmPlay.objects.exists())

    def test_bad_catalog_or_claimed_outcome_is_not_stored(self):
        self.payload["catalog_sha256"] = "0" * 64
        self.assertEqual(self.send().status_code, 409)
        self.payload = record_for(self.catalog, self.sha)
        self.payload["outcome"] = "revealed"
        self.assertEqual(self.send().status_code, 400)
        self.assertFalse(RhythmPlay.objects.exists())

    def test_exports_task_conditions_and_first_submission_for_calibration(self):
        self.assertEqual(self.send().status_code, 201)
        output = io.StringIO()
        call_command("export_rhythm_calibration", user_id=self.user.pk, stdout=output)
        self.assertIn("first_correct", output.getvalue())
        self.assertIn(self.payload["client_play_id"], output.getvalue())
