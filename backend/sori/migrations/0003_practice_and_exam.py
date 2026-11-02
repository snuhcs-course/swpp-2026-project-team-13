import uuid
import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [("sori", "0002_featureanalysis")]
    operations = [
        migrations.AddField(model_name="attempt", name="mode", field=models.CharField(db_index=True, default="exam", max_length=20)),
        migrations.AddField(model_name="attempt", name="feature_analysis", field=models.ForeignKey(null=True, on_delete=django.db.models.deletion.PROTECT, related_name="attempts", to="sori.featureanalysis")),
        migrations.AddField(model_name="gradingjob", name="error_observations", field=models.JSONField(default=list)),
        migrations.CreateModel(name="SelfAssessmentRevision", fields=[
            ("id", models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
            ("revision", models.PositiveIntegerField()),
            ("errors", models.JSONField(default=list)),
            ("completed", models.BooleanField(default=False)),
            ("completed_at", models.DateTimeField(null=True)),
            ("created_at", models.DateTimeField(auto_now_add=True)),
            ("attempt", models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name="self_assessments", to="sori.attempt")),
        ], options={"constraints": [
            models.UniqueConstraint(fields=("attempt", "revision"), name="self_assessment_revision_unique"),
            models.CheckConstraint(condition=(models.Q(completed=True, completed_at__isnull=False) | models.Q(completed=False, completed_at__isnull=True)), name="self_assessment_completion_valid"),
        ]}),
    ]
