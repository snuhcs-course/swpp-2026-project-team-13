"""Compose API entrypoint: migrate and seed before accepting requests."""
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
for arguments in (["migrate", "--noinput"], ["seed_questions"]):
    subprocess.run([sys.executable, str(ROOT / "manage.py"), *arguments], check=True, cwd=ROOT)
os.execv(sys.executable, [sys.executable, str(ROOT / "manage.py"), "runserver", "0.0.0.0:8000", "--noreload"])
