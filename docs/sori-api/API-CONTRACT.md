# SORI iPad 청음 시험 API 계약 v0.2.0

작성일: 2026-10-23 · 대상: SwiftUI 담당 1명 / Django 담당 1명

이 문서는 **문제·스케일은 MXL로 다운로드하고 iPad에서 악보 렌더링·피아노 합성 재생을 수행하며, 답안은 PNG로 업로드해 서버에서 인식·채점한다**는 개발 기준이다. 사용자가 확인한 전제는 개인 연습용이고 정답 데이터가 기기에 있어도 괜찮으며 일정한 템포의 피아노 합성음이면 충분하다는 것이다. 이미지 크기, 제한 용량, 권장 시간, 점수 산식 등 추가로 필요한 값은 이 문서에서 제안 기본값으로 정했다. 변경하려면 구현 전에 두 사람이 문서와 예시를 함께 수정한다.

실제 API 서버나 인식 엔진을 구현·배포한 결과물이 아니다. 포함된 `.example` 주소는 교체해야 하는 예시 주소다. 테스트용 오리지널 문제·스케일 MXL은 실제 파일로 제공하지만 피아노 SoundFont와 iPad 렌더러·플레이어 구현은 포함하지 않는다. 오선 템플릿 PNG는 제공된 Figma의 빈 답안 영역에서 실제로 추출했다. 답안 예시 JSON의 이미지 해시·용량과 채점 수치는 설명용 데이터이며 실제 학생 답안의 분석 결과가 아니다.

## 1. 함께 관리할 파일

| 파일 | 쓰임새 |
|---|---|
| `API-CONTRACT.md` | 동작 규칙과 구현 설명. OpenAPI에 담기 어려운 상태·재시도·채점 규칙도 계약에 포함한다. |
| `openapi.json` | OpenAPI 3.0.3 요청·응답·자료형. Swagger Editor나 Postman 등에서 가져올 수 있다. |
| `examples/*.json` | SwiftUI Mock과 Django 응답 검증에 함께 사용하는 예시. |
| `examples/manifest.json` | 각 예시 파일이 대응하는 스키마 목록. |
| `assets/staff-8bars-v1.png` | 양쪽이 공유할 2660 × 1692 픽셀의 기본 오선 이미지. |
| `assets/staff-8bars-v1.layout.json` | 템플릿의 논리 좌표·오선·마디 경계. URL은 배포 주소로 교체한다. |
| `assets/practice-01-main.mxl` | 구간 재생 검증용 오리지널 8마디 MusicXML 4.0 문제. |
| `assets/practice-01-scale.mxl` | C4~C5 상행 스케일 2마디. |
| `assets/practice-01.expected-events.json` | 붙임줄을 합친 예상 이벤트와 경계 구간의 결과. API 응답이 아닌 개발 검사 데이터. |
| `MXL-ARCHITECTURE.md` | 방식의 객관적 평가, iPad 구현 선택지, MXL 프로파일·구간 생성 상세. |
| `VALIDATION.txt` | 이번 전달물의 참조·예시·이미지·MXL 규격 검사 결과와 검사 범위. |

개발 저장소에 위 파일을 함께 넣고 PR로 변경한다. JSON 스키마와 이 문서가 불일치하면 어느 한쪽을 추측해서 구현하지 말고 같은 PR에서 정합성을 맞춘다. URL `/api/v1/`의 v1은 주요 API 호환성 버전이고, 계약 문서의 0.2.0은 설계 개정 번호다. 아직 서비스에 배포하지 않은 계약을 수정하는 것이므로 `/api/v1/`은 유지한다. 0.1의 오디오 파일 응답을 이미 운영 배포했다면 이 변경은 호환되지 않으므로 별도 API 버전으로 배포해야 한다. 이전 0.1 전체 묶음은 `SORI-API-v0.1.0.zip`에 보존했다.

## 2. 첫 개발 범위와 담당

첫 범위는 사용자 목표 저장, 준비된 단선율 문제 목록·안내, 응시 시작, 스케일 및 11개 구간 재생, Pencil 자유 필기, 이미지 업로드, 최종 제출, 비동기 채점 상태와 결과다. Daily Training, 집중 연습, 기출 아카이브, 회원가입·로그인 UI, 사용자 답안 MXL 업로드, 문제 관리용 관리자 업로드 API, 서버의 PencilKit 원본 보관은 이 시험 API 범위에 포함하지 않는다. 출제용 MXL은 초기에는 백엔드 관리 도구로 등록하고 검증한다.

**SwiftUI 담당:** PencilKit 캔버스, 오선과 필기의 합성, 로컬 필기 원본 보관, 파일 업로드, MXL 검증·파싱·렌더링·로컬 MIDI 생성·피아노 합성 재생, 시간 표시, 상태별 화면, 통신 재시도와 복귀 처리.

**Django 담당:** MXL 원본·메타데이터·구간 재생 계획·빈 오선 템플릿 제공, 사용자별 응시 관리, 이미지 검증·보관, 제출 확정, 중복 요청 방지, 작업 큐, 악보 인식 연동, 채점과 피드백, 결과 API.

API와 인식 엔진은 별개다. 엔진이 아직 없더라도 백엔드는 같은 응답 형식의 데모 결과를 제공해 프론트 개발을 진행할 수 있다. `grading_mode=demo`를 명시하며 실제 채점처럼 표시하지 않는다. 서버 설정으로 데모/실제 모드를 정하고 응시 생성 시 고정한다. 사용자가 요청에 모드를 넣어 바꾸지는 못한다.

## 3. 인증과 공통 통신 규칙

### 3.1 개발 중 인증

시험 API는 처음부터 `Authorization: Bearer <token>`을 요구한다. 토큰은 내부 구현이 JWT인지 불투명 토큰인지 프론트가 해석하지 않는 문자열이다. 초기 개발에서는 백엔드가 개발자별 테스트 사용자와 토큰을 발급하고, 토큰에 연결된 사용자로 `/me/`를 조회한다. 기본 학습 목표는 `other`로 만들 수 있다.

토큰은 앱의 기기별 개발 설정 또는 Keychain에 두고 저장소·공유 예시 JSON에 넣지 않는다. 회원가입·로그인·갱신 엔드포인트는 별도 인증 계약으로 추가한다. 그 전에도 테스트 토큰으로 아래 13개 시험 API를 모두 개발할 수 있다. 토큰이 유효하지 않으면 `401 AUTHENTICATION_REQUIRED`이며 로컬 답안은 보존한다. 인증 복구 전에는 요청을 계속 반복하지 않는다.

서버는 요청 본문의 사용자 ID를 신뢰하지 않고 인증 사용자로 소유권을 검사한다. 타인의 응시·답안·결과는 `404 RESOURCE_NOT_FOUND`로 응답한다. 답안 이미지 다운로드에도 같은 인증이 필요하다. 빈 오선 템플릿은 인증 없는 정적 파일 호스트에 둘 수 있다. 문제·스케일 MXL은 버전 고정된 인증 API로 다운로드한다. 로컬 캐시를 막지 않지만 HTTP 응답은 private, no-store로 통일한다.

### 3.2 형식

