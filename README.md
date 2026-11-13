# solfège — iPad 청음 연습

Drill의 **리듬 퍼즐**은 중·고급 선율의 두 마디를 듣고 12개 보기에서 리듬을 조합하는 게임입니다. 259개 구간, 긴 음·잇단음 조각, 타이·되돌리기, 소리 기준 기계채점과 단계별 힌트를 제공합니다. 재청취·제출·노출 조건을 기록하고 로그인한 계정으로 저장합니다. [사용법·기록·보류 사례](docs/RHYTHM-PUZZLE.md)를 확인하세요.

클래식을 제외한 **1,937문제를 Level 1~9**로 제공하고 Apple Pencil로 작성하는 개인 연습용 앱입니다. **Practice**에서는 난이도를 고르고 조성·박자로 걸러 풀며 정답과 직접 비교해 마디별 자기채점을, **Exam**에서는 서버가 추천한 문제로 시험을 보고 Django 서버를 통한 AI 평가와 한국어 피드백을 받습니다. Level 1은 조표가 없고 Level 2는 최대 1개이며, 상위 레벨은 음정·리듬·조성감과 조표 부담을 함께 평가합니다. [현재 난이도 계산식·커트라인·문제 분포 v2](docs/PRACTICE-DIFFICULTY-V2.txt)를 확인하세요. 추천 알고리즘을 구현하기 전까지 추천 문제는 클래식을 뺀 문제 중 랜덤입니다. 로컬 데모에서도 재생·필기·자기채점을 확인할 수 있으며 Exam 결과는 예시임을 표시합니다. [모드 분리와 확인 절차](docs/PRACTICE-EXAM.md), [초기 문제 수입·토큰 저장·서버 반영 안내](docs/PRACTICE-LEVELS.md)를 확인하세요.

Practice 안의 **클래식 선율 문제**에서 작곡가를 고르고 같은 형식으로 문제를 풀 수 있습니다. 원본부터 완전한 8마디인 7명·11개 선율만 수록하며, 조성별 빈 오선·음계와 MuseScore 정답 악보를 제공합니다. 기본 그랜드 피아노는 일반 청음·클래식·미니게임에서 같은 YDP Grand Piano를 사용합니다. [클래식 수록·서버 반영·검증 안내](docs/CLASSICAL-EXAMS.md), [HTML 미리듣기](classical-library/CLASSICAL.html)를 확인하세요.

시험의 필기 대기는 **대기 건너뛰기 → 3초 후 다음 재생**으로 줄일 수 있습니다. 로컬 데모 토글은 즉시 저장·전환되며, 새 응시는 더 가까운 두 단 오선과 끝세로줄을 사용합니다. [변경 사항·음계 안내 제안·업데이트](docs/EXAM-CONTROLS.md)를 확인하세요.

## 예전 이름(SORI)이 남아 있는 값

앱 이름은 solfège로 바꿨지만, 아래 값은 저장된 데이터와 이어져 있어 일부러 유지한다. 바꾸면 기존 필기와 응시 기록, 로그인, 서버 데이터를 잃거나 저장된 문제를 검증하지 못한다.

| 값 | 쓰이는 곳 |
| --- | --- |
| `SORI` 폴더, `sori.*` 설정 키, `org.snuhcs.team13.sori.*` Keychain 서비스, `sori-local-demo-v3` | 기기에 저장된 필기·기록·설정·로그인 |
| `sori-monophonic-*`, `sori-tempo-1`, `sori-score-tempo-1`, `sori-piano-*`, `sori-click-v1`, `sori-parser-5` | 문제 데이터와 저장된 응시의 재생·채점 계약 |
| `sori.local`, `api.sori.example`, `assets.sori.example` | 문제 UUID 생성 기준과 문제 데이터 안의 예시 주소 |
| Django 앱 라벨 `sori`, `sori_*` 테이블·트리거, `sori:ai-quota` 잠금 키 | 운영 DB와 마이그레이션 |
| Compose 프로젝트 `sori`, DB 이름·사용자 `sori` | 기존 Docker 볼륨 `sori_postgres_data`, `sori_answer_data` |
| `grading-prompt-v*.txt`, `notation-rules-v1.txt`, `sori-feedback-2-notation-1` | 버전을 고정한 AI 채점 프롬프트 |

## 먼저 확인할 문서

