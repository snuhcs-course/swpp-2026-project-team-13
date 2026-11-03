# Feature v1 구현과 실행

2026년 11월 1일 기준. [팀원용 명세](../FEATURE-V1.md)와 [계산 규칙](EXTRACTION-RULES.md)을 구현한 첫 공통 분석기다.

## 이번 단계에서 구현한 것

- `backend/solfege/features/`: MusicXML·MXL 읽기, 정확한 분수 시간, written event와 attack 분리, 근거가 있는 특징, 마디·구간 집계.
- `select_span`: 원본 ID를 유지하고 구간 내부 특징과 반복 관계를 다시 계산한다. 외부 붙임줄 의존성을 표시한다.
- `FeatureAnalysis`: 원본 QuestionVersion에 연결한 분석 스냅샷과 해시·규칙 버전 저장.
- `analyze_question_features`: 등록 문제를 분석하고 동일 조건은 중복 저장하지 않는 관리 명령.
- `scripts/analyze_features.py`: Django·Docker 없이 한 파일 또는 구간을 JSON으로 내보내는 도구.

추출은 로컬 CPU에서 수행하고 LLM을 호출하지 않는다. 원본 악보와 기존 채점 결과를 변경하지 않는다. 난이도 실험을 자동으로 추가하거나 사용자 약점을 추정하지 않는다.

## 서버 없이 확인하기

프로젝트 루트에서 Python만으로 실행한다.

```powershell
python scripts/test_features.py
python scripts/analyze_features.py docs/feature-v1/example.musicxml --question-id fixture-v1 --output build/features/example.json
python scripts/analyze_features.py docs/feature-v1/example.musicxml --question-id fixture-v1 --first 2 --last 2 --output build/features/measure-2.json
```

첫 결과에는 전체 5도 하행이 1회, 두 번째 결과에는 0회다. 해당 하행은 1마디 마지막 음과 2마디 첫 음 사이에 있기 때문이다.

구간 결과는 전체 분석을 참조하는 view다. `source_analysis_key`와 원본 이벤트 ID를 보관하며, 독립된 새 문제 파일이나 전체 분석 스냅샷으로 가장하지 않는다. `standalone_status=ready`는 외부 붙임줄 수정이 필요 없다는 의미다. 실제 게임에서는 음역·지원 박자·발음 시작 유무 등 해당 게임의 조건도 확인해야 한다.

## DB에 저장하기

기존 서버와 같은 PostgreSQL 설정으로 실행한다. Django 명령은 backend 디렉터리 기준이다.

```powershell
python manage.py migrate --noinput
python manage.py analyze_question_features --dry-run --report .local/features-dry-run.json
python manage.py analyze_question_features --report .local/features-saved.json
```

Docker 서버에서는 프로젝트 루트에서 다음을 사용한다. 코드 변경을 반영하려면 먼저 이미지를 다시 빌드해야 한다.

```powershell
docker compose --env-file backend/.env up --build -d --wait
docker compose --env-file backend/.env exec -T api python manage.py test api solfege --noinput
docker compose --env-file backend/.env exec -T api python manage.py analyze_question_features --dry-run --report .local/features-dry-run.json
docker compose --env-file backend/.env exec -T api python manage.py analyze_question_features --report .local/features-saved.json
```

기본값은 등록된 문제의 현재 버전이다. `--all-versions`로 과거 버전까지 분석할 수 있고 `--question-id <UUID> --question-version <정수>`로 대상을 제한할 수 있다. Django 관리 명령의 `--version`은 프레임워크 기본 옵션이므로 문제 버전에는 사용하지 않는다. 명령은 문제를 새로 등록하지 않는다. 대상이 없으면 기존 `seed_questions` 등록 상태와 필터를 확인한다.

정답 자산의 크기와 SHA256을 등록 metadata와 먼저 대조한다. 불일치하거나 미지원 악보이면 문제별 사유를 report에 남기고 그 문제는 저장하지 않는다. 유효한 문제의 결과는 유지하며, 거부된 항목이 하나라도 있으면 명령의 종료 코드는 실패다. `partial`은 원본 이벤트는 읽었으나 일부 특징을 계산할 수 없다는 뜻이며 저장할 수 있다.

## 저장과 중복 처리

분석 식별자는 다음 배열을 키 정렬·공백 없는 ASCII escape JSON으로 직렬화한 UTF-8 바이트의 SHA256이다.

```text
[question_id, question_version, source_xml_sha256, schema_version, extractor_version, config]
```

내용이 같은 분석은 같은 행을 반환한다. 같은 식별자인데 결과나 원본 검수 메모가 다르면 `analysis_identity_conflict`로 중단하고 덮어쓰지 않는다. 기존 결과를 재해석하려면 추출기·설정 또는 문제 버전을 명시적으로 변경해야 한다. 검수 상태를 수정하는 별도 이력 관리 기능은 후속 범위다.

모델의 일반 save는 기존 행 갱신을 막고, 저장 서비스는 payload 해시도 대조한다. 내부에서 QuerySet.update나 직접 SQL로 수정하면 이 보호를 우회하므로 분석 테이블에는 그런 갱신을 사용하지 않는다. 새 Practice·Exam 응시는 해당 행 ID를 `Attempt.feature_analysis`에 고정한다.

## 검증 상태

Windows에서 표준 라이브러리 기반 계약 검사와 실제 수록 악보의 전체 변환을 확인했다. 계약 검사는 붙임줄·마디 경계·도수와 반음 구분·쉼표와 잇단음·정확한 반복·조표 미명시·박자별 기본 박·잘못된 입력·MXL rootfile을 포함한다.

수록된 124문제의 과거 버전을 포함한 248개 버전을 변환했다. 242개는 complete, 6개는 partial, 거부는 0개였다. 현재 버전만 보면 121개 complete, 3개 partial이다. partial 사유는 7/8 박 묶음 미명시, 지원 범위 밖 박자, 불완전한 빔 묶음이며 이를 정상 값 0으로 바꾸지 않았다. 모든 단일 마디 view의 수치와 근거 범위를 대조했고 원본 파일 해시가 유지됨을 확인했다.

DB 저장·중복 방지·원본 버전 보존·관리 명령에 대한 Django 테스트도 추가했다. Feature 저장 단계의 서버 테스트는 사용자 환경에서 통과했다. 이 개발 환경에서는 Docker 접근 거부와 로컬 Django 미설치로 직접 PostgreSQL 테스트를 실행하지 못한다. 새 Practice·Exam 변경은 추가 migration과 테스트를 포함하므로 위 서버 검사와 CI를 다시 확인해야 한다.

## 다음 연결 범위

[Practice·Exam 분리](../PRACTICE-EXAM.md)에서 응시마다 FeatureAnalysis를 고정하고, Practice 마디별 자기채점과 Exam AI 오류 근거를 연결했다. 미니게임 결과 서버 저장, 사용자 약점 통계·추천 모델과 학습 이력을 활용한 AI 개인화는 후속 범위다.
