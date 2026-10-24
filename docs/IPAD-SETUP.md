# 개인 iPad에서 확인하기

현재 목표는 Windows에서 서버를 실행하고, 친구의 Mac에서 앱을 빌드·서명해 개인 iPad에 설치하는 것입니다. Xcode에서 빌드한 실제 앱은 Windows 서버와 같은 Wi-Fi/LAN에서 연결합니다.

## 1. Windows 서버 준비

일반 PowerShell에서 프로젝트 폴더로 이동합니다. Docker Desktop의 Linux 엔진이 Running이어야 합니다. 에이전트의 제한된 실행 환경은 Docker named pipe 접근이 거부될 수 있어, 이 단계는 사용자의 일반 터미널에서 실행합니다.

    Set-Location -LiteralPath 'C:\Users\123wh\Desktop\solfege\sori'
    python scripts/prepare-local.py

backend/.env는 이미 있으면 덮어쓰지 않습니다. 텍스트 편집기로 OPENROUTER_API_KEY 항목에 팀 키를 설정합니다. DJANGO_ALLOWED_HOSTS에는 Windows PC의 현재 LAN IPv4를 추가합니다. 포트·http://는 hosts 값에 넣지 않습니다.

    docker compose --env-file backend/.env up --build -d --wait
    docker compose --env-file backend/.env ps

세 서비스 db, api, worker가 실행되어야 합니다. 브라우저에서 http://localhost:8000/api/health/의 status=ok를 확인합니다. health는 AI 키·DB·제품 기능을 모두 검사하는 엔드포인트가 아닙니다.

API·제출·복구 검증을 실행합니다. 이 검증은 AI mock을 사용해 과금하지 않습니다.

    docker compose --env-file backend/.env exec -T api python manage.py check
    docker compose --env-file backend/.env exec -T api python manage.py makemigrations --check --dry-run
    docker compose --env-file backend/.env exec -T api python manage.py test api sori --noinput 2>&1 | Tee-Object -FilePath backend/.local/backend-checks.log

실제 HTTP·AI 연결은 아래 명령으로 확인할 수 있습니다. 빈 테스트 답안을 한 번 실제 AI에 보내므로 과금이 발생합니다. 같은 상태 파일로 반복 실행하면 이미 제출된 같은 결과를 조회합니다. 필기 인식 정확도를 검사하는 명령은 아닙니다.

    python scripts/verify-live.py --with-ai

결과는 backend/.local/live-checks.json에 저장됩니다.

## 2. 친구의 Mac에서 설치

[MAC-HANDOFF.md](MAC-HANDOFF.md)의 절차를 따릅니다. frontend/IPadApp/IPadApp.xcodeproj를 Xcode에서 열고 Debug 구성을 사용합니다. Signing & Capabilities에서 친구의 개발 Team과 사용 가능한 Bundle Identifier를 설정합니다. 개인 인증서·Team 설정은 저장소에 커밋하지 않습니다.

iPad를 Mac에 케이블로 연결하고 기기 신뢰·개발자 모드 등 Xcode가 요구하는 설정을 완료한 뒤, 실행 대상을 실제 iPad로 선택하고 Run 합니다. Xcode·iPadOS 버전과 서명 상태에 따라 추가 안내가 나올 수 있습니다.

앱 설치에 대한 공식 안내: https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices

## 3. iPad에서 서버 연결

앱은 먼저 로컬 데모로 실행됩니다. 데모에는 실제 세 문제의 악보·소리가 있지만 채점 결과는 예시입니다.

1. Windows PC와 iPad를 같은 Wi-Fi/LAN에 연결합니다. Mac은 앱 설치 후 계속 켜둘 필요가 없습니다.
2. 앱의 연결 설정에서 로컬 데모를 끕니다.
3. 서버 주소에 http://<Windows PC의 LAN IPv4>:8000/api/v1/을 입력합니다.
4. 개발 토큰에 backend/.local/connection.txt의 토큰만 입력하고 연결합니다. OpenRouter 키를 입력하지 않습니다.
5. 세 문제 중 하나를 선택 → 준비 → 시작 → 청음·필기 → 제출 → AI 평가 결과를 확인합니다.

Windows 방화벽에서 연결을 묻는 경우 개인 네트워크의 서버 접근을 허용해야 합니다. 먼저 iPad Safari에서 http://<Windows IPv4>:8000/api/health/를 확인하면 앱 설정 문제와 네트워크 문제를 나눠 확인할 수 있습니다. localhost는 iPad 자신이므로 서버 주소로 쓰지 않습니다.

## 4. 정상 결과

제출하면 PNG와 선택한 답안 ID가 저장되고 queued → processing → completed 또는 needs_review/failed가 됩니다. 처리 화면을 나가도 서버 작업은 유지됩니다. completed에는 AI 점수·음정/리듬 평가·마디별 코멘트·한국어 피드백이 표시되고 정답 악보를 볼 수 있습니다. 이는 학습 참고용 AI 평가입니다.

모델의 응답에 수십 초 이상 걸릴 수 있습니다. 60초가 지나도 앱은 실패로 간주하지 않습니다. 연결 실패와 AI 결과 오류는 같은 답안을 재전송·재처리하며 새로 필기하지 않아도 됩니다.

키를 변경했다면 컨테이너가 새 환경을 읽게 다음 명령을 다시 실행합니다.

    docker compose --env-file backend/.env up -d

종료는 다음과 같습니다. DB·이미지는 유지합니다.

    docker compose --env-file backend/.env down

## 문제가 생기면

- up 실패: Docker Desktop 엔진과 패키지/이미지 다운로드 연결을 확인합니다.
- 400 Bad Request: DJANGO_ALLOWED_HOSTS의 실제 PC IP를 확인합니다.
- 401: 앱의 개발 토큰을 확인합니다. OpenRouter 키와 다릅니다.
- failed / ENGINE_UNAVAILABLE: 서버의 키·모델·외부 연결을 확인합니다.
- 서명·빌드 실패: Mac의 Xcode 오류를 먼저 확인합니다. Windows에서 iOS 바이너리를 빌드한 것으로 간주하지 않습니다.

    docker compose --env-file backend/.env logs --tail=100 api worker
