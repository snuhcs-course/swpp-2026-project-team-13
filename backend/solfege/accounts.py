"""Permanent account deletion, shared by the API and the delete_practice_user command."""
import logging

from django.contrib.auth import get_user_model
from django.core.files.storage import default_storage
from django.db import transaction

from .models import Answer, Attempt, GradingJob, LoginThrottle, SelfAssessmentRevision, locked_throttle, throttle_key

logger = logging.getLogger(__name__)


def delete_stored_images(names, request_id):
    for name in names:
        try:
            default_storage.delete(name)
        except Exception:
            # The account is already gone, so this must not change the response.
            logger.exception("Could not delete answer image %s request_id=%s", name, request_id)


def delete_account(user, request_id=None):
    """Delete the user and everything they own; returns False if another request already did."""
    with transaction.atomic():
        # Login holds this row while locking the user, so take it first here too.
        locked_throttle("username", user.username)
        # Attempts next: submit and upload hold an attempt lock while their commit-time
        # FK check waits for the user row, so locking the user first could deadlock.
        list(Attempt.objects.select_for_update().filter(user=user).order_by("id").values_list("pk", flat=True))
        locked = get_user_model().objects.select_for_update().filter(pk=user.pk).first()
        if locked is None:
            return False
        # Attempts committed before the user lock; later ones fail their FK check.
        attempts = list(Attempt.objects.select_for_update().filter(user=user).order_by("id").values_list("pk", flat=True))
        images = list(Answer.objects.filter(attempt__in=attempts).values_list("image", flat=True))
        # These references and GradingJob.answer are PROTECT.
        Attempt.objects.filter(pk__in=attempts).update(current_job=None, submitted_answer=None)
        GradingJob.objects.filter(attempt__in=attempts).delete()
        SelfAssessmentRevision.objects.filter(attempt__in=attempts).delete()
        Answer.objects.filter(attempt__in=attempts).delete()
        Attempt.objects.filter(pk__in=attempts).delete()
        LoginThrottle.objects.filter(key=throttle_key("username", locked.username)).delete()
        # Cascades to the token, profile and idempotency receipts.
        locked.delete()
        transaction.on_commit(lambda: delete_stored_images(images, request_id))
    return True


def profile_body(user, profile):
    # The caller's own user object: re-reading it could race an account deletion.
    return {"id": str(profile.id), "username": user.username, "display_name": profile.display_name, "learning_goal": profile.learning_goal}
