"""Exam questions are recommended, never chosen. Selection is random until the recommendation algorithm exists."""
from django.db.models import F, Q
from .models import QuestionVersion


def current_versions(collection="practice"):
    items = QuestionVersion.objects.filter(question__published=True, version=F("question__current_version"))
    if collection == "classical":return items.filter(metadata__collection="classical")
    items=items.filter(Q(metadata__collection__isnull=True) | ~Q(metadata__collection="classical"))
    from .practice_bank import visible_ids
    ids=visible_ids()
    return items.filter(question_id__in=ids) if ids is not None else items


def recommended_version():
    return current_versions().order_by("?").first()