| 항목 | 규칙 |
|---|---|
| API 기준 경로 | `https://<실제 서버>/api/v1/` |
| 경로 끝 `/` | 항상 포함. 업로드·POST 요청의 리다이렉트에 의존하지 않는다. |
| 일반 요청 | `Content-Type: application/json`, `Accept: application/json` |
| 이미지 업로드 | `multipart/form-data; boundary=...` |
| 이미지 다운로드 | `Accept: image/png` |
| 문제·스케일 다운로드 | `Accept: application/vnd.recordare.musicxml` — JSON/Base64가 아닌 MXL bytes |
| 필드 이름 | `snake_case` |
| ID | UUID 문자열. 템플릿 ID와 주석 ID는 별도 문자열. |
| 날짜 | UTC RFC 3339/ISO 8601 문자열. 예: `2026-10-23T06:00:00Z`. 소수 초도 허용한다. |
| 단위 | 시험 길이: 초. 오디오·대기 시간: 밀리초. 이미지 크기: 픽셀. |
| 점수 | 총점 0~100 정수. 음정·리듬 정확도 0~100, 소수 1자리까지. |
| 성공 응답 | 최상위 객체를 직접 반환. `data`·`success` 포장 필드 없음. |
| 미정 값 | 계약에 있는 응답 키는 생략하지 않고 `null` 반환. 목록은 `[]`. |
| 요청 검증 | 모르는 요청 필드와 잘못된 타입은 400. JSON 숫자를 문자열로 보내지 않는다. multipart 텍스트 필드는 예외. |
| 진단 | 모든 응답에 서버가 생성한 `X-Request-ID`. 오류 본문 `request_id`와 같은 값. |
| 캐시 | JSON API와 개인 답안 이미지: `Cache-Control: private, no-store`. 버전 고정 공개 자산은 별도 캐시 가능. |

프론트는 응답의 추가 필드를 무시할 수 있게 디코딩한다. 새 enum 값은 앱을 종료시키지 말고 '지원하지 않는 상태'로 처리한다. 서버는 새 enum을 기존 앱에 보내기 전에 호환성을 확인한다. enum 추가도 자동으로 호환된다고 보지 않는다.

### 3.3 응답 코드

`200` 조회·프로필 수정·시작, `201` 응시·답안 생성, `202` 최종 제출·채점 재시도 접수다. `202`는 채점 완료가 아니다. 생성 응답에는 `Location`, 작업 접수 응답에는 결과 조회 URL인 `Location`을 넣는다.

이미 존재하는 채점 상태를 조회하면 대기·실패 상태도 `200`이다. HTTP 요청이 성공했고 그 결과로 '채점 실패'를 조회한 것이기 때문이다.

## 4. 문제·응시·답안·채점의 관계

`Question`은 출제 콘텐츠, `Attempt`는 사용자가 한 번 푼 기록, `Answer`는 업로드된 한 장의 이미지, `Grading`은 제출한 특정 이미지의 분석 결과다.

- 같은 문제를 다시 풀면 새 `Attempt`를 생성한다.
- 한 응시에 여러 `Answer`를 업로드할 수 있다. 각 답안 이미지는 불변이다.
- `submit`에서 **어느 `answer_id`를 채점할지 명시**한다. 마지막 업로드를 서버가 임의로 고르지 않는다.
- 응시 생성 시 문제 정보·레이아웃·재생 계획의 스냅샷을 고정한다. 기존 응시를 시작하거나 복구할 때도 현재 문제 데이터로 덮어쓰지 않는다.
- 새 문제 버전이 게시되어도 진행 중인 응시의 콘텐츠와 자산을 유지한다.
- **개인 연습용이므로 정답 음표가 들어 있는 main MXL을 iPad에 전달한다.** `content_policy=client_readable_practice`로 명시한다. 이 구조는 감독형 시험의 정답 은닉을 보장하지 않는다.
- `score_visibility=after_submission`은 앱의 표시 규칙이다. 응시 중에는 빈 오선만 보여주고, 최종 제출 이후 정답 MXL을 렌더링해 비교할 수 있다. 파일은 이미 기기에 있으므로 암호화나 UI 숨김으로 정답이 기기에 없다고 주장하지 않는다.
- 채점의 정답은 서버가 고정한 같은 버전·해시의 MXL에서 만든다. 클라이언트가 보낸 MIDI·이벤트·점수를 채점 기준으로 사용하지 않는다.

## 5. 답안 이미지 규격 — 양쪽이 가장 먼저 맞출 부분

### 5.1 내보내기 계약

| 항목 | v1 값 |
|---|---|
| 필드명 | `image` |
| 파일 형식·MIME | PNG / `image/png` |
| 레이아웃 ID | `staff-8bars-v1` |
| 답안 포맷 버전 | `answer_format_version=1` |
| 논리 캔버스 | 1330 × 846 단위 |
| 출력 배율 | 2 |
| 실제 PNG | **2660 × 1692 픽셀** |
| 색상 | 8비트 RGB 또는 RGBA. RGBA는 모든 픽셀 alpha=255. sRGB로 출력. |
| 배경 | 흰색. 서버 제공 기본 오선 이미지와 필기를 합성. |
| 필기 | 검정색 펜. 초기 기본 굵기 약 2 논리 단위; 형광펜·색상 도구는 첫 버전에서 제공하지 않음. |
| 포함 | 오선·높은음자리표·박자표·사용자 필기 |
| 제외 | 상단바·타이머·도구막대·선택 표시·빨간펜 피드백 |
| 파일 한도 | 10 MiB = 10,485,760 bytes |
| multipart 전체 한도 | 11 MiB = 11,534,336 bytes |

서버가 제공한 템플릿을 그대로 사용한다. 첫 버전 템플릿은 C Major·4/4·높은음자리표·2단 8마디 전용이다. 다른 조표·박자·단 수의 문제를 추가할 때는 적합한 템플릿과 계약을 먼저 추가한다.

