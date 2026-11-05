import re

from django.core.exceptions import ValidationError


class LetterAndDigitPasswordValidator:
    """ASCII on purpose: the iPad app applies the same check before it sends a password."""

    message = "비밀번호에 영문과 숫자를 모두 넣어 주세요."

    def validate(self, password, user=None):
        if not (re.search(r"[A-Za-z]", password) and re.search(r"[0-9]", password)):
            raise ValidationError(self.message, code="password_missing_letter_or_digit")

    def get_help_text(self):
        return self.message
