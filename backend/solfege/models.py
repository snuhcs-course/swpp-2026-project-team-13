import hashlib
import hmac
import uuid
from django.conf import settings
from django.contrib.auth import get_user_model
from django.db import models
from django.db.models import Value
from django.db.models.functions import Lower

def usernames_differing_by_case(username):
    # The same lower(username) expression as the unique index; never iexact or Python lower().
    return get_user_model().objects.annotate(lowered=Lower("username")).filter(lowered=Lower(Value(username)))

def throttle_key(kind, value):
    # Keyed so the short, enumerable IP and username space cannot be reversed from the table.
    return hmac.new(settings.SECRET_KEY.encode("utf-8"), (kind + "\0" + value).encode("utf-8"), hashlib.sha256).hexdigest()

class LoginThrottle(models.Model):
    # Database rows (and row locks) are shared by every API process.
    key = models.CharField(max_length=64, primary_key=True)
    events = models.JSONField(default=list)
    blocked_until = models.DateTimeField(null=True)
    updated_at = models.DateTimeField(auto_now=True)

def locked_throttle(kind, value):
    key = throttle_key(kind, value)
    while True:
        # INSERT ... ON CONFLICT DO NOTHING. get_or_create raised IntegrityError when a
        # concurrent request created the row and a signup deleted it before the retry read.
        LoginThrottle.objects.bulk_create([LoginThrottle(key=key)], ignore_conflicts=True)
        # The purge, a signup or an account deletion can delete the row before this lock.
        row = LoginThrottle.objects.select_for_update().filter(key=key).first()
        if row is not None:
            return row