출력 과정은 **흰 배경 → 같은 좌표의 템플릿 → 같은 좌표의 필기** 순서다. PencilKit의 `image(from:scale:)`는 필기 이미지를 얻는 데 사용할 수 있지만, 별도 오선 배경은 앱이 직접 합성해야 한다. [Apple PKDrawing 문서](https://developer.apple.com/documentation/pencilkit/pkdrawing-swift.struct?language=objc)

**`drawing.bounds`에 맞춰 잘라서 보내지 않는다.** 필기 내용이 적을 때 이미지 크기와 원점이 바뀌면 인식 위치·오선 높이·피드백 좌표가 모두 틀어진다. 항상 전체 논리 사각형 `(0,0,1330,846)`을 출력한다. 기기의 `UIScreen.scale`에 의존하지 않고 2배 출력 규격을 명시한다. 확대·스크롤 화면에서도 원래 캔버스 좌표로 되돌려 내보낸다. 펜 굵기 역시 화면 확대율에 따라 원본 좌표가 변하지 않아야 한다.

화면이 작으면 오선과 필기를 **같은 비율**로 축소한다. 너비와 높이를 서로 다른 비율로 늘리지 않는다. 원본은 기기에서 계속 보관하므로 일시적 통신 실패나 앱 재실행 때문에 필기를 잃지 않아야 한다. 서버는 이번 계약에서 PencilKit 파일을 받지 않는다. PNG만으로 편집 가능한 PencilKit 원본을 복구할 수 있다고 가정하지 않는다.

### 5.2 좌표계와 레이아웃

논리 좌표 원점은 답안 영역의 왼쪽 위, x는 오른쪽, y는 아래쪽이다. 픽셀 좌표는 논리 좌표의 2배다.

| 단 | 마디 | 오선 y 좌표 | 마디 경계 x 좌표 |
|---|---|---|---|
| 1 | 1~4 | 164, 176, 188, 200, 212 | 54, 450, 725, 1000, 1276 |
| 2 | 5~8 | 499, 511, 523, 535, 547 | 54, 397, 690, 983, 1276 |

위 값은 논리 좌표다. 첫 마디에는 음자리표·박자표 공간이 있으므로 마디마다 폭이 같다고 가정하지 않는다. 서버는 `sheet_layout_id`로 같은 레이아웃을 찾는다. 클라이언트가 임의로 오선 좌표를 보내 서버 기준을 바꾸지는 못한다. 위치를 바꾸는 템플릿 수정은 새 ID를 발급한다.

기본 이미지의 SHA-256은 `assets/staff-8bars-v1.layout.json`과 문제 응답의 `template_sha256`에 있다. 배포할 때 PNG bytes를 그대로 사용하고 URL만 바꾼다.

## 6. 전체 API 목록과 호출 순서

아래 경로에는 모두 `/api/v1` 접두사를 붙인다. 총 13개 operation이다.

| 순서 | 메서드 | 경로 | 정상 코드 | 의미 |
|---|---|---|---|---|
| 1 | GET | `/me/` | 200 | 현재 사용자와 목표 |
| 2 | PATCH | `/me/` | 200 | 사용자 목표 저장 |
| 3 | GET | `/questions/` | 200 | 이용 가능한 연습문제 목록 |
| 4 | GET | `/questions/{question_id}/` | 200 | 문제 안내와 템플릿 |
| 5 | POST | `/attempts/` | 201 | 응시 생성, 콘텐츠 버전 고정 |
| 6 | GET | `/attempts/{attempt_id}/` | 200 | 응시 복구·시간·최신 업로드 조회 |
| 7 | POST | `/attempts/{attempt_id}/start/` | 200 | 다운로드 완료 후 시험 시작 |
| 8 | POST | `/attempts/{attempt_id}/answers/` | 201 | 불변 답안 이미지 생성 |
| 9 | GET | `/attempts/{attempt_id}/answers/{answer_id}/image/` | 200 | 개인 답안 PNG 다운로드 |
| 10 | POST | `/attempts/{attempt_id}/submit/` | 202 | 선택한 답안을 제출하고 채점 예약 |
| 11 | GET | `/attempts/{attempt_id}/result/` | 200 | 채점 진행 상태 또는 결과 |
| 12 | POST | `/attempts/{attempt_id}/grading-retries/` | 202 | 재시도 가능한 채점 실패 재실행 |
| 13 | GET | `/questions/{question_id}/versions/{question_version}/scores/{score_kind}/` | 200 | main 또는 scale MXL bytes |

앱의 기본 흐름은 `문제 조회 → 응시 생성 → 템플릿·MXL 다운로드 → MXL 파싱·구간 생성·피아노 준비 → start → 필기 → answers 업로드 → submit → result 조회`다. 업로드와 제출은 서로 다르다. 업로드만으로 필기를 잠그거나 채점하지 않는다.

## 7. API별 상세 계약

### 7.1 사용자

`GET /me/` 응답은 `examples/me.json`이다. `PATCH /me/`는 `{"learning_goal":"college_entrance"}`를 받고 수정한 전체 프로필을 반환한다. 이번 버전에는 표시 이름 수정 기능을 넣지 않는다.

| learning_goal | 화면의 선택 |
|---|---|
| `arts_school_entrance` | 예중·예고 입시 |
| `arts_school_student` | 예중·예고 재학생 |
| `college_entrance` | 음대 입시 |
| `teacher_exam` | 중등 음악 임용 |
| `other` | 기타 |

### 7.2 문제 목록과 안내

`GET /questions/?page=1&page_size=20`은 `count`, `next`, `previous`, `results`를 반환한다. `page_size` 기본 20, 최대 50. `next`·`previous`는 API의 절대 URL 또는 `null`이다. 잘못된 범위·없는 페이지는 `400 INVALID_PAGE`; 문제 0개일 때 1페이지는 `200`과 빈 목록이다. 정렬은 백엔드의 출제 순서이며 동일 배포 데이터에서는 고정한다.

`GET /questions/{id}/`는 안내 문구, 조성, 박자, 8마디, 권장 시간, `time_policy`, 오선 템플릿과 `score_assets.main`, `score_assets.scale`의 MXL 파일 설명을 반환한다. main MXL에는 정답 음표가 포함된다. 이번 범위에서 `source=practice`, `clef=treble`, `time_policy=advisory`다. 조회한 `id`와 `version`을 응시 생성에 사용한다. 예시: `examples/question.json`.

### 7.2a 버전 고정 MXL 다운로드

`GET /questions/{question_id}/versions/{question_version}/scores/{score_kind}/`

`score_kind`는 `main` 또는 `scale`이고 Bearer 인증이 필요하다. `score_assets`의 URL이 이 API를 가리킨다. `200 application/vnd.recordare.musicxml`로 실제 MXL bytes를 반환한다. 해당 버전이 보관된 자신의 응시에서 사용 중이면 현재 문제 목록에서 숨겨졌어도 파일을 받을 수 있다. 다른 문제 버전으로 자동 대체하지 않는다.

파일 설명 필드는 `url`, `content_type`, `sha256`, `size_bytes`, `musicxml_version`, `profile`, `part_id`, `measure_count`다. main은 8마디, scale은 2마디, `part_id=P1`, `musicxml_version=4.0`, `profile=sori-monophonic-v1`이다. 서버는 게시한 파일 bytes를 변경하지 않고, 내용이 바뀌면 question_version을 올린다.

iPad는 다운로드 bytes의 SHA-256과 실제 용량을 검사하고, MXL을 파싱하여 프로파일·마디 수·박자·조성·템포가 응시의 스냅샷과 맞는지 확인한다. 인증 헤더는 같은 API origin에만 전달한다. 바뀐 파일·지원하지 않는 악보·피아노 리소스 누락을 조용히 무시하거나 임의 템포로 재생하지 않는다.

다운로드할 압축 파일 최대 1 MiB, 압축 해제 총합 최대 4 MiB, ZIP 엔트리는 `mimetype`, `META-INF/container.xml`, `score.xml` 세 개만 허용한다. MXL 내부 XML의 DTD·외부 엔티티·외부 리소스를 사용하지 않는다. 구체적인 지원 음악 기호와 검증 규칙은 `MXL-ARCHITECTURE.md`를 따른다. 이 한도는 문제 파일 다운로드·게시 검증 기준이며 답안 PNG의 10 MiB 한도와 다르다.

### 7.3 응시 생성

`POST /attempts/` + `Idempotency-Key: <요청별 UUID>`

```json
{
  "question_id": "22222222-2222-4222-8222-222222222222",
  "question_version": 1
}
```

서버는 `ready` 상태의 응시와 고정된 문제·재생 계획을 반환한다. `started_at`, `recommended_end_at`, `submitted_at`, `submitted_answer_id`, `latest_answer`는 `null`이다. 타이머는 아직 시작하지 않는다. 문제 버전이 바뀌었으면 `409 QUESTION_VERSION_MISMATCH`; 클라이언트는 안내를 다시 조회하고 새 논리 요청의 키로 생성한다. 예시: `examples/attempt-ready.json`.

`GET /attempts/{id}/`도 같은 `Attempt` 형태를 반환한다. `server_time`은 매 조회 시 현재 서버 시각이다. `latest_answer`는 서버가 마지막으로 접수한 답안 정보이고, 업로드 중 네트워크 순서가 바뀔 수 있으므로 '사용자가 제출하려던 이미지'를 뜻하지 않는다.

### 7.4 시험 시작과 시간

`POST /attempts/{id}/start/`는 본문을 보내지 않는다. 템플릿과 main/scale MXL을 다운로드하고 해시·프로파일을 검증한 뒤, 로컬 이벤트·11개 재생 구간을 생성하고 앱에 포함된 피아노 리소스를 준비한 후 호출한다. `ready → in_progress`로 바꾸고 다음 값을 반환한다.

```json
{
  "started_at": "2026-10-23T06:00:10Z",
  "recommended_end_at": "2026-10-23T06:05:10Z",
  "server_time": "2026-10-23T06:00:10Z"
}
```

위 코드는 전체 응답 중 시간 필드 발췌다. 실제 응답은 전체 `Attempt`이며 `examples/attempt-started.json`을 따른다. 권장 시간 기본값은 300초다. `recommended_end_at = started_at + recommended_duration_seconds`.

반복 호출 시 이미 시작된 시각을 그대로 반환하고 **타이머를 초기화하지 않는다**. 제출된 응시에는 `409 ATTEMPT_ALREADY_SUBMITTED`다.

권장 시간이 지나도 업로드와 제출을 허용한다. 타이머는 0에서 멈추고 '권장 시간이 지났어요. 답안을 제출해 주세요.'로 표시한다. 자동 제출·답안 삭제·마감 후 거절은 하지 않는다. 백그라운드·오디오 일시 정지 중에도 시간은 흐른다.

표시는 `recommended_end_at - server_time`의 차이를 받은 후 기기의 monotonic elapsed time으로 줄여 나간다. 재진입할 때 GET으로 재동기화한다. 기기 벽시계를 임의로 바꿔도 시험 시간을 초기화하지 않는다. API 응답을 매초 요청하지 않는다.

### 7.5 MXL 기반 구간 재생

재생 계획은 응시 응답의 `playback_plan`에 들어 있다. `version=2`, `engine=local_midi`다. 서버는 음원 파일·MIDI 파일을 보내지 않는다. iPad가 문제 MXL을 정규화한 음악 이벤트로 변환하고 필요하면 로컬 MIDI를 만들어 앱 내 피아노 음원으로 재생한다.

| 필드 | 기본값·의미 |
|---|---|
| `tempo_bpm` | 96. 4분음표/분 기준. MXL의 sound tempo와 반드시 일치. |
| `instrument_profile_id` | `sori-piano-v1`. 앱이 포함하는 하나의 고정 피아노 음원·설정. |
| `tuning_hz` | A4=440 Hz |
| `transpose_semitones` | 0. 임의 옥타브·이조 없음. |
| `velocity` | 모든 음표의 MIDI velocity 80 |
| `gate_ratio` | 1.0. 기보된 길이 끝에서 note-off. |
| `release_tail_ms` | 구간 끝에서 note-off 후 300ms의 감쇠 대기. 기보 길이에 포함하지 않음. |
| `scale` | scale MXL의 1~2마디를 먼저 1회 재생 |
| `pause_after_scale_ms` | 3000ms |
| `steps` | main MXL의 마디 범위 11개. 시작·끝 마디 모두 포함. |

| order | 마디 구간 |
|---|---|
| 1 | 전체 1~8 |
| 2 | 1~2 |
| 3 | 1~2 |
| 4 | 1~4 |
| 5 | 3~4 |
| 6 | 3~6 |
| 7 | 5~6 |
| 8 | 5~8 |
| 9 | 7~8 |
| 10 | 7~8 |
| 11 | 전체 1~8 |

처음 scale을 재생하고 감쇠 300ms와 스케일 후 대기 3000ms를 지난 뒤 steps를 실행한다. 각 구간은 끝의 쉼표까지 포함해 전체 기보 길이를 재생한 다음 활성 음을 정리하고, 감쇠 300ms 후 `pause_after_ms`를 센다. 마지막 음표가 먼저 끝났다는 이유로 구간 뒤쪽 쉼표를 생략하지 않는다. 초기값은 구간별 5000ms, 마지막 구간은 0ms다. 스케일은 헤더의 11개 구간 카운트에 포함하지 않는다. 8마디 본문은 4/4·96 BPM이면 기보 길이 20초이며, 스케일은 2마디 5초다. 감쇠·구간 사이 대기는 별도다.

`sori-piano-v1`은 앱 번들의 동일한 SoundFont/DLS와 매핑·이득 설정으로 고정한다. 현재 전달물에는 음원 리소스가 없으므로 프론트 담당자가 사용할 리소스를 선택하고 파일·버전·해시·이득·사운드뱅크 매핑을 저장소에 기록해야 한다. 같은 프로파일 ID의 음색 bytes나 설정을 앱 버전마다 바꾸지 않는다. 바꿀 때 새 프로파일 ID를 발급한다. 리소스 준비 전에는 start하지 않는다. 피아노 음원은 모든 문제에 공통으로 설치하는 리소스이며 매 문제마다 주고받는 녹음 파일이 아니다.

각 구간은 전체 이벤트에서 별도로 만든다. 마디 a~b는 전체 곡 기준 `[4×(a-1), 4×b)` 4분음표 구간이다. 붙임줄을 먼저 합치고 시작 전부터 이어진 음은 구간 시작에서 다시 발음하며 끝을 넘는 음은 구간 끝에서 note-off한다. 구간 시작을 0으로 옮기고 앞쪽 쉼표와 기보된 무음도 유지한다. 단순히 전체 MIDI의 재생 커서만 옮기는 것으로 대체하지 않는다. 자세한 공식과 테스트 예시는 `MXL-ARCHITECTURE.md`와 expected-events 파일에 있다.

응시 중 템포·옥타브·음색을 사용자가 바꾸는 기능은 첫 버전에서 제공하지 않는다. MusicXML의 표현·페달·스윙·휴머니제이션을 임의로 적용하지 않는다. 지원하지 않는 기호가 들어 있는 문제는 게시하지 않는다.

v1은 개인 연습용이므로 일시 정지를 허용하고, 임의 탐색·이전 구간 반복 버튼은 제공하지 않는다. `allow_manual_pause=true`, `allow_manual_replay=false`다. 중단·백그라운드·인터럽션·앱 재실행 후에는 `interruption_policy=restart_current_segment`에 따라 현재 구간을 처음부터 다시 재생한다. 즉시 진행 중인 note를 모두 끄고 잔향을 정리한다. 간격 대기 중 복귀하면 다음 구간 전에 그 대기 시간을 처음부터 센다. 자동으로 소리를 내지 않고 사용자의 '재생 계속' 입력 후 실행한다.

현재 단계·스케일 여부·대기 여부·MXL 해시·로컬 이벤트 캐시는 iPad에 저장한다. 서버에 실시간 재생 진도를 보내지는 않는다. 헤더는 현재 step의 `order / 11`, 스케일 중에는 '스케일 제시'를 표시한다. 재생 종료 후에도 제출 전까지 필기를 계속할 수 있다.

### 7.6 답안 업로드

`POST /attempts/{id}/answers/` + `Idempotency-Key: <업로드별 UUID>`

| multipart 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| `image` | 파일, image/png | O | 앞서 정의한 고정 PNG |
| `client_answer_id` | UUID 문자열 | O | 앱이 이번 이미지 스냅샷에 발급한 ID |
| `answer_format_version` | 텍스트 `1` | O | multipart에서 정수 1로 파싱 |
| `sheet_layout_id` | 텍스트 `staff-8bars-v1` | O | 이 응시의 템플릿 ID |

JSON에 Base64를 넣지 않는다. multipart의 파일 필드 이름은 항상 `image`다. 이미지가 바뀌면 새 `client_answer_id`와 새 Idempotency-Key를 사용한다. 같은 PNG를 재전송할 때는 **처음 만든 파일 bytes 그대로** 재사용한다. 화면에서 다시 렌더링하면 같은 내용이어도 PNG bytes가 달라질 수 있다.

서버는 `in_progress`에서만 새 답안을 접수한다. 1) 사용자·응시 확인, 2) 용량·MIME·실제 PNG 디코딩, 3) 크기·불투명도·레이아웃 검증, 4) 파일의 영속 저장, 5) 불변 답안 레코드 기록 순서로 처리한다. 파일이 영속 저장되기 전에는 성공 응답을 보내지 않는다.

