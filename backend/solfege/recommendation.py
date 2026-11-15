"""Published versions filtered by the frozen Practice/Exam partition."""
from django.db.models import F, Q
from .models import QuestionVersion


def current_versions(collection="practice"):
    items = QuestionVersion.objects.filter(question__published=True, version=F("question__current_version"))
    if collection == "classical":return items.filter(metadata__collection="classical")
    items=items.filter(Q(metadata__collection__isnull=True) | ~Q(metadata__collection="classical"))
    from .practice_bank import visible_ids
    ids=visible_ids()
    if ids is not None:items=items.filter(question_id__in=ids)
    if collection in ("practice", "exam"):
        from .question_pools import ids as pool_ids
        items=items.filter(question_id__in=pool_ids(collection))
    return items


def recommended_version(user):
    from .exam_rating import offer_for
    choices = sorted(offer_for(user)["choices"], key=lambda c:c["category"] != "matched")
    selected = next((c for c in choices if c["question_id"]), None)
    return QuestionVersion.objects.get(question_id=selected["question_id"],version=selected["question_version"]) if selected else None
