# 클래식 8마디 청음 시험

클래식 탭은 작곡가 선택 → 문제 안내 → 기존 시험(음계·예비박·11개 재생 구간·Pencil 필기) → 제출·채점·정답·기록 흐름을 사용한다. HTML은 별도의 미리듣기 자료다.

## 수록과 제외 기준

- 원본 단선율 XML 자체가 **완전한 8마디**여야 한다. 못갖춘마디, 마디 생략, 마지막 마디 보충, 임의 쉼표 추가, 경계 붙임줄 수선은 허용하지 않는다.
- 출처 파일과 해시, 조표·박자·음표 길이·성부·붙임줄을 검사하고, 정규화 전후 음높이와 리듬을 대조한다.
- 표현용 이음줄·아티큘레이션은 기존 시험 프로필에 맞춰 생략한다. 재생 붙임줄과 셋잇단음표는 유지한다.
- GTTM에서 제공하는 선율 발췌·편곡의 조성을 유지한다. 모든 발췌본이 원곡 조성이나 원전 옥타브라는 의미는 아니다.
- MIDI로 추정한 말러 1번, 성부 발췌를 독립 확인하지 못한 말러 8번, XML 미확보 쇼스타코비치, 조성 메타데이터가 의심스러운 브람스 헝가리 무곡·모차르트 K.331, 원본이 8마디가 아닌 나머지 자료는 시험에서 제외했다.

현재 7명, 11문제:

| 작곡가 | 발췌 선율 | 수록본 조성 | 박자 |
| --- | --- | --- | --- |
| 프로코피예프 | 피터와 늑대 | C장조 | 4/4 |
| 차이콥스키 | 백조의 호수 | B단조 | 4/4 |
| 차이콥스키 | 나폴리의 노래 | E♭장조 | 2/4 |
| 차이콥스키 | 어린이 앨범의 왈츠 | E♭장조 | 3/4 |
| 베토벤 | 환희의 송가 | D장조 | 4/4 |
| 베토벤 | 비창 소나타 2악장 | A♭장조 | 2/4 |
| 그리그 | 아침의 기분 | F장조 | 6/8 |
| 생상스 | 백조 | G장조 | 3/4 |
| 사티 | 짐노페디 1번 | D장조 | 3/4 |
| 드보르자크 | 유모레스크 | G장조 | 2/4 |
| 드보르자크 | 신세계 교향곡 2악장 | D장조 | 4/4 |

원본과 결정 기록: `backend/content/source/classical/provenance.json`. [GTTM Database](https://gttm.jp/gttm/database/) / [musicparser 미러](https://github.com/fosfrancesco/musicparser), CC BY-NC-SA 4.0 표기와 출처를 유지한다.

## 기존 문제 보존

`backend/content/catalog.json`과 iPad `Resources/practice-catalog.json`은 기존 3+59문제를 그대로 유지한다. 클래식은 별도 `classical-catalog.json`에 저장하고 `seed_questions`가 두 목록을 함께 등록한다. ID·자산 이름·순서가 기존 문제와 겹치지 않는다. 기존 문제 버전과 기존 응시 스냅샷은 수정하지 않는다.

기본 `GET /api/v1/questions/`는 기존 62문제다. `?collection=classical`은 클래식 문제이며 `composer`, `collection`을 반환한다. 페이지 이동에도 분류를 유지한다. 로컬 데모도 같은 분류와 시험 자산을 사용한다.

## 오선·조성·박자

빈 오선은 기존 1330×846 논리 좌표, 2660×1692 PNG, 4+4마디와 필기 좌표를 유지한다. 조표를 두 단에 표시하고 첫 단에 박자표를 표시한다. 조표 기호는 MuseScore 4.6.3/Leland 정답 SVG의 실제 윤곽과 음높이 기준점을 사용한다. PNG 해시는 문제 메타데이터와 번들에서 확인한다.

MusicXML 파서는 고정 조표 −7…+7, 장·단조를 지원하며 중간 조표·박자 변경, 불완전한 마디, 연결되지 않는 붙임줄은 거부한다. 시험 준비 시 안내·본문·음계의 조성과 박자를 대조한다. 단조 음계는 자연단음계다. 정답은 기존 MuseScore 4.6.3 + `compact-v1.mss`로 미리 생성한 2단 PNG를 사용한다.

2/2와 3/8도 파서·템포·예비박·템플릿 생성기에 추가했다. 2/2는 2분음표 기준, 3/8은 점4분음표 기준이다. 3/8의 15음 음계는 온전한 5마디를 사용한다. 현재 엄격한 수록 기준을 통과한 실제 문제의 박자는 2/4·3/4·4/4·6/8이다. 새 박자 문제를 억지로 만들지는 않았다.

## 피아노와 초상화

기본 그랜드 피아노는 일반 청음·클래식·미니게임 모두 미니게임의 YDP Grand Piano를 사용한다. `ClassicalPiano.load()`가 같은 SoundFont, 프로그램·뱅크, velocity 76, gain −3 dB와 해시를 적용한다. 기존 음색 선택의 그랜드 피아노 ID를 유지하므로 저장된 기본 설정에도 적용된다. 다른 악기 선택과 예비박은 유지된다. 서버 응시의 기존 재생 계약·시간표는 바꾸지 않는다.

작곡가 선택은 큰 격자 카드이며 초상화를 흑백·낮은 불투명도로 배경에 배치한다. 출처는 화면의 정보 버튼과 `Resources/composer-portraits.json`에 있다. 6개 역사적 초상화 축소본은 번들에 저장했다. 사티의 [Studio Hamelle 초상화](https://commons.wikimedia.org/wiki/File:Erik_Satie_portrait.jpg)는 CC0 원본의 크기와 SHA-1을 고정하고 CI에서 다운로드해 이미지 번들에 포함한다. 다운로드 전 소스 실행에서는 같은 원본으로 온라인 미리보기를 표시하며, 그림을 읽지 못해도 문제 응시에는 영향이 없다.

## 실행과 검증

기존 서버에서 새 문제 등록(실행용 `sori/` 폴더):

```powershell
cd C:\Users\123wh\Desktop\solfege\sori
docker compose up -d --build api worker
```

현재 Compose의 `api` 시작 과정은 자동으로 마이그레이션과 두 문제 목록 등록을 수행한다. 이미 새 이미지로 실행 중인 서버에 등록 명령만 다시 적용하려면 `docker compose exec api python manage.py seed_questions`를 사용한다. 등록은 같은 버전에 대해 반복 가능하다.

공유 저장소의 오프라인 자료 검사:

```powershell
cd C:\Users\123wh\Desktop\solfege\sori-github
python -m unittest discover -s scripts -p "test_*.py"
python scripts/fetch_composer_portraits.py
```

재생성은 클래식 전용 스크립트만 사용한다. 기존 62문제는 재생성하지 않는다.

```powershell
powershell -NoProfile -File scripts/build_classical_sheets.ps1
python scripts/build_classical_questions.py --render
```

필기 오선은 Windows System.Drawing, 정답은 설치된 MuseScore 4.6.3을 사용한다. 기본 음원 설치에는 기존 `fetch_classical_piano.py`, 다른 음색에는 `fetch_soundfont.py`를 사용한다.

macOS에서는 `swift test --package-path frontend`와 Xcode의 `ClassicalIntegrationTests`로 실제 앱의 목록·자산·준비·제출·기록 복구와 작곡가 화면 캡처를 검사한다. GitHub CI에 이 검사를 추가했다. Windows에서 Xcode 빌드나 실제 iPad의 음질은 검증할 수 없다.
