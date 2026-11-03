# Practice / Exam: 화면과 학습 기록

2026-11-01. API 0.7.0과 migration `0003_practice_and_exam`을 앱과 함께 반영한다.

## 메뉴

| 메뉴 | 이번 구현 |
|---|---|
| Daily Training | 준비 중 안내. 향후 미니게임 세트 + 청음 한 문제 구성 |
| Drills | 기존 멜로디 런 메모리/그루브 선택 화면 |
| Practice | 레벨 선택 → 문제 선택/다음 연습 추천 → 듣고 필기 → 마디별 자기채점 |
| Exam | 레벨·문제 선택 → 기존 시험 재생·필기 → AI 채점·피드백 |

클래식 선율은 Practice와 Exam 내부에서 선택할 수 있다. 기록·연결 설정은 보조 메뉴로 유지한다. 현재 추천은 선택한 레벨에서 **자기채점을 완료한 횟수가 적은 문제**를 우선하고 동률이면 카탈로그 순서를 따른다. 기기 내 기록을 사용한다. 사용자 feature 기반 약점 추정·적응형 난이도 추천은 후속 범위다.

## Practice의 실제 흐름

1. 기존 문제·오선·음계·예비박·시험 재생 순서로 듣고 Apple Pencil로 적는다.
2. 제출하면 AI 요청 없이 위에 정답, 아래에 제출 악보를 함께 표시한다. 제출 원본은 고정한다.
3. 내 악보의 마디를 누르고 **음정 / 리듬 / 기타**를 복수 선택한다. 다시 누르면 각 항목을 해제할 수 있다.
4. 표시는 즉시 iPad에 보관된다. **임시 저장**은 서버의 미완료 기록을, **채점 완료**는 완료 기록을 남긴다. 오류가 없어도 사용자가 명시적으로 완료해야 한다.
5. 완료 후에도 표시를 고쳐 다시 저장할 수 있다. 기존 저장 이력은 유지한다. 별도 점수는 만들지 않는다.

`source=self`는 학생의 관찰이다. ‘리듬 오류를 표시한 마디에 당김음이 있었다’는 추후 분석의 단서일 뿐, 당김음이 오류 원인이라고 확정하지 않는다. 완료된 응시의 마지막 revision에서만 미표시 마디를 ‘오류를 발견하지 않은 기회’로 해석한다. 임시 저장·미채점은 정답으로 세지 않는다.

앱은 전송 전에 정확한 본문·Idempotency-Key를 저장한다. 응답이 끊기면 ‘자기채점 저장 복구’로 같은 요청을 다시 보낸다. 다른 기기에서 수정했으면 로컬 표시를 보관하고 서버 표시 적용/내 표시 유지 선택을 받는다. 서버 이력과 로컬 초안을 자동으로 섞어 덮어쓰지 않는다.

## Exam과 XML 근거

기존 AI 채점·표기 관습 피드백·실패 재시도를 유지한다. 일반 서버에서만 실제 AI를 호출하며 OpenRouter 키는 백엔드 설정을 사용한다. **로컬 데모의 Exam은 예시 결과**다. Practice 데모는 실제 사용자가 선택한 자기채점 기록을 로컬에 저장한다.

서버의 각 AI 작업에는 인식 XML 전체와 `error_observations`를 보관한다. 완료된 결과의 오류 annotation마다 마디 번호·음표 순서·FeatureAnalysis ID·해당 인식 마디 XML과 상속 attributes를 남긴다. 빔·임시표·붙임줄 등 원본 인식 표기를 보존한다. 마디를 찾을 수 없으면 unavailable 사유를 남긴다. XML fragment는 독립된 전체 악보 파일이 아니다.

관습상 권장 사항인 `notation_suggestion`은 오류 집계에 넣지 않는다. 인식이 불확실한 마디는 별도로 표시한다. AI 마디/음표 순서는 인식 결과의 주장으로 보관하며, 정답 음표와 자동 정렬이 끝났다고 간주하지 않는다. 이후 통계에서는 `attempt.current_job`에 해당하는 최신 성공 결과를 사용하고, 이전 실패·재시도를 중복 학습 기록으로 세지 않아야 한다.

## 데이터 연결

- `Attempt.mode`: practice / exam. 기존 행은 exam으로 유지한다.
- `Attempt.feature_analysis`: 응시를 시작할 때 검증한 분석 스냅샷. 이후 추출 규칙이 바뀌어도 그 응시의 분석 ID는 유지한다.
- `SelfAssessmentRevision`: Practice의 revision별 마디 오류·완료 여부·완료 시각. 초기 revision 0은 미채점이다.
- `GradingJob`: Exam의 기존 점수·피드백·인식 XML과 새 오류 근거. 수정이나 재시도에도 이전 작업을 보존한다.

Drills의 기존 기계채점은 유지한다. Drills 결과 서버 저장, 누적 통계·내 프로필 화면, 개인화 선생님 프롬프트, Daily Training 구성은 이번 단계에 포함하지 않았다. 서로 다른 신뢰도의 self / AI / 기계채점 관찰을 섞지 않고 이후 공통 기록으로 연결한다.

## 실행과 확인

기존 `backend/.env`를 유지하고 프로젝트 루트에서 실행한다. 시작 스크립트가 migration과 문제 등록을 적용한다.

```powershell
docker compose --env-file backend/.env up --build -d --wait
docker compose --env-file backend/.env exec -T api python manage.py test api solfege --noinput
```

서버 없이 가능한 검사는 다음과 같다.

```powershell
python scripts/test_features.py
python scripts/test_learning_records.py
python scripts/test_grading_contract.py
```

새 DB 회귀 검사는 AI 작업 미생성, 미채점/오류 없음 구분, 복수 유형·이력 보존, 재전송, 충돌 방지, 권한과 기존 Exam을 포함한다. Swift 검사는 필드·HTTP 계약·마디 터치 좌표·데모 제출/저장/복구 화면을 포함한다. GitHub CI가 Swift 패키지와 iPad 호스트 검사를 실행한다.

이 개발 환경에는 Django와 Swift/Xcode가 없고 Docker 엔진 접근도 제한되어 있다. 따라서 새 Django·iPad 테스트는 실행 환경/CI에서 확인해야 한다. 앞 단계 Feature 저장 DB 테스트는 사용자 환경에서 통과했다.

iPad에서 확인할 순서는 Practice 한 문제 제출 → 같은 마디에 음정+리듬 표시 → 임시 저장 → 홈/앱 복귀 → 채점 완료 → 오류 없이 완료도 별도 확인 → Exam에서 AI 결과 확인이다. 앱 변경은 새 IPA를 빌드·설치해야 반영된다.
