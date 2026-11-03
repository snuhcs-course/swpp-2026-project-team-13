"""Export original observations without inventing a population difficulty estimate."""
import csv
from django.core.management.base import BaseCommand
from solfege.models import RhythmPlay


class Command(BaseCommand):
    help = "Export Rhythm Puzzle first-submit results, replays and task conditions as CSV."

    def add_arguments(self, parser):
        parser.add_argument("--user-id", type=int)

    def handle(self, *args, **options):
        rows = RhythmPlay.objects.select_related("feature_analysis__question_version").order_by("created_at")
        if options["user_id"] is not None:
            rows = rows.filter(user_id=options["user_id"])
        writer = csv.writer(self.stdout)
        writer.writerow(["user_id", "play_id", "round_id", "question_id", "question_version", "analysis_key", "catalog_sha256",
                         "game_version", "outcome", "first_correct", "submissions", "replay_started", "replay_completed",
                         "active_ms", "interruptions", "prior_exposures", "prior_pattern_exposures", "meter", "tempo_quarter_bpm", "difficulty", "difficulty_version", "rhythm_key", "choice_order", "created_at"])
        for row in rows.iterator():
            p, r = row.payload, row.result
            task = r["task"]
            writer.writerow([row.user_id, row.client_play_id, row.round_id, row.feature_analysis.question_version.question_id,
                             row.feature_analysis.question_version.version, row.feature_analysis.analysis_key, row.catalog_sha256,
                             p["game_version"], r["outcome"], r["first_correct"], len(p["submissions"]), r["replay_started"], r["replay_completed"],
                             p["active_ms"], p["interruptions"], p["prior_exposures"], p["prior_pattern_exposures"],
                             f'{task["meter"]["numerator"]}/{task["meter"]["denominator"]}', task["tempo_bpm"], task["difficulty"]["score"],
                             task["difficulty"]["version"], task["rhythm_key"], ";".join(p["choice_order"]), row.created_at.isoformat()])
