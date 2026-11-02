"""Database invariants. Run through manage.py test against PostgreSQL."""
import copy
import hashlib
import io
from pathlib import Path
from django.core.exceptions import ValidationError
from django.core.management import call_command
from django.core.management.base import CommandError
from django.db import IntegrityError, transaction
from django.test import TestCase, override_settings

from .features import FeatureError, analyze
from .features.storage import store_analysis
from .models import FeatureAnalysis, Question, QuestionVersion

FIXTURE = Path(__file__).parent / "features/fixtures/example.musicxml"


class FeatureStorageTests(TestCase):
    def setUp(self):
        self.question = Question.objects.create()
        self.version = self.make_version(1)
        self.payload = analyze(FIXTURE, question_id=str(self.question.id))

    def make_version(self, number):
        raw = FIXTURE.read_bytes()
        return QuestionVersion.objects.create(question=self.question, version=number,
            metadata={"score_assets": {"main": {"size_bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}}},
            main_path=FIXTURE.name, scale_path=FIXTURE.name)

    def test_repeated_storage_is_idempotent(self):
        a, created = store_analysis(self.version, self.payload)
        b, repeated = store_analysis(self.version, copy.deepcopy(self.payload))
        self.assertTrue(created)
        self.assertFalse(repeated)
        self.assertEqual(a.id, b.id)
        self.assertEqual(FeatureAnalysis.objects.count(), 1)

    def test_new_configuration_retains_previous_analysis(self):
        a, _ = store_analysis(self.version, self.payload)
        second = analyze(FIXTURE, question_id=str(self.question.id), config={"intervals_across_rests": False})
        b, created = store_analysis(self.version, second)
        self.assertTrue(created)
        self.assertNotEqual(a.id, b.id)
        a.refresh_from_db()
        self.assertEqual(a.payload, self.payload)

    def test_new_question_version_does_not_replace_old_result(self):
        a, _ = store_analysis(self.version, self.payload)
        v2 = self.make_version(2)
        second = analyze(FIXTURE, question_id=str(self.question.id), question_version=2)
        b, _ = store_analysis(v2, second)
        self.assertNotEqual(a.analysis_key, b.analysis_key)
        self.assertEqual(FeatureAnalysis.objects.count(), 2)

    def test_same_identity_with_conflicting_result_is_rejected(self):
        row, _ = store_analysis(self.version, self.payload)
        changed = copy.deepcopy(self.payload)
        changed["metrics"]["large_down_count"] = 999
        with self.assertRaisesRegex(FeatureError, "analysis_identity_conflict"):
            store_analysis(self.version, changed)
        row.refresh_from_db()
        self.assertEqual(row.payload["metrics"]["large_down_count"], 1)

    def test_wrong_content_identity_is_rejected(self):
        v2 = self.make_version(2)
        with self.assertRaisesRegex(FeatureError, "analysis_question_mismatch"):
            store_analysis(v2, self.payload)
        changed = copy.deepcopy(self.payload)
        changed["analysis_key"] = "0" * 64
        with self.assertRaisesRegex(FeatureError, "analysis_key_mismatch"):
            store_analysis(self.version, changed)

    def test_model_save_cannot_replace_existing_row(self):
        row, _ = store_analysis(self.version, self.payload)
        with self.assertRaises(ValidationError):
            row.save()
        clone = FeatureAnalysis(**{field.attname: getattr(row, field.attname) for field in row._meta.concrete_fields})
        with self.assertRaises(IntegrityError), transaction.atomic():
            clone.save()

    def test_management_dry_run_and_repeated_execution(self):
        with override_settings(CONTENT_ROOT=FIXTURE.parent):
            call_command("analyze_question_features", dry_run=True, stdout=io.StringIO())
            self.assertEqual(FeatureAnalysis.objects.count(), 0)
            call_command("analyze_question_features", stdout=io.StringIO())
            call_command("analyze_question_features", stdout=io.StringIO())
        self.assertEqual(FeatureAnalysis.objects.count(), 1)

    def test_management_default_selects_current_version(self):
        self.make_version(2)
        self.question.current_version = 2
        self.question.save(update_fields=["current_version"])
        with override_settings(CONTENT_ROOT=FIXTURE.parent):
            call_command("analyze_question_features", stdout=io.StringIO())
            self.assertEqual(FeatureAnalysis.objects.get().question_version.version, 2)
            call_command("analyze_question_features", all_versions=True, stdout=io.StringIO())
        self.assertEqual(FeatureAnalysis.objects.count(), 2)

    def test_management_explicit_question_version_overrides_current(self):
        self.make_version(2)
        self.question.current_version = 2
        self.question.save(update_fields=["current_version"])
        with override_settings(CONTENT_ROOT=FIXTURE.parent):
            call_command("analyze_question_features", "--question-id", str(self.question.id),
                         "--question-version", "1", stdout=io.StringIO())
        self.assertEqual(FeatureAnalysis.objects.get().question_version.version, 1)

    def test_management_rejects_nonpositive_question_version(self):
        with self.assertRaisesRegex(CommandError, "--question-version must be positive"):
            call_command("analyze_question_features", "--question-version", "0", stdout=io.StringIO())
        self.assertEqual(FeatureAnalysis.objects.count(), 0)

    def test_management_rejects_asset_mismatch_without_saving(self):
        self.version.metadata["score_assets"]["main"]["sha256"] = "0" * 64
        self.version.save(update_fields=["metadata"])
        with override_settings(CONTENT_ROOT=FIXTURE.parent):
            with self.assertRaises(CommandError):
                call_command("analyze_question_features", stdout=io.StringIO(), stderr=io.StringIO())
        self.assertEqual(FeatureAnalysis.objects.count(), 0)
