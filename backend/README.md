# Django Backend

An initial API server targeting Python 3.14. Product features and product authentication are not implemented yet.

## Run

macOS / Linux (from `backend/`):

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
cp .env.example .env
python manage.py migrate
python manage.py runserver
```

Windows PowerShell:

```powershell
py -3.14 -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
Copy-Item .env.example .env
.venv\Scripts\python.exe manage.py migrate
.venv\Scripts\python.exe manage.py runserver
```

`GET http://localhost:8000/api/health/` returns `{"status":"ok"}`.
The admin interface is available at `/admin/`. Create an account with `python manage.py createsuperuser` to use it.

## Configuration

`config/settings.py` loads `backend/.env`. Existing process environment variables take precedence.

| Variable | Purpose |
| --- | --- |
| `DJANGO_DEBUG` | `true` in the example; defaults to `false` when unset |
| `DJANGO_SECRET_KEY` | Required. The example value is for local development only |
| `DJANGO_ALLOWED_HOSTS` | Comma-separated hostnames or IP addresses, without a scheme or port |

To connect from a physical iPad, use the same network as the Mac and add the Mac's LAN IP to the allowed hosts.
For example: `DJANGO_ALLOWED_HOSTS=localhost,127.0.0.1,[::1],192.168.1.10`.
Then run `python manage.py runserver 0.0.0.0:8000`.
This setup is for local development; production web server configuration is not included.

## Structure and Checks

- `config/`: Django settings, URLs, and WSGI/ASGI entry points
- `api/`: Health API. Future product features can use separate Django apps
- `requirements.txt`: Pinned direct and transitive dependencies
- `db.sqlite3`: Local database created by migrations and excluded from Git

```sh
python manage.py check
python manage.py test api
python manage.py makemigrations --check --dry-run
```

The health API is public. The default permission for future APIs requires authentication.
Choose the production database before introducing domain models and real data.
