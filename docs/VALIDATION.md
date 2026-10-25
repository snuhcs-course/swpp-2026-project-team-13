# 검증 기록

2026-10-25, Windows 작업 환경에서 기록합니다. 기능 구현과 실제 실행 확인을 구분합니다.

| 항목 | 상태 |
|---|---|
| 원본 XML 3개와 등록 MXL 음정·길이·부점·붙임줄·빔·셋잇단음표 대조 | 통과 |
| 모든 마디 길이·음표 길이와 3종 PNG/MXL 해시·앱 번들 bytes | 통과, scripts/test_content.py의 3개 검증 |
| Python 3.14 문법 검사 | 통과 |
| Docker Compose 구성 파싱 | 통과 |
| 실제 PostgreSQL에서 기존 API·복구 검증 | 10개 통과, 실제 PostgreSQL / Python 3.14의 사용자 PowerShell 로그 확인 |
| 실제 클라이언트의 binary Accept 헤더 | MXL·PNG 요청 및 JSON 오류 응답까지 통과; 발견한 406 수정 후 9개 전체 재검증 통과 |
| 실제 HTTP 다운로드·업로드·조회 | 통과; 실제 HTTP 및 이미지 왕복 포함 전체 18개 점검 완료 |
| 실제 OpenRouter 호출·피드백 | 통과; 실제 OpenRouter 호출로 빈 답안의 completed·0점·한국어 피드백 확인 |
| Swift Package 검증·Xcode 시뮬레이터 빌드 | c3e5b7b 수정 후 GitHub frontend 검사 통과를 사용자에게 보고받음 |
| 개인 iPad 설치·필기·소리·실제 서버 연결 | GitHub 실기기 빌드와 Windows Sideloadly 설치 후 확인 필요 |

서버 검증 로그: backend/.local/backend-checks.log. 실제 HTTP·선택적 AI 점검 기록: backend/.local/live-checks.json. 이 파일들은 비공개이며 전달 ZIP에서 제외합니다.

Windows에서 Docker 엔진 named pipe 및 localhost HTTP 접근이 에이전트 실행 환경의 권한 제한으로 거부됩니다. 따라서 사용자의 일반 PowerShell에서 실제 서버/검증 스크립트를 실행하고, 저장된 결과를 확인합니다. SQLite로 실행 결과를 대체하지 않았습니다. 초기 DB migration 파일 생성만 로컬 캐시의 Django 5.2.17 도구로 수행했고, 배포용 requirements.txt의 고정 버전은 변경하지 않았습니다.

실제 AI 점검은 빈 오선 답안 한 장으로 호출해 전송·워커·구조화 결과·0점·한국어 피드백을 확인합니다. 실제 학생 필기의 인식 정확도나 기기 전체 흐름이 검증되었다는 뜻은 아닙니다.

실제 점검 결과: status=completed, score=0, failure=null. 빈 오선에 음표·쉼표가 없는 상황을 설명하는 한국어 피드백과 3개의 연습 제안을 받았습니다. 이 기록은 사용자 일반 PowerShell에서 실행한 scripts/verify-live.py --with-ai의 비공개 보고서로 확인했습니다.


## 실제 필기 3문제 평가 준비

scripts/evaluate_handwriting.py로 기존 PDF 발췌 3장을 실제 API에 제출할 준비를 했습니다.
기본 실행은 오프라인 준비만 하며 --run을 지정하면 실제 AI 채점 요청이 최대 3건 발생합니다.
API·모델·프롬프트는 현재 서버 설정을 그대로 사용합니다.

