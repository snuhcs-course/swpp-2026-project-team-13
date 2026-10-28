# Django backend

Django REST Framework + PostgreSQL + private file storage + DB-backed grading worker입니다. 현재 /api/health/ 및 /api/v1/의 로그인·로그아웃·문제·응시·답안·제출·결과·재시도 API를 구현합니다. 서버 실행과 실제 확인 상태는 ../docs/IPAD-SETUP.md 및 ../docs/VALIDATION.md를 따릅니다.

## 권장 실행: Docker Compose

프로젝트 루트에서 backend/.env를 준비한 뒤 실행합니다.

    docker compose --env-file backend/.env up --build -d --wait
    docker compose --env-file backend/.env logs --tail=100 api worker

API 컨테이너는 migrate → seed_questions → HTTP 서버 순서로 시작합니다. 개발 토큰은 자동 발급하지 않습니다. 워커는 API 준비 이후 DB의 queued 작업을 처리합니다. DB 데이터와 이미지 파일은 별도 named volume에 보존합니다. 일반 down은 데이터를 유지하며 down -v는 데이터를 삭제하므로 사용하지 마세요.

    docker compose --env-file backend/.env exec api python manage.py create_practice_user student01

비밀번호를 숨김 입력해 연습 계정을 생성합니다. 같은 명령을 다시 실행하면 기존 계정의 비밀번호를 변경하고 기존 토큰을 폐기합니다. 관리자 화면은 별도 `createsuperuser` 명령으로 준비할 수 있습니다.

## 로컬 Python 실행

Python 3.14와 PostgreSQL이 필요합니다. backend 디렉터리에서 가상환경을 만들고 requirements.txt를 설치합니다. 이 PC의 3.14 Python은 PATH의 python과 다를 수 있습니다. Docker 방식에는 호스트 Python 패키지 설치가 필요 없습니다.

    python -m venv .venv
    .venv/Scripts/python.exe -m pip install -r requirements.txt
    .venv/Scripts/python.exe manage.py migrate
    .venv/Scripts/python.exe manage.py seed_questions
    .venv/Scripts/python.exe manage.py create_practice_user student01
    .venv/Scripts/python.exe manage.py runserver 0.0.0.0:8000

다른 터미널에서 같은 환경으로 실행합니다.

    .venv/Scripts/python.exe manage.py run_grading_worker

macOS/Linux에서는 실행 경로를 .venv/bin/python으로 바꿉니다. 기존 `issue_dev_token`은 명시적으로 실행하는 개발 도구로만 남겨두며, 그 도구로 만든 계정에는 먼저 사용 가능한 비밀번호를 설정해야 로그인할 수 있습니다.

## 로그인 계약 v0.7.0

`POST /api/v1/auth/login/`은 아이디·비밀번호를 확인하고 사용자당 하나인 DRF Bearer 토큰과 프로필을 반환합니다. `POST /api/v1/auth/logout/`은 해당 토큰을 폐기하며 204를 반환합니다. 로그인 제한은 PostgreSQL의 LoginThrottle 행을 잠가 프로세스 간 공유합니다. IP는 REMOTE_ADDR만 사용하므로 프록시 환경에서는 애플리케이션 서버의 클라이언트 주소 구성을 별도로 맞춰야 합니다.

로그인과 로그아웃은 사용자 행을 잠급니다. migration 0002의 PostgreSQL 트리거는 비밀번호 변경과 비활성화를 같은 트랜잭션 안에서 토큰 폐기에 연결합니다. Django 관리자·changepassword·계정 생성 명령 및 ORM 갱신에서도 적용됩니다. 자동 만료·refresh·기기별 세션은 없습니다.

## Mac에서 로그인 E2E 테스트

실제 iPad 앱 → HTTP API → PostgreSQL → Keychain → 앱 재실행 복구를 확인하는 수동 테스트입니다. 모든 터미널 명령은 **프로젝트 루트**에서 실행합니다. 처음에는 같은 Mac의 iPad 시뮬레이터를 사용하면 LAN 설정 없이 확인할 수 있습니다.

### 1. 서버가 꺼진 상태에서 시작