확장자만 검사하지 않는다. 이미지 bytes를 검증하고, 서버가 디코딩 후 자동 리사이즈·회전·크롭으로 수정하지 않는다. 규격 오류는 422로 되돌려 앱이 올바르게 생성하게 한다. 서버가 계산한 `sha256`은 업로드된 원본 bytes의 해시다. 파일 내용이 전부 빈 오선인지 여부는 업로드 검증이 아니라 인식·채점 단계에서 다룬다.

정상 응답은 `201 Answer`다. `id`, `client_answer_id`, `revision`, 실제 크기·용량·해시·생성 시각·개인 이미지 URL을 포함한다. `revision`은 응시 안에서 접수 순서대로 증가하는 번호다. 번호가 연속이라고 가정하지 말고 리소스 식별에는 `id`를 쓴다. 예시: `examples/answer-upload.json`.

중복 처리의 추가 안전장치로 `(attempt_id, client_answer_id)`는 유일하다. 같은 ID와 같은 bytes·메타데이터는 키가 달라도 기존 `201` 영수증을 반환한다. 내용이 다르면 `409 ANSWER_ID_REUSED`다. 이미 성공한 업로드의 재전송은 제출 이후라도 기존 영수증을 반환한다. 새 답안 생성은 제출 이후 거절한다.