- 입력: ../evaluation/runs/pdf-excerpts/page-1-lines-{1-2,3-4,5-6}.png
- 변환: 원본 RGB 픽셀을 변경하지 않고 2660×1692 흰 캔버스 중앙에 배치
- 오프라인 검사 4개 통과: 세 입력의 모든 픽셀 보존, 알려진 A4 부점 누락의 구분, 제출 직후 응답 유실 시 중복 과금 방지, 실패 작업의 자동 유료 재시도 방지
- 실제 AI 실행: 사용자 일반 PowerShell에서 python scripts/evaluate_handwriting.py --run
- 결과: backend/.local/handwriting-evaluation/{REPORT.md,report.json,*-recognized.musicxml}
- 같은 명령을 재실행하면 저장된 응시·Idempotency-Key로 재개하며 별도 유료 재시도를 하지 않습니다.
- 비용·인식 XML·모델·워커 시간은 로컬 Docker에서 해당 job만 읽어 수집합니다. 비용이 없으면 추정하지 않고 null로 남깁니다.
- 실제 iPad export와 오류 표시 좌표는 이 평가 범위가 아닙니다. 기존 PDF의 오선 좌표가 앱 템플릿과 다릅니다.
- 정답 XML과의 차이는 인식 실수와 학생의 오답을 자동으로 구분하지 못합니다. 사용자 확인 사실은 3번 첫 마디 네 번째 음 A4의 부점 누락입니다.

현재 기록은 평가 준비·오프라인 검증이며, 실제 필기 3장의 서버 AI 결과가 통과했다는 뜻이 아닙니다.


## 실제 필기 3문제 평가 결과

사용자가 일반 PowerShell에서 evaluate_handwriting.py --run을 실행한 비공개 결과를 확인했습니다.
현재 모델 스냅샷은 openai/gpt-6.1-sol / medium / sori-feedback-1입니다.

| 문제 | 상태 | AI 점수 | 제출→결과 관측 | 응답 보고 비용(USD) |
|---|---|---:|---:|---:|
| 1 | completed | 100 | 47.209초 | 0.056516 |
| 2 | needs_review | 없음 | 115.419초 | 0.0946685 |
| 3 | completed | 98 | 60.119초 | 0.061216 |

합계 비용 0.2124005 USD. 1번 인식 XML은 등록 정답의 47개 이벤트와 일치했습니다.
2번은 제자리표/내림표 판독을 확정하지 못해 전체 점수를 보류했습니다. 확대 재업로드를 요청하는 피드백이 현재 앱 기능과 맞지 않습니다.
3번은 사용자 확인 A4 부점 누락을 인식·지적했지만, 뒤 B4의 짧은 두 번째 빔을 놓쳐 8분음표라고 설명하는 인식·피드백 오류도 있었습니다.
전체 인식·채점 정확도 통과로 표시하지 않습니다. 서버 처리 경로는 동작했고 품질·대기 시간 문제가 남았습니다.

상세 검토는 backend/.local/handwriting-evaluation/REVIEW.md, 원본 보고는 report.json과 REPORT.md에 있습니다.
기존 PDF 입력에 흰 여백만 추가한 검사이며 실제 iPad 내보내기·오디오·표시 좌표는 검증하지 않았습니다.


## 시험 재생 시간표·예비박 수정

사용자 지정에 따라 playback_plan v3을 구현했습니다. 시작 2초 → 스케일 → 2초 → 예비박 1마디 → 첫 전체 재생이며, 중간 각 필기 시간은 20초입니다.
마지막 전체 재생 앞에도 예비박을 주고, 그 재생 후 필기 120초를 제공합니다.
4/4·3/4·6/8의 클릭 수는 각각 4·3·6이며, 첫 클릭 velocity 110, 나머지는 70입니다.
두 전체 재생 모두 예비박과 문제를 같은 MIDI 시간축에 넣고, 중간 부분 재생에는 예비박을 넣지 않습니다.

Python 오프라인 시간·리소스 검사 2개와 Python 문법 검사를 통과했습니다.
추가한 Django 회귀 검사(전체 10개)는 사용자 Docker 재빌드 후 실행해야 합니다.
Swift의 실제 MIDI 이벤트 시점·강약·서버 v3 fixture·기존 v2 fixture 회귀 검사와 iPad 클릭 샘플 로딩 검사를 추가했지만 Mac이 없어 미실행입니다.
기기에서 실제 클릭 수·첫 박 음량·연속 재생·마지막 필기 시간을 확인하기 전까지 실기 재생 검증 완료로 보지 않습니다.

