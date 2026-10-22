# Team 13 — iPad 앱 / Django 서버

두 명이 프론트엔드와 백엔드를 나누어 개발하기 위한 초기 프로젝트입니다.
제품 이름은 미정이며 로그인·필기 인식·제품 데이터 모델은 아직 구현하지 않았습니다.

```text
SwiftUI iPad 앱 ← HTTP / JSON → Django REST API → SQLite (개발용)
```

| 경로 | 내용 | 담당 |
| --- | --- | --- |
| `frontend/` | SwiftUI Xcode 프로젝트, 서버 연결 확인 화면 | 프론트엔드 |
| `backend/` | Django + Django REST Framework, health API | 백엔드 |
| `docs/api.md` | 요청·응답 형식 합의 | 공동 |
| `.github/workflows/ci.yml` | 백엔드 검사·테스트, iPad 앱 빌드 | 공동 |

## 빠른 시작

백엔드 (macOS / Linux, 저장소 루트에서):

```sh
cd backend
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
cp .env.example .env
python manage.py migrate
python manage.py runserver
```

`curl http://localhost:8000/api/health/` → `{"status":"ok"}`.

프론트엔드:

1. Mac의 Xcode에서 `frontend/IPadApp/IPadApp.xcodeproj`를 엽니다.
2. `IPadApp` scheme과 iPad 시뮬레이터를 선택하고 Run을 누릅니다.
3. Django 서버를 켜고 **서버 연결 확인**을 누르면 연결 결과를 표시합니다.

서버 없이도 앱은 실행됩니다. 연결 확인 요청만 실패 메시지를 표시합니다.
실제 iPad에서는 Mac의 LAN IP 설정이 필요합니다.
상세 안내: [프론트엔드](frontend/README.md), [백엔드](backend/README.md), [API](docs/api.md).

## 개발 환경

- 프론트엔드: Mac, Xcode 16 이상 및 호환되는 macOS, iPadOS 17 이상
- Swift 언어 모드 5.0, UI는 SwiftUI, 외부 Swift 패키지 없음
- 백엔드: Python 3.14, Django 5.2 LTS, Django REST Framework
- Python 직접·간접 의존성은 `backend/requirements.txt`에 정확한 버전으로 고정
- 로컬 DB는 SQLite. 운영 DB는 도메인 모델과 실데이터 도입 전에 결정

## 검증

백엔드 (`backend/.env` 준비 후):

```sh
cd backend
source .venv/bin/activate
python manage.py check
python manage.py test api
```

iPad 앱 (Mac, 저장소 루트에서):

```sh
xcodebuild -project frontend/IPadApp/IPadApp.xcodeproj \
  -scheme IPadApp -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

프론트엔드 자동 검증은 빌드이며 UI 테스트는 없습니다.
health API는 서버 프로세스 응답만 확인하며 DB 상태나 제품 기능은 확인하지 않습니다.

## 협업

- `main`은 실행 가능한 상태로 유지하고 작업 브랜치에서 PR을 만듭니다.
- 브랜치 예: `feat/ipad-editor`, `feat/notes-api`.
- API를 바꿀 때 `docs/api.md`를 함께 수정합니다.
- `.env`, DB, 가상환경, 개인 Xcode 설정, 인증서·키는 커밋하지 않습니다.
- Django migration 파일과 공유 Xcode 프로젝트·scheme은 커밋합니다.
- Docker와 운영 배포 설정은 필요할 때 추가합니다.

## 기존 프로젝트

기존 Android 코드와 이전 문서는 새 프로젝트에서 제거했습니다.
과거 커밋은 유지되며 교체 전 상태는 Git 커밋 `465dde2`에서 확인할 수 있습니다.