앱은 평소 로컬 원본을 변경할 때마다 안전하게 저장하고 서버 업로드는 초기에 '제출 버튼을 눌렀을 때' 한 번만 해도 된다. 주기적 서버 저장은 필수 기능이 아니다. 제출 버튼을 누르면 필기를 잠시 잠그고 이미지·ID·키를 로컬에 저장한 뒤 업로드한다. 업로드 성공까지 필기를 다시 허용하려면 기존 업로드를 최종 답안으로 제출하지 않고 새 이미지 스냅샷을 만들어야 한다.

### 7.7 이미지 조회

`GET /attempts/{attempt_id}/answers/{answer_id}/image/`는 인증 후 접수했던 원본 PNG bytes를 반환한다. `Answer.image_url`도 이 주소다. 절대 URL을 사용하되 API와 동일 origin이어야 하며 앱은 외부 호스트에 Bearer 토큰을 전달하지 않는다.

개인 이미지는 공개 CDN 주소로 노출하지 않는다. SwiftUI에서는 인증 헤더를 붙인 URLSession 요청으로 다운로드하고 표시한다. 헤더를 넣지 않는 단순 AsyncImage 호출을 전제로 구현하지 않는다.

### 7.8 최종 제출

`POST /attempts/{id}/submit/` + `Idempotency-Key: <제출별 UUID>`

```json
{"answer_id":"44444444-4444-4444-8444-444444444444"}
```

이 답안은 같은 사용자·같은 응시에 속하며 업로드 성공한 답안이어야 한다. 다른 응시·다른 사용자의 ID는 `404 RESOURCE_NOT_FOUND`다. `ready`이면 `409 ATTEMPT_NOT_STARTED`다.

서버는 응시 잠금 아래에서 **제출 상태 변경·submitted_answer_id 고정·채점 작업 예약**을 원자적으로 기록한다. DB 커밋 후 작업 큐 전송이 실패해도 작업을 잃지 않도록 transactional outbox 또는 동등한 재전달 장치를 둔다. 한 응시에 최종 제출은 하나다. 이 시점 이후 새 답안 업로드·필기 수정은 막고 '다시 풀기'는 새 응시로 만든다.

응답은 `202 Grading`, 최초 상태는 `queued`다. 예시: `examples/grading-queued.json`. 응시 자체의 제출 상태는 GET 응시에서 확인하며 `examples/attempt-submitted.json`과 같다.

이미 제출된 응시에 **같은 answer_id**를 다시 제출하면 새 작업을 만들지 않고 현재 결과를 `202`로 반환한다. **다른 answer_id**라면 `409 ATTEMPT_ALREADY_SUBMITTED`. 따라서 타임아웃 후 제출을 재시도해도 서로 다른 답안이 최종 제출되는 일을 막는다.

### 7.9 결과 조회·폴링

`GET /attempts/{id}/result/`는 제출 이후 언제나 같은 `Grading` 구조로 응답한다. 제출 전에는 `409 NOT_SUBMITTED`다.

| status | 의미 | 점수 | 앱 동작 |
|---|---|---|---|
| `queued` | 작업 접수·대기 | null | 대기 표시, 폴링 |
| `processing` | 실제 처리 중 | null | stage 표시, 폴링 |
| `completed` | 확정 가능한 결과 | 값 있음 | 결과 표시, 폴링 종료 |
| `needs_review` | 필기를 충분히 확실하게 읽지 못함 | null | 인식 확인 안내, 폴링 종료 |
| `failed` | 엔진·서버 작업 실패 | null | 실패 안내, 조건에 따라 채점 재시도 |

작업 단계 `stage`는 `pending → recognizing → grading → feedback → done`이다. 처리 중에는 현재 진행 단계다. 실패 시에는 실패한 단계에서 멈춘다. `needs_review`는 `recognizing`에서 멈추고, `completed`만 `done`이다. 필기 인식은 완료되었지만 피드백 문구만 실패하면 고정 템플릿 문구로 대체하여 점수와 함께 완료할 수 있다.

`queued/processing`의 `poll_after_ms`는 2000, 나머지는 0이다. 포그라운드 결과 대기 화면에서만 그 간격으로 조회한다. 60초를 기다려도 진행 중이면 '분석이 계속되고 있어요'와 나가기 동작을 제공하되 서버 작업을 실패로 바꾸거나 새 제출을 보내지 않는다. 다시 결과 화면을 열면 같은 응시로 조회한다. 백그라운드에서는 폴링을 멈춘다. 429·503은 Retry-After가 우선한다.

작업 1회 제한 시간은 초기 120초로 잡고 백엔드가 강제 종료·실패 기록까지 관리한다. 큐와 워커를 감시하는 장치로 장기간 queued/processing에 갇힌 작업을 발견하고 실패 상태로 전환해야 한다. 120초는 앱이 결과를 실패로 추정하는 기준이 아니다. 엔진 실측 후 서버 설정과 문서를 함께 조정한다.

`score`, `pitch_accuracy`, `rhythm_accuracy`는 completed에서만 숫자이며 나머지에서는 모두 null이다. `feedback`은 completed와 needs_review에서 객체, 나머지는 null이다. `failure`는 failed에서만 객체이고 나머지에서는 null이다. `annotations`는 항상 배열이며 대기·처리·실패에서는 빈 배열이다.

예시는 `grading-queued.json`, `grading-processing.json`, `grading-completed.json`, `grading-needs-review.json`, `grading-failed.json`에 있다. 점수 0은 실제 0점이며 '아직 채점 전'을 의미하지 않는다.

### 7.10 채점 재시도

`POST /attempts/{id}/grading-retries/` + 새 Idempotency-Key, 요청 본문 없음.

`status=failed`이고 `failure.retryable=true`인 경우에만 허용한다. 같은 최종 답안·같은 채점 모드·같은 채점 버전을 사용하고 새 `job_id`의 queued 결과를 `202`로 반환한다. 기존 작업 로그는 보존하고 결과 API는 최신 작업을 반환한다.

새 키로 동시에 다시 호출하면 `409 GRADING_IN_PROGRESS`, 재시도 불가 실패·완료·needs_review이면 `409 GRADING_NOT_RETRYABLE`, 제출 전이면 `409 NOT_SUBMITTED`다. 원래 재시도 요청의 같은 키를 다시 보내는 경우에는 현재 상태와 무관하게 기존 접수 영수증을 반환한다. 인식이 불확실한 needs_review는 서버 장애가 아니므로 같은 이미지를 무작정 재처리하는 버튼을 제공하지 않는다. 이번 버전은 확인 후 새 응시를 풀게 한다.

## 8. 상태와 중복 요청의 규칙

응시 상태는 `ready → in_progress → submitted`다. 채점이 완료되어도 응시 상태는 submitted를 유지한다. 채점 상태와 응시 상태를 하나의 enum으로 섞지 않는다. 취소·일시 정지·시간 초과 상태를 서버 응시 enum에 추가하지 않는다. 나갔다 돌아와도 같은 응시가 유지된다.

### 8.1 멱등성 키

Idempotency-Key는 '재전송해도 같은 작업을 한 번만 실행'하기 위한 UUID다. 필수 API는 **응시 생성·답안 업로드·제출·채점 재시도** 네 개다. start는 그 자체로 중복 안전하게 구현한다.

