from django.apps import AppConfig

class SolfegeConfig(AppConfig):
    name = "solfege"
    # The old label keeps existing tables, migrations and admin URLs.
    label = "sori"
    default_auto_field = "django.db.models.BigAutoField"
