# SORI — iPad 청음 연습

초급 40개·중급 14개·고급 59개, 총 113문제를 듣고 Apple Pencil로 작성한 뒤 Django 서버를 통해 AI 평가와 한국어 피드백을 받는 개인 연습용 앱입니다. 나의 연습실에서 난이도를 고르고 기존 시험 방식으로 풀 수 있습니다. 로컬 데모에서도 같은 문제의 재생·필기를 서버 없이 확인할 수 있으며 예시 결과임을 표시합니다. [새 문제·난이도·토큰 저장·서버 반영 안내](docs/PRACTICE-LEVELS.md), [기존 고난도 문제 안내](docs/NAVER-QUESTIONS.md)를 확인하세요.

별도의 **클래식 탭**에서 작곡가를 고르고 같은 형식의 청음 시험을 볼 수 있습니다. 원본부터 완전한 8마디인 7명·11개 선율만 수록하며, 조성별 빈 오선·음계와 MuseScore 정답 악보를 제공합니다. 기본 그랜드 피아노는 일반 청음·클래식·미니게임에서 같은 YDP Grand Piano를 사용합니다. [클래식 수록·서버 반영·검증 안내](docs/CLASSICAL-EXAMS.md), [HTML 미리듣기](classical-library/CLASSICAL.html)를 확인하세요.

## 먼저 확인할 문서

- Windows에서 iPad 앱 설치: [docs/WINDOWS-IPAD.md](docs/WINDOWS-IPAD.md)
- Windows 서버 실행과 연결: [docs/IPAD-SETUP.md](docs/IPAD-SETUP.md)
- 친구의 Mac에서 빌드 확인: [docs/MAC-HANDOFF.md](docs/MAC-HANDOFF.md)
- API 계약: [docs/sori-api/API-CONTRACT.md](docs/sori-api/API-CONTRACT.md)
- 실제 검증 상태: [docs/VALIDATION.md](docs/VALIDATION.md)
- MuseScore 악보와 외부 음원 준비: [docs/ASSETS.md](docs/ASSETS.md)

## 미니게임: 멜로디 런

홈 또는 사이드바의 미니게임에서 **메모리 / 그루브** 모드를 선택해 피아노로 선율을 복원할 수 있습니다. 현재 데모는 다장조·가단조 197개를 제공하며, 박자표에 맞춘 예비박, 2·4·8마디 구간, 입력 시간·조기 진행 설정과 마디별 결과 비교를 지원합니다. YDP Grand Piano 실녹음 음원은 빌드 전에 `python scripts/fetch_classical_piano.py`로 준비합니다(CI 자동 실행). 설계, XML 추가, 검사 명령은 [멜로디 런 안내](docs/MELODY-RUN.md)를 확인하세요.

## 구성

    iPad SwiftUI/PencilKit → Django REST API → PostgreSQL + 개인 답안 파일
                                                   ↓
                                                채점 워커
                                                   ↓
                                           OpenRouter AI 평가

서버는 PostgreSQL과 API·워커를 Docker Compose로 실행합니다. 앱은 GitHub의 macOS CI에서 실기기용 IPA를 만들고 Windows의 Sideloadly로 서명·설치합니다. 친구의 Mac에서 Xcode로 직접 설치하는 경로도 사용할 수 있습니다. OpenRouter 키는 서버에만 설정하고, 앱에는 사용자별 개발 Bearer 토큰만 넣습니다.

## Windows 시작

프로젝트 디렉터리의 일반 PowerShell에서 실행합니다. Docker Desktop의 Linux 엔진이 Running이어야 합니다.

    python scripts/prepare-local.py

생성된 backend/.env의 OPENROUTER_API_KEY에 팀 키를 설정합니다. DJANGO_ALLOWED_HOSTS에 이 PC의 LAN IPv4 주소가 포함되는지 확인합니다.

    docker compose --env-file backend/.env up --build -d --wait
    docker compose --env-file backend/.env exec -T api python manage.py test api sori --noinput

개발 토큰은 backend/.local/connection.txt에 저장됩니다. 앱의 연결 설정에서 로컬 데모를 끄고 http://<이 PC의 IPv4>:8000/api/v1/과 이 토큰을 입력합니다. Windows와 iPad는 같은 LAN을 사용합니다.

## 소스와 데이터

- frontend/: 기존 앱을 확장한 SwiftUI·PencilKit 코드와 원본 피아노 리소스
- backend/: Django API, PostgreSQL 모델·migration, 별도 AI 워커
- backend/content/source/: 기본 정답 XML 3개와 Naver 최종 채보 XML 59개·출처 기록
- backend/content/questions/: 앱·채점이 공유하는 버전 고정 MXL
- docs/: 공유 API와 설치·검증 안내
- scripts/: 데이터 확인과 실행·전달 도구

학생 필기 이미지·DB·토큰·API 키는 Git과 전달 ZIP에서 제외합니다. 제출한 답안 이미지는 변경하지 않고, AI 주석은 별도 데이터로 저장합니다. AI 평가의 음악적 정확도는 보장하지 않으며 실제 정답과 함께 확인합니다.
