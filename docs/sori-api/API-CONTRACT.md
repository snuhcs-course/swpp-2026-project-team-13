# SORI API 계약 v0.6.0

이 버전은 개인 연습용 iPad 앱과 Django 서버의 계약입니다. HTTP 경로는 /api/v1/을 유지합니다. 기존 v0.2.0의 서버 비교 산식 대신, 서버가 OpenRouter에 필기 이미지와 고정된 정답을 함께 보내 AI 평가와 한국어 피드백을 받습니다. 자기채점 및 감독형 Exam 모드는 이번 구현 범위 밖입니다.

## 재생 설정 v4와 문제 버전 2

새 응시는 playback_plan.version=4를 사용합니다. 기존 v2/v3 응시의 저장된 악보·재생 계획은 변경하지 않습니다. 새 앱과 서버를 함께 업데이트한 후 새 응시에서 변경을 확인합니다.

| 박자 | 표시 기준 | 기본값 | 권장 범위 |
|---|---|---:|---:|
| 4/4 | quarter / 4분음표 | 80 | 72–96 |
| 3/4 | quarter / 4분음표 | 80 | 72–96 |
| 6/8 | dotted_quarter / 점4분음표 | 55 | 48–66 |

tempo는 policy_id, beat_unit, bpm, minimum_bpm, maximum_bpm을 포함합니다. 기존 tempo_bpm은 4분음표 기준의 number이며, 6/8 기본값은 82.5입니다. 정수로 반올림하지 않습니다. MIDI에는 마이크로초 단위로 변환해 기록합니다.

템포 정책 원본은 backend/content/playback-settings.json입니다. resolve_tempo가 응시 생성 시 값을 선택하고 plan에 고정합니다. 이후 실력별 선택 로직은 selected_bpm으로 연결할 수 있습니다. 문제 metadata에 정책 기본값을 저장하지 않으므로 기본값 수정이 정답 버전의 불변성을 깨지 않습니다. 정책 수정 후 python scripts/build_question_assets.py로 데모의 TempoDefaults.swift를 갱신합니다.

악보의 source_tempo_bpm=96은 원본 표기 검증용이며 실제 재생 속도와 분리합니다. 생략된 기존 자산은 96으로 해석합니다. 악보 해시·마디·음표·중간 템포 변경 검사는 유지합니다.

문제 버전 2의 스케일은 C4 D4 E4 F4 G4 A4 B4 C5 B4 A4 G4 F4 E4 D4 C4입니다. 처음 14음은 8분음표이고 마지막 도는 마디 끝까지 유지합니다. 4/4는 2마디, 3/4·6/8은 3마디입니다. scale.to_measure와 score_assets.scale.measure_count를 따르며 2로 고정하지 않습니다. 새 권장 시간은 4/4 456초, 3/4 426초, 6/8 423초(올림)입니다.

새 instrument_profile_id는 sori-piano-v2입니다. 원본 현 진동·해머 어택·감쇠를 합성한 피아노형 SF2이며 실제 피아노 녹음은 아닙니다. v1 음원과 자산을 보관해 기존 응시를 지원합니다. 별도 외부 음원 다운로드나 라이선스 의존성은 없습니다.

## 통신과 인증

- 일반 요청·응답은 application/json, snake_case이며 성공 객체를 직접 반환합니다.
- 개발 토큰은 Authorization: Bearer <token>입니다. 회원가입 UI는 포함하지 않습니다.
- UUID, UTC ISO 8601 날짜, 모든 응답의 X-Request-ID를 사용합니다.
- 개인 API·MXL·제출 이미지는 인증하고 Cache-Control: private, no-store를 사용합니다. 다른 사용자의 응시·답안은 404입니다.
- 경로의 마지막 /를 포함합니다. 인증 자산은 API와 같은 origin이고 리다이렉트하지 않습니다.
- iPad의 Debug 빌드는 LAN HTTP를 허용합니다. Release는 HTTPS를 요구합니다.

## 문제와 악보

준비된 3문제는 각각 6/8, 4/4, 3/4의 높은음자리표 단선율 8마디입니다. 기존 정답 XML의 음정·길이·부점·임시표·쉼표·붙임줄·셋잇단음표를 보존합니다. XML의 인쇄용 메타데이터와 DTD를 제거하고, 원본 표기 템포 96(4분음표 기준)과 C Major 메타데이터를 명시한 MXL을 제공합니다.

