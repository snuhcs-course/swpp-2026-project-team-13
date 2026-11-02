# Feature v1 계산과 데이터 규칙

명세 버전 `1.0.0` · 2026년 11월 1일 확정

[팀원용 안내](../FEATURE-V1.md)의 개발 기준이다. 아래 정의가 v1의 의미를 결정한다. 기존 `feature-lab-0.2` 출력과 차이가 있는 부분은 9절에 명시한다. 문서의 예시는 신규 분석 형식이며 현재 HTTP 응답을 뜻하지 않는다.

## 1 입력과 분석 단위

### 입력 조건

- `score-partwise`의 한 part, 한 voice, 한 staff를 대상으로 한다. `.xml`, `.musicxml`, `.mxl`을 받는다. MXL은 컨테이너의 rootfile을 읽는다.
- 조표와 박자·divisions는 해당 위치부터 다음 변경까지 이어받는다. 마디 중간의 속성 변경, `backup`·`forward`, 다성부·화음·꾸밈음·이조 악기·미분음·비전통 조표는 v1에서 제외한다.
- note의 실음은 `pitch/step`, `octave`, `alter`로 읽는다. `alter` 생략은 0이다. 표시용 `accidental`이나 조표를 다시 더해서 실음을 바꾸지 않는다. 따라서 잘못 작성된 XML을 자동으로 복원하는 기능은 아니다.
- duration과 divisions는 양수이며, note type·dot·time-modification으로 계산한 기보 길이와 duration이 일치해야 한다. 온마디 쉼표는 실제 마디 길이로 검사한다.
- type이 생략된 경우 duration은 보존하되 기보 길이 대조를 완료했다고 표시하지 않는다. `missing_note_type` 진단과 partial 상태를 남긴다. 온마디 쉼표는 이 예외 대신 마디 길이 검사를 적용한다.
- 유효한 붙임줄은 같은 MIDI 음높이로 시간상 연속되어야 한다. 끊긴 연결·매칭되지 않는 시작/끝은 제외한다. 반복 구간에만 적용하는 `time-only` 붙임줄은 제외한다.
- 반복기호는 펼치지 않는다. `written_order=true`로 적힌 순서임을 명시한다. 연주 순서가 필요한 기능은 별도 변환 후 다시 분석한다.
- 한 마디가 기대 길이보다 짧으면 실제 길이를 유지하고 `incomplete_measure`를 남긴다. 초과하면 제외한다. 못갖춘마디를 마디 끝에 맞춰 이동하거나 무음으로 채우지 않는다.
- 원본 검수 상태와 구조 검사는 별개다. 파싱 통과만으로 음원과의 일치나 정답의 정확성을 보증하지 않는다.

전체 악보에 발음 시작이 하나도 없으면 대상 문제 분석을 만들지 않고 `no_pitched_attacks`를 기록한다. 유효한 악보에서 잘라낸 쉼표 전용 구간은 허용하며 음정 지표만 미확정으로 둔다.

### 시간 단위

모든 원본 시간 값은 4분음표를 1로 하는 유리수다. JSON에서는 기약분수 문자열로 쓴다. 정수는 `"1"`, 분수는 `"1/3"`이며 분모는 양수다. 원본 시간은 실수로 반올림하지 않는다.

`duration_qn = MusicXML duration / 해당 위치 divisions`

`expected_duration_qn = beats × 4 / beat_type`

`onset_qn`은 마디 시작 기준 0부터, `absolute_onset_qn`은 적힌 악보 시작 기준 0부터 센다. 배열의 마디 순서는 1부터 부여하고 원래 `<measure number>` 문자열도 따로 보관한다. 음표/쉼표 index도 마디 안의 `<note>` 순서로 1부터 센다.

### 기본 박

