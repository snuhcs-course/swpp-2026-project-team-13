import uuid
import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [("sori", "0001_initial")]

    operations = [migrations.CreateModel(
        name="FeatureAnalysis",
        fields=[
            ("id", models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
            ("analysis_key", models.CharField(max_length=64, unique=True)),
            ("schema_version", models.CharField(max_length=40)),
            ("extractor_version", models.CharField(max_length=80)),
            ("source_xml_sha256", models.CharField(max_length=64)),
            ("payload_sha256", models.CharField(max_length=64)),
            ("analysis_status", models.CharField(max_length=20)),
            ("config", models.JSONField()),
            ("payload", models.JSONField()),
            ("created_at", models.DateTimeField(auto_now_add=True)),
            ("question_version", models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name="feature_analyses", to="sori.questionversion")),
        ],
        options={"constraints": [models.CheckConstraint(condition=models.Q(analysis_status__in=["complete", "partial"]), name="feature_analysis_status_valid")]},
    )]
