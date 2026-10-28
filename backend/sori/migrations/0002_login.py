from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("sori", "0001_initial"),
        ("authtoken", "0004_alter_tokenproxy_options"),
        ("auth", "0012_alter_user_first_name_max_length"),
    ]

    operations = [
        migrations.CreateModel(
            name="LoginThrottle",
            fields=[
                ("key", models.CharField(max_length=64, primary_key=True, serialize=False)),
                ("events", models.JSONField(default=list)),
                ("blocked_until", models.DateTimeField(null=True)),
            ],
        ),
        # An UPDATE already holds the same user-row lock as login. Revocation
        # therefore commits atomically with admin saves, changepassword, resets,
        # and QuerySet.update(), including concurrent credential changes.
        migrations.RunSQL(
            """
            CREATE FUNCTION sori_revoke_changed_credentials() RETURNS trigger AS $$
            BEGIN
                IF OLD.password IS DISTINCT FROM NEW.password OR NOT NEW.is_active THEN
                    DELETE FROM authtoken_token WHERE user_id = NEW.id;
                END IF;
                RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            CREATE TRIGGER sori_credentials_changed
                AFTER UPDATE OF password, is_active ON auth_user
                FOR EACH ROW EXECUTE FUNCTION sori_revoke_changed_credentials();
            """,
            """
            DROP TRIGGER sori_credentials_changed ON auth_user;
            DROP FUNCTION sori_revoke_changed_credentials();
            """,
        ),
    ]