| 박자 | 분석용 기본 박 길이 | 온마디 기본 박 수 | 기본 beat_grouping |
| --- | --- | --- | --- |
| 2/4 | `1` | 2 | `[1,1]` |
| 3/4 | `1` | 3 | `[1,1,1]` |
| 4/4 | `1` | 4 | `[1,1,1,1]` |
| 6/8 | `3/2` | 2 | `[3,3]` |
| 9/8 | `3/2` | 3 | `[3,3,3]` |
| 12/8 | `3/2` | 4 | `[3,3,3,3]` |

이 여섯 박자가 v1 기본 박 분석의 보장 범위다. 그 외 양의 정수 beats/beat-type은 음표와 마디 길이를 보관할 수 있지만, 명시적으로 지원하지 않은 박 기반 값은 `null`, 사유는 `unsupported_meter`다.

7/8의 `2+2+3` 같은 묶음은 분모 음표 수의 배열로 `beat_grouping=[2,2,3]`에 보관하고 합이 분자와 같은지 검사한다. 묶음이 없으면 `needs_beat_grouping`이다. v1은 묶음의 보관까지만 확정하며 불규칙 박자의 박 기반 점수는 구현·검증 전까지 제공하지 않는다.

위 기본 박을 `P`라 할 때 `pulse_position = onset_qn / P`, `phase = pulse_position - floor(pulse_position)`다. 내부 값은 0부터, 사람에게 보이는 박 번호는 1을 더한다. 못갖춘마디도 실제 시작을 0으로 두므로 완전한 마디의 강약 위치로 해석하지 않는다.

## 2 원본 이벤트와 발음 시작

`events`는 적힌 모든 음표와 쉼표를 보존한다. note와 rest를 합쳐 written event라고 부른다.

| 필드 | 형식과 의미 |
| --- | --- |
| `id` | 문제 버전 안에서 고정된 이벤트 식별자. 예시 `fixture-v1:m1:n2` |
| `measure`, `index` | 1부터 시작하는 순서상의 마디와 이벤트 번호 |
| `onset_qn`, `absolute_onset_qn`, `duration_qn` | 앞 절의 기약분수 문자열 |
| `kind` | `note` 또는 `rest` |
| `step`, `alter`, `octave`, `midi` | note의 표기와 실제 음높이. rest에는 모두 `null` |
| `type`, `dots` | XML type 문자열 또는 `null`, dot 개수 0 이상의 정수 |
| `tuplet_ratio` | `[actual_notes, normal_notes]`, 없으면 `[1,1]`. 양의 정수이며 1:1은 잇단음으로 세지 않음 |
| `accidental` | 표시 기호, `cautionary`, `editorial`을 가진 객체 또는 `null`. 속성 생략은 false |
| `beams` | 번호와 begin/continue/end/hook를 가진 원본 빔 목록 |
| `tie_start`, `tie_stop` | 소리의 `<tie>` 기준 boolean. 시각적 `<tied>`만으로 지속을 합치지 않음 |
| `attack_id` | note의 발음 시작 이벤트 ID. rest는 `null` |

MIDI는 `(octave+1)×12 + {C:0,D:2,E:4,F:5,G:7,A:9,B:11}[step] + alter`다. v1은 MIDI 0~127과 정수 alter를 대상으로 한다.

`attacks`는 tie_stop이 없는 note만 갖는다. 각 attack은 `id`, `member_event_ids`, `onset_qn`, `absolute_onset_qn`, `sounding_duration_qn`, `midi`를 가진다. duration은 연결된 적힌 음표들의 길이 합이다. `member_event_ids`에는 시작 음표와 모든 붙임줄 지속 음표를 시간 순서대로 넣는다.

**예시:** 두 마디의 온음표를 붙임줄로 연결하면 written note count=2, attack count=1, sounding duration=`"8"`, tie chain count=1이다. 두 음표를 별도 도약이나 새 음으로 세지 않는다.

## 3 음정과 특징의 근거

### 음정 연결