| 상황 | 처리 |
|---|---|
| 같은 사용자·메서드·실제 경로·키 + 같은 요청 | 최초 성공의 상태 코드·리소스·본문을 재반환, 작업 추가 생성 안 함 |
| 같은 범위·키 + 다른 요청 | `409 IDEMPOTENCY_KEY_REUSED` |
| 원래 요청이 아직 커밋 중 | `409 REQUEST_IN_PROGRESS`, `retry_after_ms=1000` |
| 검증 실패 | 성공 영수증을 기록하지 않음. 앱이 내용을 수정했다면 새 논리 요청·새 키 사용 |
| 타임아웃·5xx·연결 끊김 | 실패로 단정하지 않고 같은 키·같은 저장 파일로 재요청 |

키 매핑은 해당 응시·답안의 보관 기간 동안 유지한다. 삭제 기능은 첫 버전 범위 밖이며, 추후 삭제가 추가되어도 오래된 키로 의도치 않은 새 응시가 생성되지 않도록 설계한다. 키는 소유권 검사 뒤에 조회한다.

JSON 요청 비교는 파싱한 의미 있는 필드의 정규화 값으로 하고, multipart는 이미지 bytes의 SHA-256 + 파싱한 텍스트 필드로 비교한다. multipart boundary·파일명·필드 순서가 달라진 것만으로 다른 요청으로 보지 않는다. 최초 커밋 시 응답과 키 기록을 같은 트랜잭션에 저장한다. 원래 응답의 `server_time`이 재반환될 수 있으므로 재전송 영수증으로 시계를 동기화하지 않고 GET 응시로 갱신한다. HTTP Date와 X-Request-ID는 현재 응답 기준이다. 재반환 시 `Idempotency-Replayed: true`를 넣는다.

앱은 논리 요청을 보내기 전에 ID·키·본문·PNG 경로를 로컬에 저장한다. 타임아웃 직후 새 키를 만들거나, 제출 성공 여부를 확인하지 않고 새 응시를 만들지 않는다.

### 8.2 동시에 일어나는 작업

업로드와 submit은 같은 응시의 잠금·트랜잭션 규칙으로 경쟁을 처리한다. 제출이 먼저 확정되면 새 답안 업로드는 거절한다. 업로드가 먼저 확정되면 그 답안 ID를 지정한 제출을 허용한다. `latest_answer`나 '가장 큰 revision'을 이용한 자동 제출은 하지 않는다.

워커는 job_id별 중복 전달에도 한 번의 결과만 확정한다. 이전 작업의 늦은 응답이 새 재시도 작업의 결과를 덮어쓰지 못하도록 최신 job_id를 조건으로 갱신한다.

## 9. 점수와 인식 실패를 구분하는 기준

### 9.1 채점 v1의 범위

첫 자동 채점 대상은 단일 성부·높은음자리표·C Major·4/4·8마디 문제다. 인식 결과는 음표·쉼표·임시표·붙임줄을 포함한 음악 이벤트로 정리한다. 초기 문제는 온음표·2분음표·4분음표·8분음표·점음표와 대응 쉼표 범위로 제한하고 화음·다성부·셋잇단음표는 출제하지 않는다. 입력이 지원 범위를 벗어나거나 인식이 불확실하면 needs_review다.

표준화 데이터는 이벤트 종류, MIDI 음높이, 시작 박, 길이를 갖는다. 시작 박과 길이는 4분음표=1 기준의 정확한 유리수로 계산하며 부동소수점 오차에 의존하지 않는다. 붙임줄로 이어진 같은 음은 합친다. 이명동음은 MIDI 높이가 같으면 같은 음정으로 본다. 음표 모양의 예쁨·기둥 방향·기보 간격은 점수에 넣지 않는다.

### 9.2 기본 산식

채점 버전은 `pitch-rhythm-v1`로 고정한다. 정답은 백엔드가 이 응시에 고정한 main MXL을 자체 파싱해 준비한다. 앱이 생성한 MIDI를 정답으로 받지 않는다. 인식한 답안과 정답을 파일 bytes나 XML 문자열로 비교하지 않는다.

1. 음정 시퀀스: 시간순의 음표 MIDI 높이. 쉼표는 제외한다.
2. 리듬 시퀀스: 시간순의 `(note/rest, 전체 곡 기준 시작 박, 길이)` 튜플. 음높이는 제외한다.
3. 각 시퀀스의 편집 거리 D를 삽입·삭제·치환 비용 각각 1인 Levenshtein 거리로 계산한다.
4. 각 정확도 = `max(0, 1 - D / max(정답 길이, 답안 길이, 1)) × 100`.
5. 각 정확도를 소수 첫째 자리까지 ROUND_HALF_UP으로 반올림한다.
6. 총점 = `(반올림된 음정 정확도 + 반올림된 리듬 정확도) / 2`를 정수 ROUND_HALF_UP.

예시에서 음정 84.0%, 리듬 78.0%이면 총점은 **81점**이다. Figma의 데모 숫자 82를 그대로 산식으로 간주하지 않는다. 잘못된 음 하나가 있는 경우에도 나머지 음을 정렬해 비교할 수 있도록 단순 배열 인덱스 비교 대신 편집 거리를 사용한다. 이 산식은 첫 버전의 명시적 기본값이며 교육적 평가 기준을 바꾸면 grading_version도 바꾼다.

필기 없는 답안임을 확실히 판별하면 completed의 0점으로 처리한다. 읽지 못한 기호를 임의로 삭제하거나 정답을 참고해서 음표를 보정한 뒤 채점하지 않는다. 읽기 어려운 필기를 학생 오답으로 단정하지 말고 needs_review를 반환한다.

인식기의 신뢰도 임계값은 엔진마다 의미가 다르므로 API에 임의의 0.8 같은 수치를 고정하지 않는다. 실제 필기 표본으로 엔진별 기준을 정하고 내부 인식 버전·신뢰도·오류 로그에 남긴다. 엔진이 준비되지 않은 자동 모드에서 데모 점수를 대신 반환하지 않는다. 그 경우 `failed / ENGINE_UNAVAILABLE`이다.

### 9.3 빨간펜 표시

`annotations`의 `bbox`는 **전체 제출 이미지 기준 0~1 정규화 사각형**이다. `x,y`는 왼쪽 위, `width,height`는 크기다. 오선 한 줄 기준 좌표가 아니다. `x+width<=1`, `y+height<=1`, 크기는 양수다. 위치를 알 수 없으면 `bbox=null`, 마디를 확정할 수 없으면 `measure=null`이다. 임의 위치에 표시하지 않는다.

예를 들어 `x=0.47, y=0.18`은 원본 2660 × 1692 이미지에서 약 `(1250.2, 304.56)` 픽셀이다. 화면에 실제 이미지가 그려진 사각형을 R이라 할 때 표시 위치는 `R.minX+x×R.width`, `R.minY+y×R.height`다. 여백을 포함한 바깥 컨테이너 크기를 사용하지 않는다. 빨간 표시는 별도 오버레이이며 제출 PNG에 합쳐 재업로드하지 않는다. 이 bbox를 반응형으로 렌더링한 정답 MXL 악보에 그대로 얹지 않는다. 제출 이미지와 정답 악보는 배치가 다르므로 별도 뷰로 표시한다.

LLM 문구를 사용하더라도 점수는 정해진 비교 로직에서 산출한다. 주석은 정렬 결과와 인식 위치를 기반으로 만들고, 피드백 생성 실패가 이미 계산한 점수를 지우지는 않게 한다.

## 10. 오류 계약

오류 본문은 항상 다음 구조다. `message`는 표시용이며 앱 분기는 `code`로 한다.

