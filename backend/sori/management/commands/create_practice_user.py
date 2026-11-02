from getpass import getpass

from django.contrib.auth import get_user_model
from django.contrib.auth.hashers import make_password
from django.contrib.auth.password_validation import validate_password
from django.core.exceptions import ValidationError
from django.core.management.base import BaseCommand, CommandError
from django.db import IntegrityError, transaction

from sori.models import UserProfile, usernames_differing_by_case


def refuse_protected_account(username):
    existing = usernames_differing_by_case(username).first()
    if existing is None:
        return
    if existing.username != username:
        raise CommandError("대소문자만 다른 계정이 이미 있어 계정을 만들 수 없습니다.")
    # Signup collects no contact details, so nobody can prove ownership for a reset.
    if UserProfile.objects.filter(user=existing, created_via="signup").exists():
        raise CommandError("가입 계정은 소유자를 확인할 수 없어 비밀번호와 표시 이름을 바꾸지 않습니다.")


class Command(BaseCommand):
    help = "Create a practice account or reset its password interactively; never issues a token."

    def add_arguments(self, parser):
        parser.add_argument("username")
        parser.add_argument("--display-name", default="청음 학습자")

    def handle(self, *args, **options):
        username, name = options["username"], options["display_name"]
        User = get_user_model()
        user = User(username=username)
        try:
            user.full_clean(exclude=["password", "last_login", "date_joined"], validate_unique=False)
        except ValidationError as error:
            raise CommandError("계정 아이디를 확인해 주세요.") from error
        if not 1 <= len(name) <= 80:
            raise CommandError("표시 이름은 1~80자로 입력해 주세요.")
        refuse_protected_account(username)
        try:
            password = getpass("비밀번호: ")
            confirmation = getpass("비밀번호 확인: ")
        except (EOFError, KeyboardInterrupt):
            raise CommandError("계정 생성을 취소했습니다.") from None
        if password != confirmation:
            raise CommandError("비밀번호가 일치하지 않습니다.")
        if not 1 <= len(password) <= 1024:
            raise CommandError("비밀번호는 1~1024자로 입력해 주세요.")
        try:
            validate_password(password, user)
        except ValidationError as error:
            raise CommandError("\n".join(error.messages)) from None
        try:
            with transaction.atomic():
                User.objects.get_or_create(username=username, defaults={"password": make_password(None)})
                user = User.objects.select_for_update().get(username=username)
                # Checked again under the lock: signup may have won the race since the first check.
                refuse_protected_account(username)
                user.set_password(password)
                user.save(update_fields=["password"])
                profile, _ = UserProfile.objects.get_or_create(user=user)
                profile.display_name = name; profile.save(update_fields=["display_name"])
        except IntegrityError:
            raise CommandError("대소문자만 다른 계정이 이미 있어 계정을 만들 수 없습니다.") from None
        self.stdout.write(self.style.SUCCESS("계정 비밀번호를 설정했습니다. 앱에서 로그인하세요."))