적힌 순서에서 연속하는 attack마다 하나의 interval을 만든다. 붙임줄 지속은 건너뛴다. 쉼표 뒤의 다음 attack도 연결하되 `across_rest=true`로 구분한다. 따라서 전체 interval 수는 attack 수 N에 대해 `max(N-1,0)`이다.

`semitones = 다음 midi - 이전 midi`

`generic = abs((다음 octave×7 + 다음 step 순서) - (이전 octave×7 + 이전 step 순서)) + 1`

step 순서는 `C=0,D=1,E=2,F=3,G=4,A=5,B=6`이다. `direction`은 semitones의 부호에 따라 `up`, `down`, `same`이다. 이명동음은 기보상의 도수가 달라도 direction=`same`이다.

interval에는 `from_event_id`, `to_event_id`, `semitones`, `generic`, `direction`, `across_rest`, `scope`를 넣는다. 양끝이 같은 마디면 `local`, 다르면 `connection`이다. 음정 성질 이름 P5/m3 등의 출력은 선택 사항이며 수치가 기준이다.

쉼표를 사이에 둔 연결도 포함한 값이 기본 집계다. 쉼표 없는 연결만 필요한 기능은 `across_rest=false`로 다시 집계하고 그 필터를 설정에 남긴다.

### 공통 특징 레코드

| 필드 | 규칙 |
| --- | --- |
| `code` | 아래 표의 안정된 코드 |
| `kind` | `rule` 또는 `candidate` |
| `scope` | `local`, `connection`, `context`, `score` |
| `event_ids` | 판단에 필요한 모든 이벤트 ID. 중복 없이 악보 순서로 나열 |
| `measure_ids` | event 근거와 비교 대상의 마디 번호. 중복 없이 오름차순 |
| `details` | 음정 값, 비교 대상, 넘은 박 위치 등 재검토에 필요한 수치 |

같은 `code`와 같은 근거 ID 집합을 여러 이벤트에 붙여도 특징 레코드는 하나만 생성한다. 붙임줄은 chain 하나가 한 특징이다. **특징 발생 횟수와 특징이 있는 마디 수는 별도 집계다.**

### v1 규칙과 코드

| 코드 | 정확한 조건 | 근거와 집계 단위 |
| --- | --- | --- |
| `large_up` | interval generic≥5, semitones>0 | 양끝 attack, 연결당 1회 |
| `large_down` | interval generic≥5, semitones<0 | 양끝 attack, 연결당 1회 |
| `explicit_accidental` | written note에 accidental 요소 존재 | 해당 이벤트, 기호당 1회 |
| `cautionary_accidental` | accidental의 cautionary=yes | 해당 이벤트, 기호당 1회 |
| `editorial_accidental` | accidental의 editorial=yes | 해당 이벤트, 기호당 1회. 주의 임시표와 구분 |
| `key_relative_alteration` | attack의 alter가 해당 조표의 step 변화량과 다름 | attack당 1회. 조표 미명시는 미확정 |
| `dotted` | written event의 dots>0 | 음표와 쉼표 모두 포함, 이벤트당 1회 |
| `tuplet` | written event의 actual_notes≠normal_notes | 음표와 쉼표 모두 포함, 이벤트당 1회 |
| `tie_chain` | 한 attack의 member_event_ids가 2개 이상 | chain 전체, 1회 |
| `short_sounding_attack` | attack의 총 sounding_duration_qn≤1/4 | chain 전체, attack당 1회 |
| `rest` | written event kind=rest | 해당 이벤트, 1회 |
| `exact_rhythm_repeat` | 5절의 기보 리듬 패턴이 같은 앞선 마디 존재 | 최초 마디와 현재 마디 전체, 관계당 1회 |

조표 변화량은 샤프 순서 F C G D A E B, 플랫 순서 B E A D G C F에 따라 결정한다. 지원 fifths는 -7~7이다. 이 조건은 화성적 비화성음·전조·조성 확정과는 다르다.