```json
{
  "error": {
    "code": "IMAGE_DIMENSIONS_MISMATCH",
    "message": "답안 이미지는 2660 × 1692 픽셀이어야 합니다.",
    "fields": [
      {
        "field": "image",
        "code": "invalid_dimensions",
        "message": "2660 × 1692 픽셀 PNG를 업로드해 주세요."
      }
    ],
    "retry_after_ms": null
  },
  "request_id": "req-example-001"
}
```

| HTTP | code | 앱의 대응 |
|---|---|---|
| 400 | `INVALID_REQUEST` | 입력·타입·필수 필드 수정. missing key 포함. |
| 400 | `INVALID_PAGE` | 페이지 파라미터 수정. |
| 401 | `AUTHENTICATION_REQUIRED` | 토큰 복구. 답안 로컬 보존. |
| 404 | `RESOURCE_NOT_FOUND` | 리소스·소유권 확인. 타인 존재 여부 노출 안 함. |
| 409 | `QUESTION_VERSION_MISMATCH` | 문제 안내 재조회 후 새 응시 생성 요청. |
| 409 | `ATTEMPT_NOT_STARTED` | 응시 상태 조회 후 시작. |
| 409 | `ATTEMPT_ALREADY_SUBMITTED` | 응시 조회 후 제출한 기존 답안·결과 표시. |
| 409 | `NOT_SUBMITTED` | 업로드·제출 상태 복구. |
| 409 | `IDEMPOTENCY_KEY_REUSED` | 같은 키에 다른 본문을 붙인 구현 오류 점검. |
| 409 | `ANSWER_ID_REUSED` | 같은 client_answer_id에 다른 이미지 연결 여부 점검. |
| 409 | `REQUEST_IN_PROGRESS` | retry_after_ms 후 같은 키 재전송. |
| 409 | `GRADING_IN_PROGRESS` | 새 재시도 대신 결과 폴링. |
| 409 | `GRADING_NOT_RETRYABLE` | 현재 결과 표시. 반복 요청 안 함. |
| 413 | `UPLOAD_TOO_LARGE` | 규격에 맞게 다시 생성. 서버 한도와 프록시 한도 일치. |
| 415 | `UNSUPPORTED_MEDIA_TYPE` | 요청 Content-Type 또는 파일 MIME 수정. |
| 422 | `INVALID_IMAGE` | 손상된 PNG·잘못된 색상 형식 수정. |
| 422 | `IMAGE_DIMENSIONS_MISMATCH` | 캔버스 전체를 고정 배율로 재출력. |
| 422 | `IMAGE_NOT_OPAQUE` | 흰 배경에 합성해 투명도 제거. |
| 422 | `SHEET_LAYOUT_MISMATCH` | 응시의 템플릿 ID·답안 버전 확인. |
| 429 | `RATE_LIMITED` | Retry-After 초 후 재요청. |
| 500 | `INTERNAL_ERROR` | 변경 요청의 실패 여부를 단정하지 않고 같은 키로 복구. |
| 503 | `SERVICE_UNAVAILABLE` | Retry-After 초 후 같은 요청 재전송. |

`413`은 요청 bytes 한도, `422`는 업로드 한도 이내에서 이미지 내용이 규격에 맞지 않는 경우다. 서버는 HTML 오류 페이지나 Django 기본 detail 응답이 섞이지 않도록 예외 처리기를 통일한다. 프록시의 413·429도 가능한 한 같은 JSON으로 구성하고 앱은 JSON이 아닌 네트워크·5xx 응답에도 답안을 보존한다.

작업 실패 정보인 `Grading.failure`는 HTTP 오류 본문과 다르다. 초기 failure code는 `ENGINE_UNAVAILABLE`, `RECOGNITION_TIMEOUT`, `GRADING_INTERNAL_ERROR`다. 실제 엔진 설치·서버 상태에 따라 retryable을 서버가 결정한다.

네트워크 오류·일시적 5xx의 자동 재시도는 1초, 2초, 4초 간격으로 최대 3회 후 사용자에게 재시도 버튼을 제공한다. 키와 파일은 유지한다. 429·503의 Retry-After가 있으면 해당 시간 이상 기다린다. 4xx는 REQUEST_IN_PROGRESS·429 등 명시한 경우를 제외하고 무조건 자동 반복하지 않는다.

## 11. SwiftUI 구현 지침

네트워크 계층은 화면과 분리한다. `ExamAPI` 같은 인터페이스에 목록·생성·시작·업로드·제출·결과·재시도를 정의하고, 실제 URLSession 구현과 examples JSON을 읽는 Mock 구현을 교체한다. 필드명은 CodingKeys를 명시하거나 프로젝트 전체의 snake_case 변환 전략을 통일한다. ISO 8601 파서는 소수 초 유무를 모두 처리한다.

권장 로컬 저장 항목은 attempt_id, 마지막 Attempt 응답, PencilKit 원본, 현재 재생 단계, MXL bytes·해시·로컬 이벤트 캐시, 내보낸 PNG 경로, client_answer_id, 응시 생성·업로드·제출의 각 키, 최종 제출하려던 answer_id다. 사용자가 버튼을 누른 뒤 앱이 종료되어도 같은 요청을 복구할 수 있어야 한다.

제출 버튼 흐름:

1. 로컬 필기 저장, 편집 잠금, 최종 PNG 생성.
2. PNG bytes와 업로드 ID·키 저장.
3. answers 업로드. 성공 영수증의 answer_id 저장.
4. 해당 answer_id와 제출 키로 submit.
5. 202를 받으면 업로드 성공과 최종 제출 성공을 구분해서 상태 저장.
6. result 폴링. 완료·확인 필요·실패 화면으로 분기.

앱 재실행 시 먼저 GET 응시로 서버 상태를 확인한다. submitted이면 로컬에 남은 미전송 필기를 자동 업로드하지 않고 서버의 submitted_answer_id 결과를 보여준다. in_progress이면 같은 기기의 원본으로 이어 쓸 수 있다. 기기 교체·앱 삭제로 로컬 원본을 잃었다면 PNG를 편집 가능한 필기로 복원하지 않는다. 기존 이미지 확인 또는 새 응시로 진행한다.

SwiftUI 화면에서 악보 렌더링과 재생 엔진을 인터페이스로 분리한다. `ScoreRenderer`는 MXL→표시, `ScorePlaybackEngine`은 MXL→정규 이벤트→구간→로컬 MIDI/스케줄링→피아노 출력을 맡는다. WKWebView 기반 렌더러를 써도 앱 전체 UI는 SwiftUI로 유지할 수 있다. 정답은 제출 후에만 표시하고 필기 화면은 좌표가 고정된 기존 빈 오선 템플릿을 유지한다. 렌더러가 계산한 가변 악보 배치를 그대로 답안 PNG 배경으로 쓰지 않는다.

로컬 준비 실패는 HTTP 채점 오류와 구별한다. `SCORE_HASH_MISMATCH`, `SCORE_PARSE_FAILED`, `UNSUPPORTED_SCORE_PROFILE`, `SOUND_BANK_UNAVAILABLE`, `PLAYBACK_PREPARE_FAILED` 등을 앱 내부 오류로 구분하고 아직 start하지 않은 상태에서 안내·재준비한다. 서버가 성공했다고 실제로 피아노가 준비되었다고 가정하지 않는다.

JSON 조회 타임아웃 초기값 15초, 업로드 요청 60초로 제안한다. 채점 완료까지 HTTP 업로드 연결을 계속 열어 두지 않는다. multipart boundary 생성과 본문 boundary는 반드시 일치해야 한다.

## 12. Django 구현 지침

