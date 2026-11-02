import time
from django.core.exceptions import ObjectDoesNotExist
from django.core.management.base import BaseCommand
from django.db import close_old_connections
from sori.auth_views import purge_stale_throttles
from sori.grading import claim_job, execute_job

PURGE_INTERVAL_SECONDS = 3600

class Command(BaseCommand):
    help = "Process durable AI jobs. Runs independently of the HTTP server."
    def add_arguments(self, parser):
        parser.add_argument("--once", action="store_true")
    def handle(self, *args, **options):
        self.stdout.write("SORI grading worker started")
        next_purge = 0
        try:
            while True:
                close_old_connections()
                if time.monotonic() >= next_purge:
                    purge_stale_throttles()
                    next_purge = time.monotonic() + PURGE_INTERVAL_SECONDS
                job = claim_job()
                if job:
                    try:
                        execute_job(job)
                        job.refresh_from_db()
                        self.stdout.write(f"job={job.id} status={job.status}")
                    except ObjectDoesNotExist:
                        # The account was deleted mid-job; its result has nowhere to go.
                        self.stdout.write(f"job={job.id} deleted")
                elif not options["once"]:
                    time.sleep(1)
                if options["once"]:
                    return
        except KeyboardInterrupt:
            self.stdout.write("Worker stopped; unfinished job leases will expire.")