class UserProfile(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.OneToOneField(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    display_name = models.CharField(max_length=80, default="학습자")
    # None: signed up but not chosen yet. "other" is a real choice, so it cannot stand in for this.
    learning_goal = models.CharField(max_length=40, default="other", null=True, blank=True)
    created_via = models.CharField(max_length=10, choices=[("admin", "admin"), ("signup", "signup")], default="admin")

class Question(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    order = models.PositiveIntegerField(default=0)
    published = models.BooleanField(default=True)
    current_version = models.PositiveIntegerField(default=1)
    class Meta:
        ordering = ["order", "id"]

class QuestionVersion(models.Model):
    question = models.ForeignKey(Question, on_delete=models.PROTECT, related_name="versions")
    version = models.PositiveIntegerField()
    metadata = models.JSONField()
    main_path = models.CharField(max_length=300)
    scale_path = models.CharField(max_length=300)
    class Meta:
        constraints = [models.UniqueConstraint(fields=["question", "version"], name="question_version_unique")]

class FeatureAnalysis(models.Model):
    """Append-only musical analysis; selecting a newer analysis is explicit."""
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    question_version = models.ForeignKey(QuestionVersion, on_delete=models.PROTECT, related_name="feature_analyses")
    analysis_key = models.CharField(max_length=64, unique=True)
    schema_version = models.CharField(max_length=40)
    extractor_version = models.CharField(max_length=80)
    source_xml_sha256 = models.CharField(max_length=64)
    payload_sha256 = models.CharField(max_length=64)
    analysis_status = models.CharField(max_length=20)
    config = models.JSONField()
    payload = models.JSONField()
    created_at = models.DateTimeField(auto_now_add=True)

    def save(self, *args, **kwargs):
        if not self._state.adding or kwargs.get("force_update"):
            from django.core.exceptions import ValidationError
            raise ValidationError("Feature analyses are immutable. Create a new analysis version.")
        kwargs["force_insert"] = True
        return super().save(*args, **kwargs)

    class Meta:
        constraints = [models.CheckConstraint(condition=models.Q(analysis_status__in=["complete", "partial"]), name="feature_analysis_status_valid")]

class Attempt(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT)
    question_version = models.ForeignKey(QuestionVersion, on_delete=models.PROTECT)
    question_snapshot = models.JSONField()
    playback_plan = models.JSONField()
    mode = models.CharField(max_length=20, default="exam", db_index=True)
    feature_analysis = models.ForeignKey(FeatureAnalysis, null=True, on_delete=models.PROTECT, related_name="attempts")
    status = models.CharField(max_length=20, default="ready")
    grading_mode = models.CharField(max_length=20, default="automatic")
    grading_version = models.CharField(max_length=60, default="ai-melodic-v1")
    created_at = models.DateTimeField(auto_now_add=True)
    started_at = models.DateTimeField(null=True)
    recommended_end_at = models.DateTimeField(null=True)
    submitted_at = models.DateTimeField(null=True)
    submitted_answer = models.ForeignKey("Answer", null=True, on_delete=models.PROTECT, related_name="submitted_for")
    current_job = models.ForeignKey("GradingJob", null=True, on_delete=models.PROTECT, related_name="current_for")

class Answer(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    attempt = models.ForeignKey(Attempt, on_delete=models.CASCADE, related_name="answers")
    client_answer_id = models.UUIDField()
    revision = models.PositiveIntegerField()
    image = models.FileField(max_length=300)
    answer_format_version = models.PositiveSmallIntegerField(default=1)
    sheet_layout_id = models.CharField(max_length=80)
    sha256 = models.CharField(max_length=64)
    size_bytes = models.PositiveIntegerField()
    created_at = models.DateTimeField(auto_now_add=True)
    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["attempt", "client_answer_id"], name="answer_client_unique"),
            models.UniqueConstraint(fields=["attempt", "revision"], name="answer_revision_unique"),
        ]

class GradingJob(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    attempt = models.ForeignKey(Attempt, on_delete=models.CASCADE, related_name="jobs")
    answer = models.ForeignKey(Answer, on_delete=models.PROTECT)
    status = models.CharField(max_length=20, default="queued", db_index=True)
    stage = models.CharField(max_length=20, default="pending")
    grading_version = models.CharField(max_length=60)
    model = models.CharField(max_length=160)
    reasoning_effort = models.CharField(max_length=20)
    prompt_version = models.CharField(max_length=60)
    timeout_seconds = models.PositiveIntegerField(default=240)
    max_output_tokens = models.PositiveIntegerField(default=16000)
    prompt_text = models.TextField()
    score = models.PositiveSmallIntegerField(null=True)
    pitch_accuracy = models.FloatField(null=True)
    rhythm_accuracy = models.FloatField(null=True)
    feedback = models.JSONField(null=True)
    annotations = models.JSONField(default=list)
    failure = models.JSONField(null=True)
    recognized_musicxml = models.TextField(blank=True)
    error_observations = models.JSONField(default=list)
    usage = models.JSONField(default=dict)
    provider_request_id = models.CharField(max_length=200, blank=True)
    raw_response = models.JSONField(default=dict)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    started_at = models.DateTimeField(null=True)
    lease_expires_at = models.DateTimeField(null=True, db_index=True)
    class Meta:
        constraints = [models.CheckConstraint(condition=models.Q(score__isnull=True) | models.Q(score__lte=100), name="score_range")]

class SelfAssessmentRevision(models.Model):
    """One complete snapshot of a student's own measure-level review."""
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    attempt = models.ForeignKey(Attempt, on_delete=models.PROTECT, related_name="self_assessments")
    revision = models.PositiveIntegerField()
    errors = models.JSONField(default=list)
    completed = models.BooleanField(default=False)
    completed_at = models.DateTimeField(null=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["attempt", "revision"], name="self_assessment_revision_unique"),
            models.CheckConstraint(condition=(models.Q(completed=True, completed_at__isnull=False) | models.Q(completed=False, completed_at__isnull=True)), name="self_assessment_completion_valid"),
        ]

class IdempotencyRecord(models.Model):
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    method = models.CharField(max_length=8)
    path = models.CharField(max_length=300)
    key = models.UUIDField()
    request_hash = models.CharField(max_length=64)
    response_status = models.PositiveSmallIntegerField()
    response_body = models.JSONField()
    location = models.CharField(max_length=500, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    class Meta:
        constraints = [models.UniqueConstraint(fields=["user", "method", "path", "key"], name="idempotency_scope_unique")]


class RhythmPlay(models.Model):
    """A frozen drill round. Deleting an account cascades to all its telemetry."""
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="rhythm_plays")
    client_play_id = models.UUIDField()
    question_version = models.ForeignKey(QuestionVersion, on_delete=models.PROTECT)
    feature_analysis = models.ForeignKey(FeatureAnalysis, on_delete=models.PROTECT)
    round_id = models.CharField(max_length=64)
    catalog_sha256 = models.CharField(max_length=64)
    payload_sha256 = models.CharField(max_length=64)
    payload = models.JSONField()
    result = models.JSONField()
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["user", "client_play_id"], name="rhythm_play_client_unique")]
