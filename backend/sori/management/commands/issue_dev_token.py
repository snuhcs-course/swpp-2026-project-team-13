from pathlib import Path
from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand
from rest_framework.authtoken.models import Token
from sori.models import UserProfile

class Command(BaseCommand):
    help = "Create a development user and save its Bearer token to a private local file."
    def add_arguments(self, parser):
        parser.add_argument("--username", default="ipad-owner")
        parser.add_argument("--output", default=str(settings.BASE_DIR / ".local" / "connection.txt"))
    def handle(self, *args, **options):
        user, created = get_user_model().objects.get_or_create(username=options["username"])
        if created:
            user.set_unusable_password(); user.save(update_fields=["password"])
        UserProfile.objects.get_or_create(user=user, defaults={"display_name": "청음 학습자"})
        token, _ = Token.objects.get_or_create(user=user)
        path = Path(options["output"])
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("SORI iPad 연결 설정\n서버 주소: http://<Windows 컴퓨터의 IPv4 주소>:8000/api/v1/\n개발 토큰: " + token.key + "\n\n이 파일은 비공개로 보관하세요. OpenRouter 키는 앱에 넣지 않습니다.\n", encoding="utf-8")
        path.chmod(0o600)
        self.stdout.write(f"Development connection settings saved to {path}")
