# Mac 담당자에게 전달

현재 개인 iPad 설치는 [GitHub 빌드 → Windows Sideloadly](WINDOWS-IPAD.md) 경로를 사용합니다. 아래 Xcode 직접 설치는 Mac과 iPad를 연결할 수 있을 때의 대안입니다.

이 작업본은 기존 SwiftUI/PencilKit 앱과 Django API 계약을 함께 수정한 소스입니다. 새 문제 3개를 앱 번들에도 넣었으므로 서버 없이 데모의 문제 표시·청음·필기를 먼저 확인할 수 있습니다. 데모 결과는 실제 채점이 아닙니다.

## 전달 파일

프로젝트 루트에서 python scripts/package-handoff.py를 실행해 dist/SORI-iPad-source.zip을 만듭니다. ZIP에는 소스·정답 MXL·템플릿·피아노 리소스·설치 안내를 포함하며 .env·개발 토큰·DB·학생 이미지·가상환경은 제외합니다.

원래 브랜치로 반영할 때 frontend/, backend/, docs/, scripts/, compose.yaml 및 .github/workflows/ci.yml의 변경을 함께 확인합니다. 개인 Xcode 설정과 signing 인증서는 반영하지 않습니다.

## Mac에서 확인

Xcode 16 이상과 iPadOS 17 이상을 대상으로 합니다. 사용 가능한 기기·SDK에 맞게 시뮬레이터를 선택합니다.

    swift test --package-path frontend
    xcodebuild -project frontend/IPadApp/IPadApp.xcodeproj -scheme IPadApp -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build

개인 iPad 설치는 Xcode 프로젝트를 열고 Signing Team을 선택한 뒤 실제 기기로 Run 합니다. [개인 iPad 설치 안내](IPAD-SETUP.md)를 따릅니다.

## 이번 프론트 변경

- Models/ExamAPI: 3/4·6/8과 박자별 새 오선 ID 허용
- MusicScore: 마디당 tick을 박자에서 계산, 16분음표·3:2 셋잇단음표·빔 파싱
- ScorePlaybackEngine: 구간 MIDI 끝과 실제 재생 대기 시간을 박자별 길이로 계산
- ScoreView: 박자표·음표 간격·16분음표·공통 빔·셋잇단음표 표시
- DemoExamAPI/Resources: 실제 3문제, 각자 main/scale MXL과 해시 고정 PNG
- ResultView: 점수와 음정/리듬 값을 AI 학습 평가로 표시
- Info-Debug.plist: Debug에서 PC의 LAN HTTP 허용; Release HTTPS 요구 유지

## 기기에서 확인할 항목

세 문제의 박자·16분음표·셋잇단음표·붙임줄이 맞게 보이고 들리는지 확인합니다. 확대·지우개·undo 후 제출 PNG가 캔버스 전체와 일치하는지, 실제 서버 연결 후 제출·대기·결과·앱 재실행 복구가 되는지 확인합니다. 실제 AI 응답은 키를 넣은 Windows 서버로 연결한 상태에서 확인합니다.

Windows 작업 환경에서는 Xcode 빌드·서명·개인 iPad 실행을 수행하지 않았습니다. [검증 상태](VALIDATION.md)에 Mac 확인 결과를 추가해 주세요.


## 예비박 시간표 추가 확인

새 소스 ZIP에는 시험 시간표 v3과 sori-click-v1.wav가 추가됐습니다. 첫·마지막 전체 재생 전에 4/4는 4클릭, 3/4는 3클릭, 6/8은 6클릭이 나오고 첫 클릭이 더 큰지 확인합니다. 예비박 다음 문제 시작, 구간 뒤 필기 20초, 마지막 뒤 120초 카운트다운과 일시정지 복구도 확인합니다. 실제 시간표 확인은 기기 재생이 필요합니다.