기본 표기의 `key_relative_alteration`은 모든 attack 위치에서 계산한다. 같은 임시표가 반복되는 음도 각 발음 시작의 특성이며, 실제로 새 기호를 적은 횟수는 `explicit_accidental`로 별도 센다. 누락된 기호를 자동으로 추론해서 이 횟수를 늘리지 않는다.

잇단음 그룹 개수는 v1 필수 집계에 넣지 않는다. 비율이 같은 이벤트가 연속된다는 사실만으로 3개 묶음의 경계가 확정되지 않기 때문이다. event 수와 attack 비율로 활용하고, 그룹 개수를 제공하려면 start/stop 등 명확한 근거와 별도 규칙 버전을 추가한다.

## 4 검토 후보

### 기본 박을 넘는 지속음 후보

코드 `offbeat_sustain_candidate`, kind=`candidate`다. 기본 박 길이 P가 확정된 완전한 마디에서 시작한 attack에 한해 다음을 검사한다.

1. `onset_qn mod P != 0`인지 확인한다.
2. 다음 기본 박의 절대 위치 B를 찾는다. 못갖춘마디나 박자 변경 경계가 필요하면 그 지점까지의 후보 계산을 미확정으로 둔다.
3. `attack_absolute_start < B < attack_absolute_end`이면 후보 1회다. B에서 정확히 끝나면 세지 않는다.

근거는 attack chain 전체이며 `details`에 B의 마디·위치를 넣는다. 마디를 넘으면 connection이다. 이 후보는 단순한 구조 탐지이며 완전한 당김음·강약·연주 해석이 아니다. 난이도 실험의 metrical displacement와도 별도 값이다.

### 기본 박 경계를 넘는 빔 후보

코드 `cross_pulse_beam_candidate`, kind=`candidate`다. 완전한 지원 박자 마디에서 level 1 beam의 begin부터 end까지 묶음을 찾고, 서로 다른 `floor(onset_qn/P)`의 이벤트가 있으면 묶음당 1회다. 근거에는 묶음 전체를 넣는다. hook와 중첩 level은 보존하되 별도 묶음 횟수로 세지 않는다.

begin/end가 맞지 않거나 기본 박을 정하지 못하면 후보 여부를 미확정으로 둔다. 이 결과만으로 학생의 표기 오류나 감점을 만들지 않는다.

## 5 마디 패턴과 집계

### 기보 리듬 패턴

정확한 반복의 기본 단위는 한 마디다. canonical value는 아래 배열을 UTF-8 JSON으로 직렬화한 것이다. 공백 없이 ASCII 숫자·문자열을 사용한다.

```text
[meter, beat_grouping_or_null, actual_duration_qn, [[kind,onset_qn,duration_qn], ...]]
```

`meter`는 `"4/4"`와 같은 문자열이다. `kind`는 쉼표 R, tie_stop이 있는 지속 음표 T, 나머지 note N이다. 그룹이 없으면 `null`이며 6/8의 기본 그룹은 `[3,3]`, 4/4는 `[1,1,1,1]`이다. 기본 그룹은 각 박자의 분모 음표 단위다. 이벤트는 원본 순서를 따른다.

`rhythm_pattern_id = SHA256(canonical_value)`의 64자리 소문자 hex다. 해시뿐 아니라 canonical value도 보관한다. 음높이·조표·BPM·빔·점 모양·잇단음 표시 자체는 포함하지 않으며 실제 onset과 duration에 반영된 길이는 포함한다.

붙임줄의 적힌 분할 방식이 다르면 다른 기보 패턴이다. 실제 소리가 같은 패턴을 찾으려면 별도 sounding pattern 규칙이 필요하며 v1에서는 동일하다고 자동 병합하지 않는다.

