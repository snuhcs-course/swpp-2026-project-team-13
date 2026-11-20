from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):
    dependencies = [("sori", "0007_exam_rating")]
    operations = [
        migrations.CreateModel(
            name="AIFeedbackRating",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("stars", models.PositiveSmallIntegerField()),
                ("reason", models.CharField(blank=True, max_length=500)),
                ("feedback_id", models.CharField(max_length=64)),
                ("feedback_snapshot", models.JSONField()),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("job", models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name="beta_rating", to="sori.gradingjob")),
            ],
            options={"constraints": [models.CheckConstraint(condition=models.Q(stars__gte=1, stars__lte=5), name="ai_feedback_stars_range")]},
        ),
    ]