새 악보 프로파일은 sori-monophonic-v2입니다. 기존 v1에 3/4·6/8, 16분음표, 3:2 셋잇단음표, 빔 표기를 추가합니다. 임의의 MusicXML 전체를 지원한다는 뜻은 아닙니다. 프론트는 예전 v1 fixture도 계속 읽습니다.

MXL은 정확히 mimetype, META-INF/container.xml, score.xml 세 엔트리를 갖습니다. 압축 1 MiB, 해제 합계 4 MiB 한도입니다. main 8마디, scale 2마디 또는 3마디, part_id=P1, MusicXML 4.0입니다. 크기와 SHA-256을 검사합니다.

문제 버전과 파일 bytes는 불변입니다. 응시 생성 시 문제와 재생 계획의 스냅샷을 고정합니다. 정답 main MXL은 로컬 합성 재생을 위해 제출 전 내려받지만, 앱은 제출 후에만 악보를 표시합니다. 정답을 기기에 전달하지 않는 감독형 시험 구조가 아닙니다.

## 답안 이미지

- 논리 캔버스 1330 × 846, 출력 2배, PNG 2660 × 1692입니다.
- 8비트 RGB 또는 완전히 불투명한 RGBA, 흰 배경과 검은 필기입니다.
- 서버가 제공한 빈 오선과 필기를 합성하고, UI·피드백·잘라내기를 포함하지 않습니다.
- 파일 10 MiB, multipart 전체 11 MiB 한도입니다.
- sheet_layout_id는 박자별 staff-8bars-6-8-v2, staff-8bars-4-4-v2, staff-8bars-3-4-v2입니다.
- 마디 좌표와 캔버스 크기는 기존 두 단·각 네 마디 규격을 유지합니다. 템플릿이 바뀌므로 각자 새 ID와 해시를 사용합니다.
- PencilKit 원본은 기기에 보존하며 서버에는 PNG만 보냅니다.

## API 목록

아래 경로 앞에 /api/v1을 붙입니다. 요청·응답 필드의 전체 스키마는 openapi.json을 따릅니다.

| 메서드 | 경로 | 성공 | 동작 |
|---|---|---|---|
| GET / PATCH | /me/ | 200 | 사용자·학습 목표 |
| GET | /questions/ | 200 | 3문제의 페이지 목록 |
| GET | /questions/{id}/ | 200 | 안내·오선·main/scale 자산 |
| GET | /questions/{id}/versions/{version}/scores/{kind}/ | 200 | main 또는 scale MXL bytes |
| POST | /attempts/ | 201 | question_id, question_version으로 응시 생성 |
| GET | /attempts/{id}/ | 200 | 저장된 응시·제출 답안 복구 |
| POST | /attempts/{id}/start/ | 200 | 자산·피아노 준비 후 시작, 본문 없음 |
| POST | /attempts/{id}/answers/ | 201 | multipart PNG 업로드 |
| GET | /attempts/{id}/answers/{answer_id}/image/ | 200 | 업로드한 원본 PNG |
| POST | /attempts/{id}/submit/ | 202 | 명시한 answer_id로 최종 제출 |
| GET | /attempts/{id}/result/ | 200 | 채점 진행·결과 |
| POST | /attempts/{id}/grading-retries/ | 202 | 실패한 같은 답안 재시도, 본문 없음 |

공개 오선은 /assets/sheets/{layout_id}.png에서 제공합니다. 기존 /api/health/도 유지합니다.

## 응시·제출·재전송

응시 상태는 ready → in_progress → submitted입니다. 시작 반복 호출은 타이머를 초기화하지 않습니다. 권장 시간은 아래 전체 재생·필기 시간표로 계산하며, 초과해도 제출할 수 있습니다. 기존 응시는 생성 당시의 계획과 시간을 유지합니다.

업로드와 제출은 별개입니다. multipart 필드는 image, client_answer_id, answer_format_version(텍스트 1), sheet_layout_id입니다. 서버는 실제 PNG와 규격을 검사하고 원본 bytes·해시를 저장합니다.

생성·업로드·제출·재시도에는 Idempotency-Key(UUID)를 보냅니다. 같은 사용자·경로·키·본문을 재전송하면 최초 영수증을 반환합니다. 같은 키의 다른 본문은 409 IDEMPOTENCY_KEY_REUSED, 진행 중인 동일 요청은 409 REQUEST_IN_PROGRESS입니다.

(attempt, client_answer_id)는 유일합니다. 동일 이미지·ID의 업로드 영수증은 제출 후에도 재조회할 수 있습니다. 제출은 answer_id를 고정하며 마지막 업로드를 임의 선택하지 않습니다. 같은 답안 재제출은 새 채점 작업을 만들지 않습니다. 다른 답안으로 바꾸는 요청은 409입니다.