- 첫 실행 회원가입·학습 목표·로그인: [docs/ONBOARDING.md](docs/ONBOARDING.md)
- Windows에서 iPad 앱 설치: [docs/WINDOWS-IPAD.md](docs/WINDOWS-IPAD.md)
- Windows 서버 실행과 연결: [docs/IPAD-SETUP.md](docs/IPAD-SETUP.md)
- 친구의 Mac에서 빌드 확인: [docs/MAC-HANDOFF.md](docs/MAC-HANDOFF.md)
- API 계약: [docs/solfege-api/API-CONTRACT.md](docs/solfege-api/API-CONTRACT.md)
- Practice 난이도·레벨·조표 정책: [docs/PRACTICE-DIFFICULTY-V2.txt](docs/PRACTICE-DIFFICULTY-V2.txt)
- 악보 Feature v1 명세와 활용 원칙: [docs/FEATURE-V1.md](docs/FEATURE-V1.md)
- 실제 검증 상태: [docs/VALIDATION.md](docs/VALIDATION.md)
- MuseScore 악보와 외부 음원 준비: [docs/ASSETS.md](docs/ASSETS.md)

## 미니게임: 멜로디 런

메인 화면의 **Drill** 건반에서 기존 미니게임의 **메모리 / 그루브** 모드를 선택해 피아노로 선율을 복원할 수 있습니다. **Daily Training**은 준비 중인 메뉴입니다. 현재 데모는 다장조·가단조 197개를 제공하며, 박자표에 맞춘 예비박, 2·4·8마디 구간, 입력 시간·조기 진행 설정과 마디별 결과 비교를 지원합니다. YDP Grand Piano 실녹음 음원은 빌드 전에 `python scripts/fetch_classical_piano.py`로 준비합니다(CI 자동 실행). 설계, XML 추가, 검사 명령은 [멜로디 런 안내](docs/MELODY-RUN.md)를 확인하세요.

## 구성

    iPad SwiftUI/PencilKit → Django REST API → PostgreSQL + 개인 답안 파일
                                                   ↓
                                                채점 워커
                                                   ↓
                                           OpenRouter AI 평가

서버는 PostgreSQL과 API·워커를 Docker Compose로 실행합니다. 앱은 GitHub의 macOS CI에서 실기기용 IPA를 만들고 Windows의 Sideloadly로 서명·설치합니다. 친구의 Mac에서 Xcode로 직접 설치하는 경로도 사용할 수 있습니다. OpenRouter 키는 서버에만 설정하고, 앱에서는 관리자가 만든 아이디·비밀번호로 로그인합니다.

## Windows 시작

프로젝트 디렉터리의 일반 PowerShell에서 실행합니다. Docker Desktop의 Linux 엔진이 Running이어야 합니다.

    python scripts/prepare-local.py

생성된 backend/.env의 OPENROUTER_API_KEY에 팀 키를 설정합니다. DJANGO_ALLOWED_HOSTS에 이 PC의 LAN IPv4 주소가 포함되는지 확인합니다.

    docker compose --env-file backend/.env up --build -d --wait
    docker compose --env-file backend/.env exec -T api python manage.py test api solfege --noinput

관리자가 계정을 생성합니다. 비밀번호는 터미널에서 숨김 입력하며, 같은 명령으로 기존 계정의 비밀번호를 변경할 수도 있습니다.

    docker compose --env-file backend/.env exec api python manage.py create_practice_user student01

앱의 회원가입·로그인 화면 오른쪽 위 아이콘으로 연결 설정에 들어가 http://<이 PC의 IPv4>:8000/api/v1/로 연결한 뒤 해당 아이디·비밀번호로 로그인합니다. Windows와 iPad는 같은 LAN을 사용합니다. 서버 시작 시 개발 토큰을 자동 발급하지 않습니다.

## 소스와 데이터

- frontend/: 기존 앱을 확장한 SwiftUI·PencilKit 코드와 원본 피아노 리소스
- backend/: Django API, PostgreSQL 모델·migration, 별도 AI 워커
- backend/content/source/: 기본 정답 XML 3개와 Naver 최종 채보 XML 59개·출처 기록
- backend/content/questions/: 앱·채점이 공유하는 버전 고정 MXL
- docs/: 공유 API와 설치·검증 안내
- scripts/: 데이터 확인과 실행·전달 도구

학생 필기 이미지·DB·토큰·API 키는 Git과 전달 ZIP에서 제외합니다. 제출한 답안 이미지는 변경하지 않고, AI 주석은 별도 데이터로 저장합니다. AI 평가의 음악적 정확도는 보장하지 않으며 실제 정답과 함께 확인합니다.
