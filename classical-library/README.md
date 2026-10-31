# 클래식 청음 라이브러리

`CLASSICAL.html`을 Chrome/Safari에서 열면 오프라인으로 36개 선율을 들을 수 있습니다. 작곡가별 분류, 검색, 피아노 합성 재생, 빠르기·기준 템포, 반복, 선곡 별표, XML 다운로드를 제공합니다. 원곡 녹음의 재생이 아닙니다.

- 한 파트·고정 박자·8개 마디의 MusicXML 발췌본: 32개 (`xml/`).
- 원본이 8마디보다 짧은 참고 선율: 4개. 8마디 문제로 표시하지 않습니다.
- 쇼스타코비치 교향곡 5·7·10번: 외부 청음·악보 링크 3개. 8마디 XML 미확보이며 앱 안에서 합성 재생되는 항목이 아닙니다. 10번 MIDI 링크는 파일 다운로드 링크입니다.
- 말러: 실제 교향곡 1번 1·3악장 MIDI에서 추출한 선율 2개와 교향곡 8번 종결부 총보 MusicXML에서 추출한 합창 선율 1개. 가곡을 교향곡으로 표기하지 않았습니다.

앱의 **클래식** 탭은 이 HTML을 로컬 리소스로 불러오는 별도 청음 라이브러리입니다. 기존 시험형 청음 문제 카탈로그/시도/서버 채점과 연결하지 않았습니다. 기존 샘플 3개 + 고난도 59개를 변경하지 않습니다. 새 앱 빌드·설치 후 탭이 표시됩니다.

## 원본과 발췌

GTTM은 연구자들이 클래식 단선율 발췌를 수집한 코퍼스입니다. 사이트가 8마디 코퍼스로 소개하더라도 실제 XML은 5~11개 구획으로 나뉘는 사례가 있으므로 직접 검사했습니다. 원본에 못갖춘마디/선행 쉼표가 있으면 첫 구획을 제외하고 연속 8개 마디를 선택하기도 했습니다. 마지막 부족분에 쉼표를 넣은 경우도 있습니다. 각 항목의 `sourceMeasures`, `changes`, `source`에 선택 구간·변경·확보 출처를 기록했습니다. 원전에서의 자연스러운 종지를 보장하지 않습니다.

말러 교향곡 1번은 Lucarelli의 관현악 MIDI를 사용했습니다. 트랙별 미세 시작 오프셋을 제거하고 16분음표 격자로 양자화했으며 청음용으로 한 옥타브 올렸습니다. 원전 기보를 정확하게 복원한 MusicXML이 아닙니다. 원전 마디 번호는 미확정이며 MIDI의 4분음표 위치를 별도로 기록했습니다. 교향곡 8번은 maialib 배포 MXL의 P71, 파일 내 29–36마디입니다. 전체 교향곡의 원전 마디 번호와 구분합니다. 연주 지시·악기·가사·장식 표기는 단순화했습니다.

## 출처와 이용 조건

- [GTTM Database](https://gttm.jp/gttm/database/): Masatoshi Hamanaka, Keiji Hirata, Satoshi Tojo.
- [실제 확보한 GTTM 미러](https://github.com/fosfrancesco/musicparser/tree/570df3ba3b2900f470ca2b16ac3fb415424c67ee/data/gttm): Francesco Foscarin, Daniel Harasim, Gerhard Widmer. 저장소는 CC BY-NC-SA 4.0을 명시합니다. [라이선스 사본](GTTM-MIRROR-LICENSE.md)을 보존했습니다.
- [말러 교향곡 1번 MIDI](https://github.com/gasman/mahlerproject/tree/b718acd293480541ec76c856c91ca9bee8f1346c/midi): 파일명에 Lucarelli 크레딧. MIDI 편집본 이용 조건은 별도 확인이 필요합니다.
- [말러 교향곡 8번 MXL](https://github.com/nyckmaia/maialib/blob/72d1e72a7961333411eaecc3fd0b475fb677e502/maialib/xml-scores-examples/Mahler_Symphony_8_Finale.mxl): 저장소 코드 라이선스가 악보 판본의 이용권까지 보장한다고 판단하지 않았습니다.
- [쇼스타코비치 교향곡 MIDI 목록](https://classicalmidi.co.uk/shostakovich.htm), [7번 침공 주제 악보](https://musescore.com/user/52237487/scores/14272558), [5·7번 음반사 청음](https://www.pentatonemusic.com/product/shostakovich-symphonies-nos-5-7/).

이 자료는 개인 청음·선곡용이며 공개 앱에 재배포할 권리를 모두 확인한 패키지가 아닙니다. GTTM 발췌 데이터의 CC BY-NC-SA 표시를 유지하세요. 원작과 디지털 악보/MIDI 편집본의 권리는 별개입니다. 원본 전체 MIDI·교향곡 총보는 Git 패키지에 포함하지 않고 짧은 발췌와 출처를 보존합니다.

## 다시 만들기와 검사

저장소 루트에서 다음을 실행합니다. Python 표준 라이브러리와 Node만 사용하며, 기존 시험형 문제 빌더를 실행하지 않습니다.

```powershell
python classical-library/render_library.py
python classical-library/validate_library.py
node classical-library/check_player.cjs
```

첫 명령은 선택 데이터에서 HTML과 32개 XML을 재생성하고 앱의 `classical-library.html`만 갱신합니다. `library-data.json`에 편집 결과와 출처가 함께 들어 있습니다.

검사: 32개 파일의 한 파트/8마디, 마디별 길이, 음표 기보 길이, 붙임줄 연결, 재생 이벤트 범위, 다운로드 XML 일치를 검증했습니다. 모의 DOM/Web Audio로 36곡의 재생 스케줄, 재생 준비 중 정지, 반복/속도 변경, 작곡가 필터, 백그라운드 정지를 검사했습니다. 실제 브라우저 화면·스피커 청음 및 iPad/Xcode 빌드는 이 Windows 환경에서 검증하지 못했습니다. 브라우저 자동화는 현재 URL을 확실하게 확인할 수 없어 중단됐습니다.

## 네이티브 앱 연결

`Views/ClassicalLibraryView.swift`가 오프라인 HTML을 WKWebView에 표시합니다. 출처 링크는 Safari로 열고 앱 안의 파일 다운로드 버튼은 숨깁니다. 탭 이탈, 앱 비활성화, 오디오 인터럽트, 오디오 경로 변경 시 재생을 멈춥니다. Web Audio 합성 피아노를 사용하며 기존 시험형 플레이어나 서버 API를 변경하지 않습니다.

기존 파일 변경은 `ContentView.swift`의 메뉴·화면 연결 2줄과 `AppModel.Screen`의 `classical` 항목 추가뿐입니다. 문제 카탈로그·59개 악보·기존 HomeView는 수정하지 않았습니다.
