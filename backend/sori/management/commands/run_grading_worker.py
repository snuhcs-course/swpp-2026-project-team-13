import time
from django.core.management.base import BaseCommand
from django.db import close_old_connections
from sori.grading import claim_job, execute_job

class Command(BaseCommand):
    help = "Process durable AI jobs. Runs independently of the HTTP server."
    def add_arguments(self, parser):
        parser.add_argument("--once", action="store_true")
    def handle(self, *args, **options):
        self.stdout.write("SORI grading worker started")
        try:
            while True:
                close_old_connections()
                job = claim_job()
                if job:
                    execute_job(job)
                    job.refresh_from_db()
                    self.stdout.write(f"job={job.id} status={job.status}")
                elif not options["once"]:
                    time.sleep(1)
                if options["once"]:
                    return
        except KeyboardInterrupt:
            self.stdout.write("Worker stopped; unfinished job leases will expire.")
