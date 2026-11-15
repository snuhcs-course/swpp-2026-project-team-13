from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):
    dependencies = [("sori", "0006_learning_goal_optional"), migrations.swappable_dependency(settings.AUTH_USER_MODEL)]
    operations = [
        migrations.AddField(model_name="attempt", name="exam_rating_snapshot", field=models.JSONField(blank=True, null=True)),
        migrations.CreateModel(name="ExamRatingState", fields=[
            ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
            ("rating", models.FloatField(default=7.0)), ("completed", models.PositiveIntegerField(default=0)),
            ("offer", models.JSONField(default=dict)), ("updated_at", models.DateTimeField(auto_now=True)),
            ("user", models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name="exam_rating", to=settings.AUTH_USER_MODEL)),
        ], options={"constraints": [models.CheckConstraint(condition=models.Q(rating__gte=0), name="exam_rating_nonnegative")]}),
        migrations.CreateModel(name="ExamRatingChange", fields=[
            ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
            ("before", models.FloatField()), ("after", models.FloatField()), ("delta", models.FloatField()),
            ("difficulty", models.FloatField()), ("grade", models.PositiveSmallIntegerField()),
            ("expected_score", models.FloatField()), ("completed_before", models.PositiveIntegerField()),
            ("k", models.FloatField()), ("model_version", models.CharField(max_length=60)),
            ("difficulty_version", models.CharField(max_length=60)), ("pool_version", models.CharField(max_length=60)),
            ("created_at", models.DateTimeField(auto_now_add=True)),
            ("attempt", models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name="rating_change", to="sori.attempt")),
        ]),
    ]
