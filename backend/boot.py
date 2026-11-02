"""Compose API entrypoint: migrate and seed before accepting requests."""
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
for arguments in (["migrate", "--noinput"], ["seed_questions"]):
    subprocess.run([sys.executable, str(ROOT / "manage.py"), *arguments], check=True, cwd=ROOT)
port = os.getenv("PORT", "8000")
os.execv(sys.executable, [sys.executable, "-m", "gunicorn", "config.wsgi:application", "--chdir", str(ROOT), "--bind", f"0.0.0.0:{port}", "--workers", "2", "--threads", "4"])
