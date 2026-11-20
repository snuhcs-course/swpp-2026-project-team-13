"""Export beta evaluations as JSONL to stdout; redirect to a private local file."""
import json
from django.core.management.base import BaseCommand
from solfege.models import AIFeedbackRating


class Command(BaseCommand):
    help = "Export AI feedback star ratings and frozen feedback/model versions as JSONL."

    def handle(self, *args, **options):
        rows = AIFeedbackRating.objects.select_related("job__attempt").order_by("created_at", "pk")
        for row in rows.iterator(chunk_size=200):
            self.stdout.write(json.dumps({"user_id": str(row.job.attempt.user_id), "attempt_id": str(row.job.attempt_id),
                "job_id": str(row.job_id), "stars": row.stars, "reason": row.reason,
                "feedback_id": row.feedback_id, "feedback": row.feedback_snapshot,
                "created_at": row.created_at.isoformat(), "updated_at": row.updated_at.isoformat()}, ensure_ascii=False))
