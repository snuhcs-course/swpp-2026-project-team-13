# Django 백엔드

Python 3.14 기준의 API 기본 틀입니다. 제품 기능과 제품용 인증은 미구현입니다.

## 실행

macOS / Linux (`backend/`에서):

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

`GET http://localhost:8000/api/health/` → `{"status":"ok"}`.
관리자 화면은 `/admin/`이며 사용하려면 `python manage.py createsuperuser`로 계정을 만듭니다.

## 설정

`config/settings.py`는 `backend/.env`를 읽습니다. 기존 프로세스 환경변수가 우선합니다.

| 변수 | 역할 |
| --- | --- |
| `DJANGO_DEBUG` | 예제는 `true`, 미설정 시 `false` |
| `DJANGO_SECRET_KEY` | 필수. 예제 값은 로컬 개발 전용 |
| `DJANGO_ALLOWED_HOSTS` | 쉼표로 구분한 호스트/IP. 스킴·포트 제외 |

실제 iPad에서 접속하려면 Mac과 같은 네트워크를 사용하고 호스트 목록에 Mac의 LAN IP를 추가합니다.
예: `DJANGO_ALLOWED_HOSTS=localhost,127.0.0.1,[::1],192.168.1.10`.
이후 `python manage.py runserver 0.0.0.0:8000`으로 실행합니다.
이 설정은 로컬 개발용이며 운영 웹 서버 설정은 포함하지 않습니다.

## 구조와 검사

- `config/`: Django 설정, URL, WSGI/ASGI 진입점
- `api/`: health API. 향후 제품 기능은 별도 Django app으로 나누어도 됩니다.
- `requirements.txt`: 직접·간접 의존성의 정확한 버전
- `db.sqlite3`: migrate로 생성되는 로컬 DB, Git 제외

```sh
python manage.py check
python manage.py test api
python manage.py makemigrations --check --dry-run
```

health API는 공개이며 향후 API의 기본 권한은 인증 필수입니다.
운영 DB는 도메인 모델과 실데이터를 만들기 전에 결정합니다.
