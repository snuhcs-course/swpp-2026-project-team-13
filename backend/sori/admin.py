from django.contrib import admin
from django.contrib.auth import get_user_model
from django.contrib.auth.admin import UserAdmin
from django.contrib.auth.forms import AdminUserCreationForm, UserChangeForm
from django.core.exceptions import ValidationError
from .models import UserProfile, Question, QuestionVersion, Attempt, Answer, GradingJob, usernames_differing_by_case

class CaseInsensitiveUsernameForm:
    # Reports what would otherwise be a unique index violation and a 500.
    def clean_username(self):
        username = self.cleaned_data["username"]
        if usernames_differing_by_case(username).exclude(pk=self.instance.pk).exists():
            raise ValidationError("대소문자만 다른 아이디가 이미 있습니다.", code="unique")
        return username

class SoriUserCreationForm(CaseInsensitiveUsernameForm, AdminUserCreationForm):
    pass

class SoriUserChangeForm(CaseInsensitiveUsernameForm, UserChangeForm):
    pass

class SoriUserAdmin(UserAdmin):
    add_form = SoriUserCreationForm
    form = SoriUserChangeForm

class UserProfileAdmin(admin.ModelAdmin):
    list_display = ("user", "display_name", "created_via")
    list_filter = ("created_via",)

admin.site.unregister(get_user_model())
admin.site.register(get_user_model(), SoriUserAdmin)
admin.site.register(UserProfile, UserProfileAdmin)
for model in (Question, QuestionVersion, Attempt, Answer, GradingJob):
    admin.site.register(model)
