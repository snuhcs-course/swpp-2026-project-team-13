import hashlib
import json
from django.conf import settings
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from sori.models import Question, QuestionVersion

class Command(BaseCommand):
    help = "Register the three immutable problem versions shipped with the application."
    @transaction.atomic
    def handle(self, *args, **options):
        catalog = json.loads((settings.CONTENT_ROOT / "catalog.json").read_text(encoding="utf-8"))
        for item in catalog:
            metadata = item["metadata"]
            for kind in ("main", "scale"):
                data = (settings.CONTENT_ROOT / item[f"{kind}_path"]).read_bytes()
                asset = metadata["score_assets"][kind]
                if len(data) != asset["size_bytes"] or hashlib.sha256(data).hexdigest() != asset["sha256"]:
                    raise CommandError(f"Asset mismatch: {metadata['id']} {kind}")
            layout = metadata["sheet_layout"]
            png = (settings.CONTENT_ROOT / "sheets" / f"{layout['id']}.png").read_bytes()
            if hashlib.sha256(png).hexdigest() != layout["template_sha256"]:
                raise CommandError("Template hash mismatch")
            question, _ = Question.objects.get_or_create(id=metadata["id"], defaults={"order": item["order"], "current_version": metadata["version"]})
            old = QuestionVersion.objects.filter(question=question, version=metadata["version"]).first()
            if old and (old.metadata != metadata or old.main_path != item["main_path"] or old.scale_path != item["scale_path"]):
                raise CommandError("An existing question version is immutable. Publish a new version instead.")
            if old is None:
                QuestionVersion.objects.create(question=question, version=metadata["version"], metadata=metadata, main_path=item["main_path"], scale_path=item["scale_path"])
            if question.current_version < metadata["version"]:
                question.current_version = metadata["version"]
                question.save(update_fields=["current_version"])
            self.stdout.write(f"Question {item['order']}: {metadata['title']}")
