"""Analyze registered content offline; no API calls or automatic live submission changes."""
import hashlib
import json
from pathlib import Path
from uuid import UUID
from django.conf import settings
from django.core.management.base import BaseCommand, CommandError
from django.db.models import F
from sori.features import FeatureError, analyze
from sori.features.storage import store_analysis
from sori.models import QuestionVersion


class Command(BaseCommand):
    help = "Extract Feature v1 for registered question versions, preserving previous analyses."

    def add_arguments(self, parser):
        parser.add_argument("--question-id", type=UUID)
        parser.add_argument("--question-version", type=int)
        parser.add_argument("--all-versions", action="store_true")
        parser.add_argument("--dry-run", action="store_true", help="Analyze and report without creating any database rows.")
        parser.add_argument("--report", type=Path)

    def handle(self, *args, **options):
        if options["question_version"] is not None and options["question_version"] < 1:
            raise CommandError("--question-version must be positive")
        items = QuestionVersion.objects.select_related("question").order_by("question_id", "version")
        if options["question_id"]:
            items = items.filter(question_id=options["question_id"])
        if options["question_version"] is not None:
            items = items.filter(version=options["question_version"])
        elif not options["all_versions"]:
            items = items.filter(version=F("question__current_version"))
        results = []
        content = Path(settings.CONTENT_ROOT).resolve()
        for item in items.iterator():
            identity = dict(question_id=str(item.question_id), question_version=item.version)
            try:
                path = (content / item.main_path).resolve()
                if not path.is_relative_to(content):
                    raise FeatureError("content_path_outside_root")
                asset = item.metadata.get("score_assets", {}).get("main", {})
                if not asset.get("sha256") or not asset.get("size_bytes"):
                    raise FeatureError("missing_asset_manifest")
                if path.stat().st_size != asset["size_bytes"] or hashlib.sha256(path.read_bytes()).hexdigest() != asset["sha256"]:
                    raise FeatureError("source_asset_mismatch")
                payload = analyze(path, **identity)
                if options["dry_run"]:
                    outcome = "dry_run"
                else:
                    _, created = store_analysis(item, payload)
                    outcome = "created" if created else "unchanged"
                results.append(dict(**identity, outcome=outcome, analysis_status=payload["analysis_status"],
                                    analysis_key=payload["analysis_key"], unavailable_reasons=payload["unavailable_reasons"]))
            except FeatureError as error:
                results.append(dict(**identity, outcome="rejected", code=error.code, measure=error.measure))
            except OSError:
                results.append(dict(**identity, outcome="rejected", code="source_file_unavailable"))
        report = dict(dry_run=options["dry_run"], count=len(results),
                      created=sum(r["outcome"] == "created" for r in results),
                      unchanged=sum(r["outcome"] == "unchanged" for r in results),
                      rejected=sum(r["outcome"] == "rejected" for r in results), results=results)
        if options["report"]:
            options["report"].parent.mkdir(parents=True, exist_ok=True)
            options["report"].write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        self.stdout.write(json.dumps({k: v for k, v in report.items() if k != "results"}))
        if not results:
            raise CommandError("No registered question versions matched. Run seed_questions or check the filters.")
        if report["rejected"]:
            for row in results:
                if row["outcome"] == "rejected":
                    self.stderr.write(f"{row['question_id']} v{row['question_version']}: {row['code']}")
            raise CommandError("Some questions were rejected. Valid analyses were retained; inspect --report.")
