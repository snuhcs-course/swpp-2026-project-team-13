# Windows에서 SORI를 개인 iPad에 설치하기

GitHub의 Mac에서 만든 실기기용 Debug 앱을 Windows의 Sideloadly로 서명·설치합니다. 친구의 Mac이나 유료 Apple Developer 가입 없이 진행하는 경로입니다. 현재 앱은 iPadOS 17 이상이 필요합니다.

IPA는 서명 전 파일입니다. iPad에서 파일을 누르는 것만으로 설치되지 않습니다. Apple 계정 로그인은 사용자 PC의 Sideloadly에서 진행하며 GitHub나 채팅에 비밀번호를 입력하지 않습니다.

## 1. GitHub에서 앱 파일 받기

1. [프로젝트 Actions](https://github.com/snuhcs-course/swpp-2026-project-team-13/actions)에서 CI를 엽니다.
2. 브랜치가 feat/sori-ipad-integration이고, 설치하려는 커밋의 실행인지 확인합니다.
3. 해당 실행의 frontend 작업이 성공하면 실행 요약 하단 Artifacts에서 **SORI-iPad-install**을 다운로드합니다. 저장소를 읽을 수 있는 GitHub 계정으로 로그인해야 합니다.
4. ZIP을 압축 해제합니다. 안에 있는 **SORI-iPad-unsigned.ipa**가 설치할 앱 파일입니다. build-info.json에서 원본 커밋을 확인할 수 있습니다.

IPA는 push로 실행한 CI에서 생성하며 보관 기간은 14일입니다. PR 검사에서는 중복 생성하지 않습니다. 이전 CI 실행에는 이 파일이 없습니다.

## 2. Windows 준비

1. [Sideloadly 공식 사이트](https://sideloadly.io/)에서 Windows 버전을 설치합니다.
2. Sideloadly의 Before you install 안내에 따라 Apple 웹 배포판 iTunes와 iCloud를 준비합니다. 공식 사이트는 Microsoft Store판 대신 웹 배포판을 요구하므로 설치 안내의 링크를 사용합니다.
3. iPad 잠금을 풀고 데이터 전송이 가능한 USB 케이블로 PC에 연결합니다.
4. iPad가 “이 컴퓨터를 신뢰하겠습니까?”라고 물으면 신뢰를 선택하고 기기 암호를 입력합니다.
5. Sideloadly의 기기 목록에 iPad가 표시되는지 확인합니다.

기존 iTunes/iCloud 환경 때문에 막히면 표시된 오류부터 확인합니다. 앱이나 iPad 데이터를 삭제해서 해결하지 않습니다.

## 3. 앱 설치

1. Sideloadly에 **SORI-iPad-unsigned.ipa**를 끌어다 놓습니다.
2. 설치 대상이 자신의 iPad인지 확인합니다.
3. 자신의 Apple 계정을 입력하고 **Start**를 누릅니다. 암호·2단계 인증을 요청하면 Sideloadly와 기기에서 직접 완료합니다.
4. iPad의 설정 → 일반 → VPN 및 기기 관리에서 자신의 계정에 해당하는 개발자 앱을 신뢰합니다. iPadOS 버전에 따라 신뢰·재시작 안내를 따릅니다.
5. 설정 → 개인정보 보호 및 보안 → 개발자 모드를 켜고 재시작·확인을 완료합니다. 메뉴가 보이지 않으면 먼저 설치를 시도한 후 다시 확인합니다.
6. 홈 화면의 **SORI**를 실행합니다. 처음에는 로컬 데모로 열립니다.

무료 계정은 앱 서명 유효 기간이 7일이며, 만료 전에 갱신해야 합니다. Sideloadly의 자동 갱신 옵션을 사용할 수 있지만 PC와 iPad가 USB 또는 미리 설정한 Wi-Fi로 연결되어 있어야 합니다. 처음에는 USB로 설치하고, Wi-Fi 갱신은 설치 성공 후 설정합니다.

앱을 업데이트하거나 서명을 갱신할 때는 같은 Apple 계정과 Bundle ID를 사용해 기존 앱 위에 설치합니다. SORI를 먼저 삭제하면 기기에만 저장된 편집 가능한 필기를 잃을 수 있습니다.

## 4. 현재 Windows 서버 연결

1. 서버를 실행하던 일반 PowerShell에서 다음을 실행합니다.

       Set-Location -LiteralPath 'C:\Users\123wh\Desktop\solfege\sori'
       docker compose --env-file backend/.env up -d

2. Windows PC와 iPad를 같은 Wi-Fi/LAN에 연결합니다. 서버와 워커가 실행되는 동안 Windows PC가 켜져 있어야 합니다.
3. iPad Safari에서 http://<Windows PC의 LAN IPv4>:8000/api/health/를 열어 status=ok를 확인합니다.
4. SORI의 **연결 설정**에서 **로컬 데모 사용**을 끕니다.
5. API 기준 주소를 http://<Windows PC의 LAN IPv4>:8000/api/v1/로 입력합니다. iPad의 localhost는 Windows 서버가 아닙니다.
6. 개발용 Bearer 토큰에는 서버 PC의 **sori/backend/.local/connection.txt**에 있는 토큰 값만 입력하고 **서버 연결**을 누릅니다. OpenRouter API 키와는 다른 토큰입니다.
7. 세 문제 중 하나를 준비 → 시작 → 청음·필기 → 제출하고 AI 결과를 확인합니다.

처음에는 데모에서 소리·필기를 확인하고, 서버 연결 후 실제 AI 제출을 한 번 확인합니다. 데모 결과는 예시이고, 실제 서버로 제출하면 OpenRouter 사용량이 발생합니다.

## 5. 기기에서 확인할 것

- 문제 3개의 박자·소리와 Apple Pencil/손가락 필기
- 시작 2초 → 스케일 → 2초 → 예비박 → 첫 전체 재생
- 첫·마지막 전체 재생의 예비박: 4/4는 4클릭, 3/4는 3클릭, 6/8은 6클릭. 첫 클릭이 더 큼
- 중간 필기 20초, 마지막 재생 후 필기 120초
- 필기 제출 → AI 대기 → 점수·피드백·정답 악보 표시

GitHub 빌드 성공은 실제 iPad의 오디오·필기·서버 제출까지 검증했다는 뜻이 아닙니다.

## 오류가 나면

- Artifacts 없음: 이전 실행이나 PR 실행이 아닌지, frontend의 IPA 생성·업로드 단계가 성공했는지 확인합니다.
- iPad가 안 보임: 잠금 해제·USB 케이블·컴퓨터 신뢰·Apple 드라이버를 확인합니다.
- 신뢰되지 않은 개발자 / Developer Mode Required: 위 3번의 iPad 설정을 확인합니다.
- Sideloadly 설치 실패: 오류 메시지와 단계를 확인합니다. 계정 암호나 인증 코드는 공유하지 않습니다.
- 서버 400: backend/.env의 DJANGO_ALLOWED_HOSTS에 현재 PC IPv4가 있는지 확인합니다.
- 서버 401: 개발 토큰을 확인합니다.
- 서버 연결 실패: iPad Safari에서 health 확인 후 앱 주소와 토큰을 확인합니다.

공식 자료: [Sideloadly](https://sideloadly.io/), [Sideloadly FAQ](https://sideloadly.io/faq.html), [Apple 개발자 모드](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device), [GitHub 빌드 파일 다운로드](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts).