Django REST Framework를 사용한다면 일반 API는 JSONParser, 업로드 API는 MultiPartParser를 명시한다. multipart는 request.data에 텍스트, request.FILES에 파일이 들어온다. [DRF 파서 문서](https://www.django-rest-framework.org/api-guide/parsers/)

권장 모델은 UserProfile, Question/QuestionVersion, SheetLayout, Attempt, Answer, GradingJob, IdempotencyRecord, OutboxEvent다. 필수 유일성은 `(attempt, client_answer_id)`, `(user, method, path, key)`이며 제출 전환은 Attempt 행 잠금 아래에서 한 번만 이루어지게 한다. 파일은 개인 접근이 통제되는 저장소에 두고 DB에는 경로·해시·크기·소유 응시를 보관한다. 예외나 경합으로 남은 미참조 파일은 정리한다.

이미지 업로드 요청에서 무거운 인식을 실행하지 않는다. 워커는 제출로 고정된 answer_id를 읽고 인식→정규화→점수 비교→피드백을 수행한다. 작업 상태 변경은 DB에 남긴다. Celery 등 작업 큐의 구체적인 제품은 이 계약의 필수사항이 아니지만 재전달·중복 처리·실패 복구 의미는 동일해야 한다.

스키마 문서화는 drf-spectacular를 사용할 수 있다. DRF 공식 문서도 이를 권장한다. 먼저 합의한 openapi.json으로 구현하고, 구현에서 생성한 스키마가 이 계약과 달라지면 PR에서 차이를 확인한다. [DRF 문서화 가이드](https://www.django-rest-framework.org/topics/documenting-your-api/)

템플릿의 실제 정적 파일 origin을 설정하고 제공한 템플릿 bytes와 레이아웃 JSON을 같은 버전으로 게시한다. API·개인 이미지·MXL 다운로드 origin은 동일하게 유지한다. 문제 게시 시 MXL 압축 구조·XML·지원 프로파일·마디 수·박자·고정 템포·메타데이터 일치를 검사하고 같은 bytes를 서버 채점에도 사용한다. main 1개와 scale 1개를 저장하므로 구간별 MXL·MIDI·AAC를 11개 만들 필요는 없다. 이번 전달물에는 실제로 열 수 있는 테스트 MXL 두 개가 있지만 학습된 인식 모델·피아노 SoundFont는 없다.

## 13. 양쪽이 따로 시작할 작업 순서

| 단계 | SwiftUI 담당 | Django 담당 | 함께 확인할 결과 |
|---|---|---|---|
| 1 | 템플릿 위 PencilKit, PNG 내보내기 | 템플릿 게시, 개발 사용자·토큰, 이미지 업로드·조회 | 실제 iPad 출력 PNG 1장을 업로드·다운로드 |
| 2 | 테스트 MXL 렌더링·로컬 피아노·경계 구간 검증 | MXL 게시 검증·버전 다운로드·재생 계획 | 같은 MXL의 음높이·길이·11구간 재생 |
| 2b | examples로 안내·제출·상태 화면 | 문제·응시·시작·제출·데모 결과 API | 문제 하나의 시작부터 결과까지 연결 |
| 3 | 타임아웃·앱 재시작·동일 키 복구 | 멱등성·잠금·작업 큐·오류 형식 | 중복 응시·중복 채점 없이 복구 |
| 4 | 실제 인식 결과와 주석 표시 | 인식 엔진·정규화·채점 연결 | 실제 필기 표본으로 인식 오류와 오답 구분 |

첫 통합은 회원가입 화면이나 AI 코멘트 완성까지 기다리지 않는다. **실제 iPad가 만든 규격 PNG를 Django가 받고 그대로 돌려주는 것**을 첫 공동 완료 기준으로 삼는다.

## 14. 통합 시 반드시 확인할 시나리오

다음은 상태·동시성·파일 경계에 관한 확인 항목이다. 단순 화면 배치 테스트를 늘리는 대신 실제 실패 위험을 검증한다.

- MXL 다운로드·파싱·피아노 준비가 늦어져도 타이머가 시작되지 않는다.
- main/scale MXL 해시·실제 bytes·문제 버전·재생 템포가 일치한다.
- 점음표·쉼표·F# 임시표·4→5마디 붙임줄을 올바르게 해석한다.
- 1~4마디 끝에서는 붙임줄 음을 끄고 5~6마디 시작에서는 이어지는 음을 새로 발음한다.
- 첫 박이 쉼표인 7~8마디 구간에서 앞 무음이 사라지지 않는다.
- 실제 iPad에서 샘플 MXL 표시·피아노 재생·백그라운드 복귀를 확인한다.
- 답안 PNG 좌표는 정답 MXL의 자동 줄바꿈·배치와 독립적으로 유지된다.
- start를 두 번 보내도 시작 시각이 바뀌지 않는다.
- 300초가 지나도 같은 응시에 업로드·수동 제출할 수 있다.
- 다른 iPad 화면 크기·확대율에서도 2660 × 1692 PNG가 생성된다.
- 투명 PNG·잘린 이미지·잘못된 크기·과대 파일은 명세의 오류로 거절된다.
- 업로드·제출 응답 직전 연결을 끊고 같은 키로 복구해도 답안·작업이 하나다.
- 같은 업로드 키에 다른 PNG를 보내면 충돌한다.
- 업로드 A와 B가 있어도 A의 ID로 제출하면 A가 채점된다.
- 제출 후 새 이미지 업로드·다른 답안 제출은 거절된다.
- 다른 사용자 토큰으로 응시·이미지·결과에 접근할 수 없다.
- 대기·실패·확인 필요 상태에서 0점이 표시되지 않는다.
- 확실한 빈 답안의 0점은 정상 결과로 표시된다.
- 채점 재시도는 같은 답안, 새 job_id로 수행되고 이전 워커가 새 결과를 덮지 못한다.
- 축소·여백·확대 화면에서 bbox 표시가 제출 이미지 위치와 맞는다.
- 앱을 종료한 뒤 재실행해도 로컬 답안과 제출 키를 복구할 수 있다.
- demo 결과에는 '예시 결과'가 표시되며 automatic으로 가장하지 않는다.

## 15. 계약 변경 규칙

필드 삭제·이름 변경·타입 변경·단위 변경·상태 의미 변경·이미지 좌표 변경은 호환성 변경이다. 새로운 레이아웃은 새 sheet_layout_id, 새로운 점수 산식은 새 grading_version, 새로운 문제 콘텐츠·MXL bytes·메타데이터는 새 question version으로 구분한다. 재생 계획은 playback_plan.version, 악기 음원은 instrument_profile_id, 지원 악보 문법은 score profile로 구분한다. 이미 생성된 응시의 스냅샷은 바꾸지 않는다.

백엔드 배포만으로 프론트가 새 필수 요청 필드를 보내게 만들지 않는다. 명세 변경 PR에는 OpenAPI·이 문서·영향받는 Mock JSON을 함께 바꾸고 양쪽이 확인한 뒤 적용한다. 인증 가입·로그인·갱신, 답안 보관·삭제, 실제 배포 origin은 서비스 공개 전에 별도 계약으로 채우되 시험 API 개발을 막는 선행 구현으로 두지 않는다.


## 16. v0.1 → v0.2 변경 요약

문제 전달을 구간별 AAC 파일에서 main/scale MXL 두 개로 바꿨다. `AudioAsset`, `scale_audio`, 각 step의 `audio`를 제거했다. `score_assets`, `content_policy`, `score_visibility`, MXL 다운로드 API, 로컬 합성 설정을 추가했다. `playback_plan.version=2`, `engine=local_midi`, `interruption_policy=restart_current_segment`를 사용한다.

답안은 계속 PNG로 업로드하고 기존 2660×1692 규격·좌표·제출·멱등성·서버 인식·채점 계약은 유지한다. 네트워크로 MIDI·녹음 음원 파일을 전달하지 않는다. 레퍼런스 MXL 파일과 예상 이벤트를 추가했다. 이번 개정은 실제 iPad용 렌더러·플레이어를 구현했다는 뜻이 아니며 해당 실기기 검증은 다음 통합 과제다.
