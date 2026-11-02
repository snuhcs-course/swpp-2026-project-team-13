import uuid
from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):
    dependencies = [migrations.swappable_dependency(settings.AUTH_USER_MODEL),
                    ("sori", "0004_merge_0003_practice_and_exam_0003_signup")]
    operations = [migrations.CreateModel(name="RhythmPlay", fields=[
        ("id", models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False, serialize=False)),
        ("client_play_id", models.UUIDField()), ("round_id", models.CharField(max_length=64)),
        ("catalog_sha256", models.CharField(max_length=64)), ("payload_sha256", models.CharField(max_length=64)),
        ("payload", models.JSONField()), ("result", models.JSONField()), ("created_at", models.DateTimeField(auto_now_add=True)),
        ("user", models.ForeignKey(to=settings.AUTH_USER_MODEL, on_delete=django.db.models.deletion.CASCADE, related_name="rhythm_plays")),
        ("question_version", models.ForeignKey(to="sori.questionversion", on_delete=django.db.models.deletion.PROTECT)),
        ("feature_analysis", models.ForeignKey(to="sori.featureanalysis", on_delete=django.db.models.deletion.PROTECT)),
    ], options={"constraints": [models.UniqueConstraint(fields=["user", "client_play_id"], name="rhythm_play_client_unique")]})]