최종 제출·선택 답안·채점 작업을 하나의 DB 트랜잭션에 저장합니다. 별도 워커가 DB의 작업을 가져가므로 HTTP 프로세스 재시작이나 앱 화면 이탈로 작업을 잃지 않습니다. 파일 저장이 성공한 다음 업로드 성공을 반환합니다.


## v3/v4의 공통 재생 시간표

새 응시의 playback_plan.version은 4입니다. 기존 저장 응시의 version=2/3은 변경하지 않습니다.

1. 시작 후 2초 대기 → 스케일 재생
2. 스케일 종료 후 2초 대기 → 예비박 1마디 → 첫 1–8마디 전체 재생
3. 필기 20초 → 1–2 → 20초 → 1–2 → 20초 → 1–4 → 20초 → 3–4 → 20초 → 3–6 → 20초 → 5–6 → 20초 → 5–8 → 20초 → 7–8 → 20초 → 7–8
4. 필기 20초 → 예비박 1마디 → 마지막 1–8마디 전체 재생 → 마지막 필기 120초

예비박은 처음과 마지막 전체 재생 앞에만 있으며, 첫 박을 크게 냅니다. 4/4는 4번, 3/4는 3번, 6/8은 8분음표 간격으로 6번 클릭합니다. 6/8을 두 번의 점4분음표 클릭으로 바꾸지 않습니다.
예비박 마지막 클릭 이후 한 박 간격이 지나면 문제의 첫 박입니다. 클릭과 문제는 하나의 MIDI 시퀀스에서 재생하므로 중간에 로딩·별도 휴지가 없습니다.

initial_delay_ms=2000, pause_after_scale_ms=2000, count_in.before_step_orders=[1,11]입니다.
count_in에는 measures=1, beats_per_measure/beat_unit=문제 박자표, accent_velocity=110, velocity=70, profile_id=sori-click-v1을 보냅니다.
steps의 pause_after_ms는 1~10번째 20000, 마지막 120000입니다. 기존 release_tail_ms=300은 이 휴지 시간에 포함하며 별도로 더하지 않습니다.

현재 4분음표 BPM 96에서 전체 길이는 4/4 문제 434초, 3/4·6/8 문제 406.5초입니다. recommended_duration_seconds는 각각 434, 407로 올림합니다.
문제 자산과 저장된 문제 버전의 bytes·해시는 그대로 유지하며, 현재 목록·상세 안내와 새 응시 스냅샷의 권장 시간을 계산해서 제공합니다.

필기 대기 중 일시정지는 남은 시간을 저장해 이어집니다. 재생 도중 일시정지는 현재 구간 처음부터 재개하며, 전체 재생이면 예비박도 다시 제공합니다.
최종 2분이 지나면 제출 안내를 표시합니다. 현재 연습의 advisory 정책대로 자동 제출·자동 편집 잠금은 하지 않습니다.

## AI 평가

- grading_mode=automatic, grading_version=ai-melodic-v1입니다. 점수·음정/리듬 평가는 학습 참고용 AI 추정값이며 기존 50:50 편집 거리 산식과 다릅니다.
- AI 호출 한 번으로 보이는 필기의 MusicXML, 점수, 마디별 오류, 다정한 한국어 피드백을 요청합니다. 정답에 맞춰 필기 내용을 보정하지 않도록 지시합니다.
- 모델과 reasoning effort는 서버 설정이며 작업 생성 시 고정합니다. 기본 설정은 기존 실험의 openai/gpt-6.1-sol, medium입니다.
- 프롬프트 원문·버전, 모델·설정, 응답, 사용량과 provider 요청 ID를 작업에 보관합니다. 키는 앱·응답·로그에 포함하지 않습니다.
- 서버가 JSON 구조·점수 범위·마디 번호를 검증합니다. 문법 검증이 음악적 정확도를 보장하지는 않습니다.
- 좌표는 AI가 추측하지 않습니다. 초기 주석은 서버의 고정 마디 영역에 표시합니다. 위치가 불명확하면 measure와 bbox는 null입니다.

| status | 점수 | 의미 |
|---|---|---|
| queued | null | 저장·대기 |
| processing | null | AI 요청 처리 |
| completed | 숫자, 0도 유효 | AI 평가 완료 |
| needs_review | null | 필기를 확실히 평가하기 어려움 |
| failed | null | 연결·시간 초과·응답 검증 실패 |