현재 `.env`와 DB 볼륨은 유지합니다. `.env`를 다시 만들거나 DB 비밀번호를 임의로 바꾸지 않습니다. 처음 설치하는 환경에만 `python3 scripts/prepare-local.py`가 필요합니다. 준비 스크립트는 이미 있는 `.env`를 덮어쓰지 않습니다.

```sh
docker compose --env-file backend/.env up --build -d --wait db api
docker compose --env-file backend/.env ps
curl -i http://127.0.0.1:8000/api/health/
```

정상 결과는 `db`, `api` 모두 `healthy`, health HTTP 200 및 `{"status":"ok"}`입니다. API 시작 시 migration과 문제 등록을 자동 수행합니다. 로그인 테스트에는 OpenRouter 키와 worker가 필요하지 않습니다. 재시작이 반복되면 아래의 비밀번호 인증 오류 복구 절차를 확인합니다.

별도 터미널에서 요청 로그를 관찰합니다.

```sh
docker compose --env-file backend/.env logs -f api
```

### 2. 테스트 계정 두 개 준비

```sh
docker compose --env-file backend/.env exec api python manage.py create_practice_user e2e-a --display-name "E2E 학습자 A"
docker compose --env-file backend/.env exec api python manage.py create_practice_user e2e-b --display-name "E2E 학습자 B"
```

각 계정의 비밀번호를 숨김 입력으로 두 번 설정합니다. 회원가입 API를 호출하는 과정은 아닙니다. 같은 아이디가 이미 있으면 비밀번호를 변경하고 기존 토큰을 폐기하므로, 이 명령은 계정 준비 단계에 실행합니다. 비밀번호 입력이 필요하므로 `exec -T`는 사용하지 않습니다.

### 3. 시뮬레이터 앱 실행

```sh
python3 scripts/fetch_soundfont.py
```

macOS의 python.org Python 3.14에서 `CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate`가 발생하면, Python에 동봉된 인증서 설치 스크립트를 한 번 실행한 뒤 다시 받습니다. 이 스크립트는 certifi와 Python 기본 신뢰 인증서 경로를 설정합니다.

```sh
"/Applications/Python 3.14/Install Certificates.command"
python3 scripts/fetch_soundfont.py
python3 scripts/fetch_soundfont.py --check
```

다른 Python 버전을 사용하는 경우 해당 버전의 인증서 설치 스크립트를 사용합니다. `--check`가 `PASS GeneralUser GS v2.0.3 pinned bank and license`를 출력하면 음원과 라이선스 검증이 완료된 것입니다.

[Xcode 프로젝트](../frontend/IPadApp/IPadApp.xcodeproj)를 열고 Scheme `IPadApp`, 실행 대상은 설치된 iPad 시뮬레이터, Run configuration은 `Debug`로 선택한 뒤 실행합니다. 음원 준비는 이후 필기 복구 테스트에서 연습을 시작하기 위해 필요합니다.

앱의 **연결 설정 → 로컬 데모 사용 끄기 → API 기준 주소 입력 → 서버 연결** 순서로 진행합니다. 같은 Mac의 시뮬레이터에서는 `http://127.0.0.1:8000/api/v1/`을 입력합니다. 마지막 `/`를 포함합니다.

실제 iPad에서는 Mac의 LAN IPv4를 사용하고, 같은 네트워크에 연결합니다. 해당 IP를 `.env`의 `DJANGO_ALLOWED_HOSTS`에 추가한 뒤 API를 다시 생성합니다. Release 빌드는 HTTPS를 요구합니다. 자세한 기기 연결은 [설치 안내](../docs/IPAD-SETUP.md)를 따릅니다.

테스트 도중 서버 주소를 바꾸지 않습니다. `localhost`와 `127.0.0.1`은 서로 다른 origin이며 로그인 정보와 로컬 기록도 구분됩니다. 예전에 로그인한 정보가 자동 복구된다면 연결 설정에서 로그아웃한 뒤 아래 테스트를 시작합니다.

### 4. 정상·오류·재실행·로그아웃 확인