앞선 동일 ID와 canonical value를 가진 마디 중 가장 처음 것을 `repeat_of`로 연결한다. 현재 마디마다 한 관계만 만든다. 모든 마디 쌍을 만들어 중복 집계하지 않는다. 이 관계의 scope는 context이며 단일 마디 고유 태그가 아니다.

### 필수 집계

아래 값은 문제 전체와 선택 구간에서 계산한다. 마디 집계에는 외부 근거를 가진 특징을 포함하지 않는다.

| 값 | 정확한 계산 |
| --- | --- |
| `written_note_count` | kind=note인 written event 수. 붙임줄 지속 포함 |
| `rest_event_count` | kind=rest인 written event 수 |
| `attack_count` | 선택 구간 안에서 새로 시작하는 attack 수 |
| `tie_chain_count` | chain 전체가 범위 안에 들어오는 tie_chain 특징 수 |
| `interval_count` | 두 끝점이 모두 범위 안에 있는 interval 수 |
| `mean_abs_semitones` | 위 interval의 abs(semitones) 산술평균. interval 0개이면 null |
| `large_up_count`, `large_down_count` | 범위 안에 모든 근거가 포함된 해당 특징 수 |
| `pitch_range_semitones` | 범위에 적힌 note의 최대 midi−최소 midi. 들어오는 붙임줄 음도 포함. note 0개이면 null |
| `duration_pulses` | 각 마디의 실제 duration_qn/P 합. 박이 미확정인 마디가 있으면 null |
| `attacks_per_pulse` | attack_count / duration_pulses. 분모 0·미확정이면 null |
| `dotted_event_count` | dots>0인 written event 수 |
| `tuplet_event_count` | 비율이 1:1이 아닌 written event 수 |
| `tuplet_attack_share` | 시작 written event가 잇단음인 attack 수 / attack_count. attack 0개이면 null |
| `exact_rhythm_repeat_fraction` | (범위의 마디 수−서로 다른 패턴 수) / 마디 수. 패턴 미확정 마디가 있으면 null |

같은 원칙으로 explicit/cautionary/editorial accidental, key_relative_alteration, 후보의 발생 수를 별도로 센다. 어떤 마디든 조표 미명시 구간이 있으면 구간 전체의 key_relative_alteration 총계는 null이다. 계산 가능한 부분은 별도 partial 필드와 coverage를 표시한 경우에만 제공한다.

정의된 경우의 0은 그대로 0이다. null에는 `missing_key_signature`, `no_intervals`, `no_notes`, `no_attacks`, `needs_beat_grouping`, `unsupported_meter`, `incomplete_measure` 등 사유를 `unavailable_reasons`에 필드별로 남긴다. 형식은 JSON 필드 경로를 키, 사유 코드의 중복 없는 배열을 값으로 하는 객체다. 예: `{"metrics.mean_abs_semitones":["no_intervals"]}`. 데이터가 없거나 후보 검사를 수행하지 않은 것을 빈 배열만으로 특징 없음이라고 표현하지 않는다.

## 6 구간 추출

원본의 연속 마디 `[first,last]`를 대상으로 한다. 원본 ID·시점은 유지하고 게임 표시용 새 마디 번호는 별도로 만든다.

1. 모든 `event_ids`와 `measure_ids`가 범위 안인 특징만 가져온다. 1마디에서 출발한 도약을 2마디 단독 구간에 붙이지 않는다.
2. exact_rhythm_repeat는 선택 구간 안에서 최초 등장 마디를 다시 찾는다. 바깥 마디와의 반복 관계를 내부 관계로 가장하지 않는다.
3. 통계·난이도는 원래 문제의 값을 복사하지 않고 해당 범위와 설정에서 다시 계산한다.
4. 붙임줄 chain이 구간 바깥으로 나가거나 바깥에서 들어오면 `standalone_status=requires_tie_adaptation`을 남긴다. 그 chain은 완전한 특징 집계에서 제외한다. 자동으로 소리를 잘라 유효한 독립 문제로 표시하지 않는다.
5. 붙임줄을 수정한 구간은 새 콘텐츠 버전·XML 해시로 분석한다. 원본에서 유래한 문제임을 provenance로 연결한다.