전체 길이는 현재 4분음표 BPM 96에서 4/4 434초(7분14초), 3/4·6/8 406.5초(안내 407초)입니다.
기존 문제 버전·정답 파일·기존 응시는 유지하며, 새 응시 스냅샷과 현재 문제 안내에 계산한 시간을 제공합니다.


## 재생 시간표 변경 후 서버 회귀 검사

사용자가 Docker 재빌드 후 실행한 backend/.local/backend-checks.log를 확인했습니다. PostgreSQL에서 10개 테스트가 0.781초에 OK로 완료됐으며, 박자별 예비박 계약·권장 시간·기존 문제 메타데이터 보존 검사를 포함합니다. Swift MIDI·기기 소리 검증은 아직 미실행입니다. 다음은 iPad Safari에서 Windows LAN 서버 health 접속 확인입니다.


## iPad Safari에서 Windows LAN 접속

사용자가 iPad Safari로 Windows 서버의 /api/health/에 접속해 ok 응답을 확인했다고 보고했습니다. 같은 LAN의 기기→Docker API 연결을 확인했습니다. 앱 개발 토큰 인증·필기 제출·기기 오디오는 앱 설치 후 확인해야 합니다.


## 첫 GitHub Actions 프론트 검사에서 확인한 테스트 오류

사용자가 공유한 macOS CI 로그에서 SORICore와 테스트 모듈의 컴파일은 성공했고, XCTest 33개 중 32개가 통과했습니다.
ThreeQuestionTests.testBadTripletDurationIsRejected 한 테스트에서 단언 2개가 실패했습니다.
1번 MXL의 셋잇단음표는 16분음표 셋잇단음표(duration=80)인데, 테스트가 존재하지 않는 duration=160을 치환하려 해 정상 XML이 그대로 유지된 것이 원인이었습니다.

테스트를 세 문제 각각의 실제 파싱 결과에서 셋잇단음표 길이를 찾고, 그 길이를 1 tick 늘린 XML을 만들어 거부되는지 확인하도록 수정했습니다.
사용하지 않는 q 경고도 해당 값을 실제 자산 파싱에 사용하면서 해결했습니다.
악보·앱 파서는 이 수정에서 변경하지 않았습니다. Windows에서 입력 변조가 실제로 일어나는지는 대조했지만, 수정 후 Swift 테스트 통과 여부는 다시 실행한 GitHub Actions 결과로 확인해야 합니다.
Core 검사 실패로 이후 iPad 앱 빌드 단계는 아직 확인되지 않았습니다.


## iPad 시뮬레이터 빌드의 좌표 타입 오류 수정

후속 GitHub Actions 로그에서 ScoreView.swift:53의 (Bool, CGFloat)를 (down: Bool, end: Double) 튜플에 저장할 수 없어 x86_64 앱 컴파일이 실패한 것을 확인했습니다.
NativeScoreRenderer의 줄기 끝 위치·마디 좌표·선 두께·텍스트 좌표와 계산을 SwiftUI/CoreGraphics에서 사용하는 CGFloat로 통일했습니다.
Windows에는 Xcode가 없어 이 수정 후 앱 빌드 성공 여부는 GitHub macOS CI의 재실행으로 확인해야 합니다.
이 변경은 좌표의 수치 타입에 관한 수정입니다. 악보 데이터와 재생·채점 로직은 변경하지 않았습니다.


## Windows에서 개인 iPad 설치 경로 추가

사용자가 가장 간편한 원격 설치 경로로 진행하도록 승인하여, push CI의 frontend 검사·시뮬레이터 빌드 뒤에 실기기용 unsigned Debug IPA 생성·업로드를 추가했습니다. 빌드에 Apple 로그인·서명 인증서가 필요하지 않으며 실제 설치 서명은 사용자의 Windows Sideloadly에서 수행합니다.