| 순서 | 조작 | 기대 결과 |
|---|---|---|
| 1 | A 아이디와 잘못된 비밀번호로 로그인 | HTTP 401, 아이디·비밀번호 확인 안내 |
| 2 | 올바른 비밀번호로 로그인 | HTTP 200, E2E 학습자 A와 문제 3개 표시 |
| 3 | 학습 목표 변경 | 변경한 목표 저장 |
| 4 | 앱 전환 화면에서 앱을 완전히 종료한 뒤 재실행 | GET /me/ 200, 비밀번호 재입력 없이 A와 학습 목표 복구 |
| 5 | 연결 설정에서 로그아웃 | POST /auth/logout/ 204, 로그인 화면으로 이동 |
| 6 | 앱 완전 종료 후 재실행 | 로그인 화면 유지 |
| 7 | A로 다시 로그인 | 정상 접속 |

경로 앞에는 `/api/v1`이 붙습니다. 앱을 홈 화면으로 보내는 것과 완전히 종료하는 것을 구분합니다. 로그인 오류 후 사용자 조작 없이 로그인 POST가 반복되지 않는지도 로그에서 확인합니다.

토큰 자체를 출력하지 않고 DB에서 토큰 존재 여부만 확인할 수 있습니다.

```sh
docker compose --env-file backend/.env exec -T api python manage.py shell -c "from rest_framework.authtoken.models import Token; print(Token.objects.filter(user__username='e2e-a').exists())"
```

로그인 후 `True`, 정상 로그아웃 후 `False`가 기대 결과입니다.

### 5. 계정 전환과 미제출 필기 복구

1. A로 로그인하고 문제 선택 → 연습 준비하기 → 시작을 누릅니다.
2. 필기를 남깁니다. 시뮬레이터에서는 손가락 필기 토글을 켜고 마우스로 그릴 수 있습니다.
3. 상단 연습실 버튼으로 돌아가 연결 설정의 계정 전환을 선택합니다.
4. B로 로그인하고 연습 기록에서 A의 기록이 보이지 않는지 확인합니다.
5. 다시 A로 계정을 전환하고 연습 기록 또는 이어서 연습하기를 엽니다.
6. 같은 응시와 기존 필기가 복구되는지 확인합니다.

이 테스트에서는 답안을 제출하지 않아도 됩니다. AI 평가와 비용 없이 로컬 필기 보존과 계정 분리를 확인할 수 있습니다.

### 6. 비밀번호 변경 후 기존 토큰 거부

A로 로그인한 상태에서 다음을 실행하고 새 비밀번호를 설정합니다.

```sh
docker compose --env-file backend/.env exec api python manage.py changepassword e2e-a
```

토큰 존재 여부가 `False`로 바뀌어야 합니다. 앱의 나의 연습실 화면을 아래로 당겨 새로고침하면 보호 API가 401을 반환하고 로그인 화면으로 이동해야 합니다. 이전 비밀번호로는 실패하고 새 비밀번호로는 성공하며, 기존 기록과 필기가 복구돼야 합니다. 서버가 토큰을 폐기한 직후 앱 화면이 즉시 바뀌는 것은 아니며, 다음 보호 요청에서 401을 받을 때 전환됩니다.

### 7. 서버 연결 실패와 로컬 로그아웃

A로 로그인한 상태에서 API만 중지합니다.

```sh
docker compose --env-file backend/.env stop api
```

앱을 완전히 종료하고 다시 실행하면 통신 오류가 표시돼야 합니다. API를 다시 시작하고 health 응답을 확인한 뒤 로그인 화면의 **저장된 로그인 다시 확인**을 누르면 비밀번호 입력 없이 복구돼야 합니다.

```sh
docker compose --env-file backend/.env start api
curl -i http://127.0.0.1:8000/api/health/
```

로컬 로그아웃을 확인하려면 정상 로그인 상태에서 API를 다시 중지하고, 앱 연결 설정에서 로그아웃을 누릅니다. 서버 폐기를 확인하지 못했다는 안내와 재시도·기기에서만 로그아웃 선택지가 나와야 합니다. **이 기기에서만 로그아웃**을 명시적으로 선택하면 저장된 로그인 정보가 제거돼야 합니다. 이 경우 서버 토큰은 남아 있을 수 있으므로 서버를 다시 켠 뒤 로그인하고 정상 로그아웃하여 정리할 수 있습니다.

### 8. 로그인 제한 확인