관계가 구간 내부로 들어왔다고 원본 scope를 바꾸지 않는다. 두 마디 구간 안에 있는 connection은 여전히 connection이고, 해당 구간에서 사용 가능한 특징이 된다.

## 7 저장 형식과 버전

아래는 분석 레코드의 논리 구조다. 별도 DB 테이블과 JSON 컬럼 중 어느 방식으로 물리 저장할지는 후속 구현에서 결정한다.

| 필드 | 필수 내용 |
| --- | --- |
| `schema_version` | `"1.0.0"` |
| `analysis_status` | `complete` 또는 `partial`. 필수 구조를 읽을 수 없으면 분석 대신 제외 사유를 남김 |
| `question_id`, `question_version` | 분석 대상 콘텐츠의 고정 식별자와 양의 정수 버전 |
| `source_xml_sha256` | MXL에서 꺼낸 root XML 또는 원본 XML의 정확한 바이트 SHA256. 원본 파일/container 해시는 별도 보관 가능 |
| `extractor_version`, `config` | 구현 버전과 규칙에 영향을 주는 설정. 가정한 조표가 있다면 원본과 별도로 기록 |
| `source_review` | 검수 상태와 검수 범위. 구조 검사의 성공과 구분 |
| `written_order` | v1은 true |
| `measures`, `events`, `attacks`, `intervals` | 원본·연결 데이터 |
| `features`, `metrics`, `unavailable_reasons` | 근거가 있는 특징, 요약 수치, 미확정 사유 |
| `experimental` | 별도 버전을 가진 선택적 실험 결과. 없으면 빈 객체 |

source_review의 상태는 `unreviewed`, `partially_reviewed`, `reviewed`이며 마지막 상태도 scope 안의 검수만 의미한다. 조표와 이명동음 표기가 임시인 경우 그 사실을 notes에 남긴다.

조표 누락·미지원 박자·불완전 마디 등으로 필수 특징의 검사 범위가 부족하면 analysis_status는 partial이다. 한 음 구간에서 평균 음정이 정의되지 않는 것처럼 계산상 해당하지 않는 경우만으로 partial이 되지는 않는다. source_review가 unreviewed라는 이유로 구조 분석 상태를 바꾸지도 않는다. 완전한 분석은 원본이 올바른 정답이라는 의미가 아니다.

분석을 구분하는 키는 question/version, XML 해시, schema_version, extractor_version, canonical config의 조합이다. config는 키 정렬·공백 없는 UTF-8 JSON으로 직렬화한다. 생성 시각과 표시 제목은 음악 결과의 재현성 비교에서 제외한다. 의미가 같은 새 XML도 바이트가 다르면 새 source hash가 될 수 있다.

이벤트 ID는 문제 버전과 마디·이벤트 순서로 고정한다. 원본에 음표를 삽입해 순서가 바뀌면 새 문제 버전으로 취급한다. AI 인식 답안의 음표 index와 정답 이벤트 ID를 같다고 가정하지 않는다. 서로 연결하려면 별도 정렬 결과가 필요하다.

단위·범위·판정 조건을 바꾸면 schema의 major 버전을 올린다. 의미를 유지한 선택 필드 추가는 minor, 의미를 바꾸지 않는 설명 정정은 patch로 기록한다. 구현 오류 수정도 extractor_version을 바꾸고 재분석 전후를 구분한다.

과거 풀이가 어떤 분석을 사용했는지 고정할 수 있어야 한다. 새 분석이 이전 분석을 덮어쓰지 않으며, 사용자 요약은 원본 풀이·채점 기록에서 다시 계산할 수 있어야 한다.

## 8 난이도 실험과의 분리