실기기 빌드는 iphoneos/arm64를 사용하고 설치용 앱에 한해 ENABLE_DEBUG_DYLIB=NO로 일반 실행 파일 레이아웃을 사용합니다. 패키징 단계는 시뮬레이터 출력 거부, iPad 대상·Debug HTTP 설정·필수 악보/오디오 원본 bytes·IPA 무결성을 확인합니다. Artifacts 이름은 SORI-iPad-install, 보관 기간은 14일입니다.

Windows의 패키징 검사 결과와 GitHub 실기기 빌드·실제 설치 여부는 구분합니다. 실제 iPad 오디오·필기·인증 제출 확인은 아직 남아 있습니다. iPad-hosted 통합 테스트를 실행한 것으로 간주하지 않습니다.

Windows 오프라인 패키징 검사 통과: Payload/IPadApp.app 구조, 원본 파일 bytes, 실행 권한, SHA-256, 설치 안내 동봉을 확인했습니다. 시뮬레이터 출력과 손상된 오디오를 패키징 전에 거부하는 것도 확인했습니다. 이 검사는 가짜 실행 파일을 쓴 패키징 전용 fixture이며 실제 사용 가능한 IPA를 생성한 결과가 아닙니다. GitHub iphoneos 빌드와 실제 설치 검증은 아직 대기 상태입니다.


## 재생·입력 개선 v0.5 — 기기 확인 대기

문제 전환·앱 복귀 시 오디오 그래프를 다시 구성하고, 중단·구성 변경·미디어 서비스 재시작을 처리하도록 변경했습니다. MIDI의 program change를 제거해 로드한 피아노와 클릭 음색을 덮어쓰지 않도록 했습니다. 실제 사용자의 무음 현상 해결 여부는 새 IPA의 기기 재현으로 확인해야 합니다.

새 템포 정책(4/4·3/4는 4분음표 80, 6/8은 점4분음표 55), 15음 상·하행 스케일, 피아노형 합성 음원 v2, Pencil 더블탭 처리를 추가했습니다. 문제 버전 2를 발행하며 기존 v1 파일과 응시 스냅샷은 보관합니다.

Windows에서 콘텐츠 5개, 시간 정책 5개, 음원 해시·튜닝·감쇠 1개, 필기 평가 도구 회귀 4개가 통과했습니다. GitHub CI에 실제 앱의 PianoAudioGraph를 macOS에서 오프라인 렌더링해 반복 복구 후 피아노 A4와 클릭의 비무음을 확인하는 검사를 추가했습니다. Swift 검사·Xcode 빌드·이 네이티브 오디오 검사는 push 후 CI에서 실행해야 합니다.

Docker named pipe가 에이전트 환경에서 Access is denied라 PostgreSQL API 검사와 새 이미지 빌드는 사용자 PowerShell 실행이 필요합니다. 이 기록은 소리·펜슬의 실기기 검증 완료를 뜻하지 않습니다.

추가 확인: Python 3.14에서 변경된 Python 11개 파일의 문법 검사가 통과했습니다. 새 v2 음원·악보의 IPA 동봉, 원본 bytes, 실행 권한, 체크섬과 시뮬레이터/손상 리소스 거부 검사를 통과했습니다. 이 패키징 검사는 실제 실행 파일 대신 fixture를 사용하며 실기기 IPA 빌드 성공을 뜻하지 않습니다.


## macOS 오디오 검사 -10871과 새 음원 메타데이터 수정

