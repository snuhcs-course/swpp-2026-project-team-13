from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError

from solfege.accounts import delete_account


class Command(BaseCommand):
    help = "Permanently delete an account and its learning records after retyping the username."

    def add_arguments(self, parser):
        parser.add_argument("username")

    def handle(self, *args, **options):
        username = options["username"]
        user = get_user_model().objects.filter(username=username).first()
        if user is None:
            raise CommandError("계정을 찾을 수 없습니다.")
        try:
            typed = input("삭제를 확인하려면 아이디를 다시 입력하세요: ")
        except (EOFError, KeyboardInterrupt):
            raise CommandError("계정 삭제를 취소했습니다.") from None
        if typed != username:
            raise CommandError("아이디가 일치하지 않아 삭제하지 않았습니다.")
        if not delete_account(user):
            raise CommandError("계정을 찾을 수 없습니다.")
        self.stdout.write(self.style.SUCCESS("계정과 학습 기록을 삭제했습니다."))
