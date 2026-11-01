# 시험 대기와 연결 모드, 새 오선

## 필기 대기 건너뛰기

시험 화면의 **다음 구간**을 누르면 현재 선율 또는 20초 필기 대기를 건너뛰고 **1.5초 후** 다음 청취 구간을 재생한다. 준비 중 다시 누르면 그다음 구간으로 한 단계 더 넘기며, 마지막 입력 뒤 1.5초 준비한다. 예를 들어 1번 청취 중 세 번 누르면 4번 청취부터 시작한다. 이전 재생 작업을 취소하고 한 개의 작업만 예약해 음원이 겹치지 않게 한다.

1–10번 청취의 재생·필기 대기에서 사용할 수 있다. 스케일과 마지막 청취 뒤에는 다음 구간이 없어 넘기지 않는다. 원래 필기 대기가 이미 1.5초 이하라면 더 늘리지 않는다. 일시 정지·백그라운드 전환·앱 복구 때 선택한 다음 구간과 남은 대기를 응시 기록에 저장한다. 권장 종료 시각은 기존 서버 기준을 유지한다.

## 로컬 데모 토글 수정

이전 화면은 `@State useDemo`만 바꾸고 데모 시작/서버 연결 버튼을 누를 때 모델에 적용했다. 따라서 다른 탭으로 나가면 선택이 사라지거나 이전 서버 API가 계속 사용될 수 있었다.

이제 토글은 실제 `AppModel.demo`를 표시하며 변경 즉시 설정을 저장하고 API를 다시 연결한다. 로컬 데모를 켜면 서버·AI 연결 대신 데모 API를 활성화한다. 전환이 끝나도 설정 화면에 머문다. 새 모드로 연결하지 못하면 이전 API를 남겨두지 않고 연결이 해제된 상태를 표시한다. 이미 저장한 응시·필기 파일과 서버 토큰을 삭제하지 않는다.

## 가까워진 오선과 끝세로줄

첫 오선 위치는 그대로 두고 두 번째 오선의 위쪽 선을 499에서 386으로 옮긴다. 두 단의 위쪽 선 사이 거리는 **335 → 222, 약 34% 감소**한다. 두 번째 오선 오른쪽 끝은 얇은 선 + 굵은 선으로 마무리한다. 첫 단의 오른쪽 끝은 일반 세로줄을 유지한다.

새 오선은 `staff-8bars-…-key…-v4`이며 표시할 높이는 620이다. 빈 아래 여백만 화면에서 잘라내고 PencilKit 좌표, 전체 저장 영역 1330×846, 제출 PNG 2660×1692는 유지한다. 따라서 글씨를 옮기거나 압축하지 않는다. 정답 MuseScore 이미지와 XML은 바꾸지 않는다.

기존 문제·응시를 덮어쓰지 않기 위해 `sheet-revisions.json`에서 같은 문제 ID의 새 버전으로 발행한다. 기본 62문제는 버전 3, 클래식 11개와 추가 51개는 버전 2로 올라간다. 이전 버전·오선·파일·응시 스냅샷은 남겨 두며 **새로 시작하는 응시**가 새 오선을 사용한다. 예전에 풀던 응시는 원래 오선에서 이어서 작성한다.

## 조성별 음계 안내

악보 준비가 끝나면 화면 상단에 **큰 보라색 음계 안내 배너**를 실제로 표시한다. 음계 재생 중에는 조성 이름과 진행 막대를 보여 주며, 첫 선율로 넘어가면 접힌다.

- 큰 제목: **D장조 음계 듣는 중** / **B단조 자연단음계 듣는 중**.
- 작은 설명: **문제에 앞서 이 조성의 기준음을 들려드려요**.
- 건반 아이콘과 실제 재생 시간에 맞춘 진행 막대.

표시 조성은 실제 음계 XML을 기준으로 한다. 조성이 명시되지 않은 고급 문제도 실제 제공되는 C장조 음계로 표시한다. 단조는 현재 제공하는 자연단음계를 명시한다. 음성 안내를 추가하지 않아 피아노 음계에 집중할 수 있다.

## 반영

일반 PowerShell에서 GitHub에 수정본을 올려 CI와 새 IPA 생성을 실행한다.

```powershell
cd C:\Users\123wh\Desktop\solfege\sori-github
git status
git log -3 --oneline
git push origin feat/sori-ipad-integration
```

서버에도 새 오선 버전을 등록한다.

```powershell
cd C:\Users\123wh\Desktop\solfege\sori
docker compose --env-file backend/.env up -d --build --wait api worker
docker compose --env-file backend/.env exec -T api python manage.py seed_questions
```

문제 수는 연습실 113 + 클래식 21이다. 브람스 10개를 별도 `brahms-catalog.json`에 추가했으며, 기존 124개와 버전은 그대로 유지한다. [브람스 반영 내역](BRAHMS-IMPORT.md)을 참고한다. 새 IPA를 기존 앱 위에 설치한다. DB·답안 볼륨을 삭제하지 않는다.

새 오선을 다시 생성할 때는 기존 버전 자산을 덮어쓰지 않는다.

```powershell
$sheetCode = Get-Content -Raw -LiteralPath scripts/build_classical_sheets.ps1
& ([scriptblock]::Create($sheetCode)) -Repository (Get-Location).Path -Compact
python scripts/build_sheet_revisions.py
```

## 검증

- Python 오프라인 검사: 새 악보의 원본 음정·리듬·붙임줄 보존, 조표·음계·MuseScore 정답, 기존 124문제 보존.
- `ExamPlaybackStateTests`: 1.5초 대기, 연속 건너뛰기, 마지막 구간 경계, 짧은 대기, 이전 기록 복구.
- `SheetRevisionTests`: 새 오선과 이전 악보 자산·ID·좌표 호환.
- `ExamControlsIntegrationTests`: 실제 재생 중 연속 건너뛰기와 예약 복구, 음계 배너, 데모 전환·재실행, 두 번째 오선 필기의 제출 좌표.
- Django 테스트: 최신 버전 목록과 이전 응시의 기존 오선·업로드 보존.

Swift/iPad와 Django DB 검사는 Windows에서 실행하지 못했으며 CI에 포함했다.