사용자 CI 로그에서 새 audio-check 실행이 Core Audio -10871(InvalidFile)로 실패했습니다. 초기 로그에는 어느 파일을 읽다 실패했는지 없었습니다. 분석 결과 새 sori-piano-v2.sf2의 INAM 문자열 길이가 21바이트로 기록되어 SoundFont 2.01 §5.3의 짝수 바이트·영 종료 규칙을 위반한 것을 확인했습니다. [SoundFont 원문 규격](https://www.synthfont.com/SFSPEC21.PDF)

문자열 끝 패딩까지 길이에 포함하도록 생성기를 수정하고 음원·SHA-256을 갱신했습니다. 실제 음원 바이너리에서 바뀐 것은 길이 필드 1바이트이며 PCM 샘플 해시는 이전과 동일합니다. 새 규격 검사가 수정 전 실패하고 수정 후 통과하는 것을 확인했고, 음원 검사 2개와 콘텐츠 검사 5개가 통과했습니다.

PianoAudioGraph는 피아노/예비박 로딩 오류에 파일명을 붙입니다. CI 실행기는 단계 로그를 즉시 기록하고 실패 시 읽기 쉬운 오류로 종료하도록 변경했습니다. 기존 네이티브 오디오 검사는 그대로 유지하며 생략하지 않았습니다. Apple Sampler에서 이 수정으로 해당 실행 오류가 해소되는지는 다음 macOS CI에서 확인해야 합니다.


## v0.6.0, 두 번째 피드백 반영 (2026-10-25)

- 로컬 통과: 악보 원본/재생/기존 음원 12개 검사, 기존 필기 평가 도구 4개 검사, 새 MuseScore 자산 2개 검사, 실제 AI 결과 검증 함수 4개 검사. 합계 22개. Python 문법 검사와 git diff --check 통과.
- 실제 MuseScore Studio 4.6.3으로 정답 3문제를 재출력하고 PNG를 눈으로 확인. 4+4마디 두 줄, 마디 번호 없음, 표시용 권장 제자리표. 원본 MXL 해시 보존.
- 구현: 정답/내 악보 동시 표시, 화면에서만 오선 두 줄 여백 축소, 원본 전체 보기, 표기 오류/권장 표기 피드백과 음표 순서, 피드백 선택 시 마디 강조, GeneralUser GS의 네 가지 음색 선택과 기기 저장.
- 실행 환경 제한: Docker named pipe는 Access is denied, GitHub raw 다운로드는 DNS 조회 실패. Swift/Xcode 미설치. 따라서 이번 변경의 PostgreSQL 통합 검사·실제 외부 음원 다운로드·AVAudioUnitSampler 소리·iPad UI 빌드/렌더링은 여기서 실행하지 못함.
- CI에 추가: 고정된 외부 음원/라이선스 다운로드, 네 프리셋의 C3/C4/A4/C6 실제 오프라인 렌더링, iPad 시뮬레이터의 비교 이미지/설정 저장/제출 복구 검사. 실행 결과와 비교 스크린샷은 SORI-comparison-tests artifact에 저장. 아직 이번 변경의 CI 결과를 확인하지 않음.
- 실제 필기에서 새 규칙이 얼마나 잘 동작하는지는 별도 검증 대상. docs/NOTATION-REVIEW.md의 실제 필기 사례를 확인해야 하며, 이번 작업에서 추가 OpenRouter 호출은 하지 않음.


## v0.6.0 첫 CI 실패 보정 (2026-10-25)

- 재현된 해시 오류: Windows 작업 파일의 CRLF 해시 c6986e63...와 Git의 LF 해시 dd2f4368...가 달랐음. 실제 작업 파일을 LF로 바꾼 뒤 MuseScore를 재실행하여 양쪽 manifest를 갱신. PNG/SVG 이미지 바이트는 변경되지 않음. 빌더는 이제 CR 문자가 있는 스타일 입력을 거부함.
- 프론트 코드의 오류: DemoExamAPI가 URL.path.hasSuffix("/display/")로 정답 이미지 경로를 식별했으나 Foundation URL.path는 끝의 슬래시를 제거함. lastPathComponent == "display"로 변경해 PNG 요청이 MXL로 떨어지는 분기를 수정. 정답 PNG 다운로드를 사용하는 두 실패 테스트의 공통 경로이며 실제 CI 상세 assertion은 아직 확인 전.
- 새 회귀 검사: 모든 데모 정답 URL의 끝에 슬래시가 있는/없는 형태가 같은 PNG 해시를 반환해야 함. 기존 비교 화면·제출/복구 테스트를 유지함. 시뮬레이터 테스트 로그도 artifact에 포함.
- 로컬 악보 검사 3개와 AI 결과 검사 4개 통과. Windows에는 Xcode가 없어 iPad 테스트 재실행 결과는 다음 CI에서 확인해야 함.