현재 방식 C의 버전은 `difficulty-review-0.1`이다. feature v1의 확정 지표나 학생 능력 점수가 아니다. 로컬 `evaluation/feature_lab/difficulty.py` 구현과 아래 정의로 재현한다. 이 실험 코드는 현재 공유 앱 저장소의 API 구현에 포함되지 않는다.

```text
pitch_raw = 평균 절대 반음 간격
          + 12 × 7반음 이상 연결 비율
          + 6 × 트라이톤 계열 연결 비율

rhythm_raw = metrical_displacement / 기본 박 시작점 수
           + 0.5 × 잇단음 attack 비율
           + 0.25 × 박별 분할 격자 변화 비율
           + 0.1 × 기본 박 시작점당 attack 수

tonal_raw = 1 − max(0, 장단조 24개 KK 프로필 중 최대 상관계수)

각 정규화 지표 = 100 × raw / 기준 집단 raw의 75백분위수
C = (정규화 pitch + 정규화 rhythm + 정규화 tonal) / 3
```

비율 분모는 interval이면 interval 수, attack이면 attack 수다. 트라이톤 계열은 `abs(semitones) mod 12 = 6`이다. 코드의 길이가 0인 분모에 대한 fallback을 통계적 근거로 해석하지 않는다. 충분한 음표가 없거나 조성 히스토그램의 상관계수가 정의되지 않는 입력은 v1 사용 단계에서 실험 점수를 미확정으로 둔다.

metrical displacement의 위치별 세기는 마디 시작 4, 4/4 셋째 박 3, 나머지 기본 박 2, 단순박의 절반 또는 복합박의 1/3 위치 1, 그 외 0이다. 각 attack의 시작보다 세기가 높은 격자점을 sounding duration의 **엄격한 내부**에서 찾고 가장 큰 세기 차이를 1회 더한다. 강박에서 시작한 긴 음은 새 attack이 없다는 이유만으로 가산하지 않는다. 후보 탐지 4절과 다른 실험이다.

격자 변화는 각 기본 박 안의 attack 시작 위상 분모와, 1박보다 짧은 sounding duration/P 분모의 최소공배수로 격자값을 만들고 연속 박의 값이 바뀐 비율이다. attack이 없는 박의 격자값은 0이다. 같은 박의 정박·엇박 음을 번갈아 세는 방식이 아니다.

기준 집단은 교재 악보의 실음·길이·박자 기준 이조 중복 family당 1개다. 같은 박자 family가 20개 이상이면 해당 박자를, 아니면 전체를 사용한다. 75백분위수는 정렬 후 `(N-1)×0.75` 위치의 선형보간이며 0인 scale은 `1e-6`으로 제한한다. 기준 집단·family 구성·파라미터·입력 해시를 결과와 함께 고정해야 한다. 기준 집단이 바뀌면 실험 버전 또는 calibration 식별자를 바꾼다.

24개 프로필의 최대 적합도를 사용하며 조표나 조성을 원본에 부여하지 않는다. 7/8은 이 실험 총점을 제공하지 않는다. 100은 상한·백분위 순위·정답률이 아니고, 박자별 기준이 다르므로 서로 다른 박자의 점수를 공통 절대 척도로 사용하지 않는다.

기존 A/B 및 예측 지표를 더한 D는 비교 실험 이력으로만 남긴다. C가 일부 샘플을 더 잘 분리했다는 결과는 실제 학생 난이도의 검증 정확도가 아니다.

## 9 현재 실험 코드와 다른 부분

v1 구현 전에 아래 차이를 처리해야 한다. 기존 결과 파일의 version 문자열만 바꾸어 v1으로 재사용하지 않는다.

