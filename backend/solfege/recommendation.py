"""Exam questions are recommended, never chosen. Selection is random until the recommendation algorithm exists."""
from django.db.models import F, Q
from .models import QuestionVersion


def current_versions(collection="practice"):
    items = QuestionVersion.objects.filter(question__published=True, version=F("question__current_version"))
    return items.filter(metadata__collection="classical") if collection == "classical" else items.filter(Q(metadata__collection__isnull=True) | ~Q(metadata__collection="classical"))


def recommended_version():
    return current_versions().order_by("?").first()
