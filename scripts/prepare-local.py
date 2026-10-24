"""Create private development settings. Never overwrite an existing .env or print keys."""
from pathlib import Path
import secrets
import socket
root = Path(__file__).resolve().parents[1]
path = root / "backend" / ".env"
if path.exists():
    print("Existing backend/.env preserved.")
else:
    addresses = {"localhost", "127.0.0.1", "[::1]"}
    try:
        addresses.update(item[4][0] for item in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET))
    except OSError:
        pass
    example = (root / "backend" / ".env.example").read_text(encoding="utf-8")
    example = example.replace("dev-only-change-before-deployment", secrets.token_urlsafe(48)).replace("replace-with-a-local-password", secrets.token_urlsafe(24))
    example = example.replace("DJANGO_ALLOWED_HOSTS=localhost,127.0.0.1,[::1]", "DJANGO_ALLOWED_HOSTS=" + ",".join(sorted(addresses)))
    path.write_text(example, encoding="utf-8")
    path.chmod(0o600)
    print("Created private backend/.env. Set OPENROUTER_API_KEY there before running the worker.")
(root / "backend" / ".local").mkdir(exist_ok=True)
