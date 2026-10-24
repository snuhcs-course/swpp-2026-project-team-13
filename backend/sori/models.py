import uuid
from django.conf import settings
from django.db import models

class UserProfile(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.OneToOneField(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    display_name = models.CharField(max_length=80, default="학습자")
    learning_goal = models.CharField(max_length=40, default="other")

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

class Attempt(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT)
    question_version = models.ForeignKey(QuestionVersion, on_delete=models.PROTECT)
    question_snapshot = models.JSONField()
    playback_plan = models.JSONField()
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
    usage = models.JSONField(default=dict)
    provider_request_id = models.CharField(max_length=200, blank=True)
    raw_response = models.JSONField(default=dict)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    started_at = models.DateTimeField(null=True)
    lease_expires_at = models.DateTimeField(null=True, db_index=True)
    class Meta:
        constraints = [models.CheckConstraint(condition=models.Q(score__isnull=True) | models.Q(score__lte=100), name="score_range")]

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