| 기존 feature lab | v1 기준 |
| --- | --- |
| raw tags와 normalized schema가 혼재 | 원본 events·attacks·intervals와 근거 features를 분리 |
| `courtesy`에 cautionary/editorial을 함께 포함 | 두 속성을 별도 코드로 보관 |
| dotted/tuplet 태그가 주로 note에만 부여 | rest도 written event로 동일하게 처리 |
| tuplet_groups가 연속 비율과 start로 추정됨 | event 수·attack 비율이 필수, 그룹 개수는 보류 |
| `subdivision`이 시작 음표의 적힌 길이를 사용 | `short_sounding_attack`은 붙임줄을 합친 길이 사용 |
| 같은 tie 태그가 여러 written note에 부여 | chain당 한 특징으로 중복 제거 |
| `syncopation`, `beam_cross` | 의미를 드러내는 후보 코드, 근거 전체와 판정 가능 여부 보관 |
| pattern hash가 10자리이고 박 단위 signature 사용 | 5절 canonical value와 전체 SHA256, v1에서 새로 생성 |
| 임의 박자의 분모 박을 계산할 수 있음 | 지원 박자 목록과 미확정 상태 명시 |
| 정확한 리듬 반복만 구현 | 선율·유사 반복은 구현됐다고 표시하지 않음 |

기존 `family` 해시는 학습자 분석이나 콘텐츠 ID로 사용하지 않는다. 실험 중복 제거용이며 실음 패턴 기준이다. 5도 태그에 영향을 주는 이명동음 표기의 동등성을 보장하지 않는다.

## 10 구현 시 검증할 예시

| 입력 또는 상황 | 기대 결과 |
| --- | --- |
| 도4→솔4, 도4→솔♭4, 도4→파♯4 | 각각 generic 5/5/4, semitones 7/6/6. large_up은 앞의 두 연결만 |
| 솔4→도4가 마디 경계에 있음 | 전체 large_down=1, 도4가 속한 마디 local large_down=0 |
| 붙임줄로 연결된 4분음표 두 개 | written notes=2, attacks=1, sounding duration=2 |
| C4 온음표 한 개와 C4 2분음표 두 개의 붙임줄 | 실음 길이·attack 수는 같고 기보 패턴은 다름 |
| 6/8의 8분음표 여섯 개 | 기본 박 길이=3/2, duration_pulses=2, attacks_per_pulse=3 |
| duration=160, divisions=480인 8분 셋잇단음 | duration_qn=1/3, ratio=[3,2]이면 길이 일치 |
| 조표 미명시 악보의 F♯ | MIDI는 읽고 key_relative_alteration은 null |
| G장조 악보의 F♯ | 조표 변화량과 일치하므로 key_relative_alteration=0 |
| C 제자리표에 cautionary=yes | explicit와 cautionary 각각 1, 조표 밖 음은 아님 |
| 두 마디의 음높이만 다르고 N/R/T 위치·길이는 같음 | 같은 기보 리듬 패턴, 두 번째 마디 repeat_of=1 |
| 그 두 번째 마디만 자름 | 바깥 마디와의 반복 관계는 빠짐 |
| 음이 다음 기본 박에서 정확히 끝남 | offbeat_sustain_candidate가 아님 |
| 구간 밖에서 들어오는 붙임줄 | requires_tie_adaptation, 새 attack으로 위장하지 않음 |
| 7/8의 박 묶음 미명시 | 원본 음표 보관, 박 기반 값과 C 총점은 null |
| 한 음뿐인 구간 | interval_count=0, mean_abs_semitones=null |

현재 로컬 실험 검사들은 위 규칙의 일부에 대한 근거다. 전체 v1의 적합성 검사를 통과한 구현으로 간주하지 않는다.

## MusicXML 의미 확인 자료

- [divisions](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/divisions/)
- [alter](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/alter/)
- [accidental](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/accidental/)
- [tie](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/tie/)

분류 기준·집계 방식·지원 범위는 Solfège v1의 제품 설계다. MusicXML 표준 자체가 학습 난이도나 표기 오류를 결정하는 것은 아니다.