AI가 한 번에 처리하므로 진행 중 stage=recognizing으로 표시하고 완료 시 done으로 바꿉니다. 내부의 세부 진행 단계를 추정해서 표시하지 않습니다. needs_review도 recognizing입니다.

대기 중 2초 간격으로 결과를 조회합니다. 60초 이후에는 화면을 나갔다 나중에 돌아올 수 있습니다. 앱을 닫아도 서버 작업은 계속됩니다. 초기 서버 제한은 240초이며 별도 HTTP 자식 프로세스를 종료해 강제 적용합니다. 작업 lease 만료도 failed로 복구합니다.

실패하고 retryable=true일 때 같은 답안으로 새 job_id를 발급합니다. 오래된 작업의 늦은 응답이 새 결과를 덮어쓰지 않습니다. 초기 설정은 응시당 최대 3개 작업이며 서버 설정으로 조정합니다. 네트워크 결과가 불명확한 AI 요청을 서버가 자동 반복해 과금하지 않습니다. 재시도는 명시적 요청입니다.

## 오류와 검증

오류 객체는 error(code, message, fields, retry_after_ms), request_id입니다. HTTP 요청 실패와 채점 작업 실패를 구분합니다. 결과를 정상 조회해 failed를 받는 것은 HTTP 200입니다.

원본 v0.2.0 examples는 구버전 클라이언트 회귀 검증용으로 유지합니다. 이번 세 문제의 실제 예시는 question-excerpt-1.json부터 question-excerpt-3.json, questions-v0.4.json 및 attempt-ready-v3.json입니다. 실제 구현·검증 범위는 ../VALIDATION.md를 확인합니다.


## v0.6.0: 정답 이미지, 표기 관습, 악기 음색

문제 상세·응시의 question에 선택 필드 correct_score가 추가됩니다. url, content_type=image/png, sha256, size_bytes, pixel_width, pixel_height, renderer를 포함합니다. GET /api/v1/questions/{id}/versions/{version}/display/는 Bearer 인증과 Accept: image/png를 사용하며 기존 악보 파일과 같은 버전 접근 규칙을 적용합니다. 원본 main.mxl의 SHA-256으로 사전 생성 이미지를 연결하므로 DB 문제 metadata와 응시 스냅샷을 수정할 필요가 없습니다. 현재 개인 연습용 client_readable_practice 정책은 유지됩니다.

정답 이미지는 MuseScore Studio 4.6.3 + scripts/engraving/compact-v1.mss로 사전 생성합니다. 마디 번호 없이 4+4마디 두 줄이며, 직전 마디의 변화음을 환기하는 주의 임시표를 표시용 사본에 추가합니다. 원본 MusicXML·재생 데이터·채점 기준은 수정하지 않습니다. 앱은 PNG 바이트·해시·크기를 검증하고 응시별로 캐시합니다. 미리보기 생성은 서버 요청/LLM 대기 경로 밖에서 수행합니다.

annotations.type에 notation_error(표기 관습 오류), notation_suggestion(권장 표기)을 추가합니다. note_index와 end_note_index는 선택 가능한 nullable 정수(1~128)로 마디 안의 음표/쉼표 순서이며, 마지막 순서는 첫 순서 이상이어야 합니다. 기존 기록에는 두 필드가 없습니다. bbox는 여전히 제출 전체 이미지의 마디 범위이며 음표 좌표가 아닙니다. 프론트엔드는 선택한 피드백의 마디만 강조하고, 설명에 음표 순서를 표시합니다.

새 채점 프롬프트 버전은 sori-feedback-2-notation-1입니다. grading-prompt-v2.txt + notation-rules-v1.txt 전문을 각 GradingJob에 저장합니다. 호출은 기존과 같은 이미지+정답 1회이며 자동 유료 재시도는 없습니다. 권장 제자리표 생략과 빔 묶음 지적은 이번 버전에서 음정·리듬 점수에 추가 감점하지 않습니다. 실제 음높이·길이 오류와 별도로 설명합니다. 규칙을 프롬프트에 넣었다고 인식 정확도를 보장하지 않으며 실제 필기 평가는 별도 검증이 필요합니다.

음색은 사용자 기기의 로컬 선호입니다. 기존 playback_plan의 악보·템포·대기 시간·예비박 계약은 변경하지 않습니다. 악기 프로필은 문제의 원본 기본값이며, 앱 설정의 GeneralUser GS 프리셋이 실제 문제/스케일 음색을 선택합니다. 음색 ID는 서버에 전송하거나 점수에 사용하지 않습니다.
