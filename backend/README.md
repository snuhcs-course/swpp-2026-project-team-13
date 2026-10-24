# Django backend

Django REST Framework + PostgreSQL + private file storage + DB-backed grading worker입니다. 현재 /api/health/ 및 /api/v1/의 문제·응시·답안·제출·결과·재시도 API를 구현합니다. 서버 실행과 실제 확인 상태는 ../docs/IPAD-SETUP.md 및 ../docs/VALIDATION.md를 따릅니다.

## 권장 실행: Docker Compose

프로젝트 루트에서 backend/.env를 준비한 뒤 실행합니다.

    docker compose --env-file backend/.env up --build -d --wait
    docker compose --env-file backend/.env logs --tail=100 api worker

API 컨테이너는 migrate → seed_questions → issue_dev_token → HTTP 서버 순서로 시작합니다. 워커는 API 준비 이후 DB의 queued 작업을 처리합니다. DB 데이터와 이미지 파일은 별도 named volume에 보존합니다. 일반 down은 데이터를 유지하며 down -v는 데이터를 삭제하므로 사용하지 마세요.

## 로컬 Python 실행

Python 3.14와 PostgreSQL이 필요합니다. backend 디렉터리에서 가상환경을 만들고 requirements.txt를 설치합니다. 이 PC의 3.14 Python은 PATH의 python과 다를 수 있습니다. Docker 방식에는 호스트 Python 패키지 설치가 필요 없습니다.

    python -m venv .venv
    .venv/Scripts/python.exe -m pip install -r requirements.txt
    .venv/Scripts/python.exe manage.py migrate
    .venv/Scripts/python.exe manage.py seed_questions
    .venv/Scripts/python.exe manage.py issue_dev_token
    .venv/Scripts/python.exe manage.py runserver 0.0.0.0:8000

다른 터미널에서 같은 환경으로 실행합니다.

    .venv/Scripts/python.exe manage.py run_grading_worker

macOS/Linux에서는 실행 경로를 .venv/bin/python으로 바꿉니다. 개발 토큰은 backend/.local/connection.txt에 기록하며 OpenRouter 키와 다릅니다.

## 확인

    python manage.py check
    python manage.py makemigrations --check --dry-run
    python manage.py test api sori --noinput

API 테스트의 AI 응답은 명시적으로 mock 처리하므로 과금하지 않습니다. 실제 OpenRouter 호출과 iPad 연동은 별도 통합 확인이 필요합니다. 테스트 DB는 PostgreSQL을 사용합니다. 이 코드의 실행 검증을 SQLite 결과로 대신하지 않습니다.

## 운영 범위

현재 HTTP 서버는 개인 LAN 확인용 Django 개발 서버입니다. 공용 서비스 배포 시 HTTPS·운영 웹서버·백업 등의 배포 구성을 별도로 준비해야 합니다. SGS 배포는 이번 실행 구성에서 수행하지 않았습니다.