다른 테스트를 마친 뒤 실행합니다. 같은 아이디의 잘못된 비밀번호가 최근 5분 안에 5회 누적되면, 5번째 실패는 401이고 그다음 요청부터 429로 제한됩니다. 429 응답 후 앱에 남은 대기 시간이 표시되고, 대기 중에는 로그인 버튼이 비활성화돼야 합니다. 제한 해제 후 올바른 비밀번호로 로그인합니다.

IP별로도 최근 5분 동안 허용한 로그인 요청 30회를 집계합니다. 앞선 반복 시도로 제한이 섞일 수 있으므로 필요하면 5분을 기다린 뒤 시작합니다. 제한은 DB에 저장되어 API를 재시작해도 초기화되지 않습니다.

### 9. 자동 회귀 검증과 종료

```sh
docker compose --env-file backend/.env exec -T api python manage.py test sori.test_auth --noinput
swift test --package-path frontend
xcodebuild -project frontend/IPadApp/IPadApp.xcodeproj -scheme IPadApp -configuration Debug -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -only-testing:IPadAppTests/AuthenticationIntegrationTests -only-testing:IPadAppTests/IntegrationTests/testLocalJournalPersistsImmutableSubmissionKeysAndDrawing test
```

설치된 iPad 시뮬레이터 이름에 맞춰 destination을 바꿉니다. Keychain 테스트에는 시뮬레이터의 로컬 임시 서명이 필요합니다. 앱 자동 테스트는 HTTP 응답을 fixture로 대체하므로 실제 서버 E2E 확인에는 위 수동 절차도 실행합니다.

테스트가 끝나면 API·DB·워커를 모두 종료합니다. DB와 답안 볼륨은 유지합니다.

```sh
docker compose --env-file backend/.env down
docker compose --env-file backend/.env ps
```

종료 후 `ps`에 실행 중인 서비스가 없어야 합니다. `down -v`는 사용하지 않습니다.

## 확인

    python manage.py check
    python manage.py makemigrations --check --dry-run
    python manage.py test api sori --noinput

API 테스트의 AI 응답은 명시적으로 mock 처리하므로 과금하지 않습니다. 실제 OpenRouter 호출과 iPad 연동은 별도 통합 확인이 필요합니다. 테스트 DB는 PostgreSQL을 사용합니다. 이 코드의 실행 검증을 SQLite 결과로 대신하지 않습니다.

## API가 시작 직후 재시작을 반복할 때

먼저 프로젝트 루트에서 API 로그를 확인합니다.

    docker compose --env-file backend/.env logs --tail=100 api

`password authentication failed for user "sori"`가 나오고 DB 로그에 `Skipping initialization`이 보이면, 기존 PostgreSQL 볼륨의 비밀번호와 현재 설정이 다른지 확인합니다. 기존 볼륨을 재사용할 때는 `.env`의 `POSTGRES_PASSWORD`를 바꿔도 DB 계정 비밀번호가 자동으로 바뀌지 않습니다. `db`가 healthy인 상태에서도 API의 비밀번호 인증은 실패할 수 있습니다.

이 프로젝트의 로컬 DB 계정 비밀번호를 현재 컨테이너 설정에 맞추려면 다음 명령을 실행합니다. DB의 로컬 소켓 접속을 이용하며 비밀번호를 화면이나 명령 인자에 노출하지 않습니다. 기존 테이블과 답안 데이터는 유지합니다.

```sh
docker compose --env-file backend/.env exec -T db sh -c 'printf "%s\n%s\n" "$POSTGRES_PASSWORD" "$POSTGRES_PASSWORD" | psql -X -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c "\password"'
docker compose --env-file backend/.env up -d --wait db api
curl -i http://127.0.0.1:8000/api/health/
```

이 복구 방법은 API와 DB가 같은 `POSTGRES_PASSWORD` 설정을 사용하는 기본 Compose 구성을 전제로 합니다. 서버 복구를 위해 `down -v`로 볼륨을 삭제할 필요는 없습니다.

## 운영 범위

현재 HTTP 서버는 개인 LAN 확인용 Django 개발 서버입니다. 공용 서비스 배포 시 HTTPS·운영 웹서버·백업 등의 배포 구성을 별도로 준비해야 합니다. SGS 배포는 이번 실행 구성에서 수행하지 않았습니다.
