from django.core.management.base import CommandError
from django.db import migrations, models
from django.utils import timezone


def refuse_case_duplicates(apps, schema_editor):
    with schema_editor.connection.cursor() as cursor:
        cursor.execute("SELECT lower(username), array_agg(username) FROM auth_user GROUP BY 1 HAVING count(*) > 1")
        duplicates = cursor.fetchall()
    if duplicates:
        accounts = "\n".join(f"  {', '.join(usernames)}" for _, usernames in duplicates)
        raise CommandError(f"대소문자만 다른 계정이 있습니다:\n{accounts}\nadmin에서 한쪽 아이디를 바꾼 뒤 다시 시작하세요.")


class Migration(migrations.Migration):
    dependencies = [
        ("sori", "0002_login"),
        ("auth", "0012_alter_user_first_name_max_length"),
    ]

    operations = [
        migrations.AddField(
            model_name="userprofile",
            name="created_via",
            field=models.CharField(choices=[("admin", "admin"), ("signup", "signup")], default="admin", max_length=10),
        ),
        migrations.AddField(
            model_name="loginthrottle",
            name="updated_at",
            field=models.DateTimeField(auto_now=True, default=timezone.now),
            preserve_default=False,
        ),
        migrations.RunPython(refuse_case_duplicates, migrations.RunPython.noop),
        # auth.User cannot take a Meta index, so the case-insensitive rule lives here.
        migrations.RunSQL(
            "CREATE UNIQUE INDEX sori_auth_user_username_lower ON auth_user (lower(username));",
            "DROP INDEX sori_auth_user_username_lower;",
        ),
    ]
