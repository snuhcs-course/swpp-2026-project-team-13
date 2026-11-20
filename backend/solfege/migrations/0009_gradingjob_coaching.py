from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [("sori", "0008_ai_feedback_rating")]
    operations = [migrations.AddField(model_name="gradingjob", name="coaching", field=models.JSONField(default=dict))]
