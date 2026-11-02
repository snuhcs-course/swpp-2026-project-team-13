# 사용자 제공 브람스 악보

`classic/brahms.mscz`를 MuseScore 4.6.3으로 MusicXML로 내보낸 뒤 `brahms.txt`의 순서에 따라 8마디씩 분리했다. 원본은 `backend/content/source/brahms/`에 해시와 함께 보관한다. 총 106마디 중 1–88마디가 11개 선율이며, 뒤쪽 18마디는 전부 쉼표다.

10개를 새 UUID·버전 1로 별도 `brahms-catalog.json`에 등록한다. 기존 연습실 113개, 클래식 11개, 이전 버전·정답·진행 기록은 바꾸지 않는다. 로컬 데모와 서버에서 모두 클래식 → 브람스로 선택한다. 초상화와 출처도 기존 작곡가 카드 형식으로 추가한다.

| 원본 순서 | 곡명(사용자 메모) | 원본 마디 | 박자 | 제공 음계 |
| --- | --- | --- | --- | --- |
| 1 | 바이올린 협주곡 Op.77, 1악장 | 1–8 | 3/4 | D장조 |
| 2 | 바이올린 협주곡 Op.77, 3악장 | 9–16 | 2/4 | B자연단음계 |
| 3 | 교향곡 4번 Op.98, 1악장 | 17–24 | 4/4 | E자연단음계 |
| 4 | 교향곡 4번 Op.98, 4악장 | 25–32 | 3/2 | E자연단음계 |
| 5 | 교향곡 4번 Op.98, 2악장 | 33–40 | 6/8 | E장조 |
| 6 | 교향곡 4번 Op.98, 3악장 | 41–48 | 2/4 | C장조 |
| 7 | 교향곡 2번 Op.73, 1악장 | 49–56 | 3/4 | D장조 |
| 9 | 교향곡 2번 Op.73, 4악장 | 65–72 | 4/4 | D장조 |
| 10 | 교향곡 1번 Op.68, 3악장 | 73–80 | 2/4 | C장조(제공 편곡의 조표) |
| 11 | 교향곡 3번 Op.90, 1악장 | 81–88 | 6/4 | F장조 |

조표는 관계장조와 관계단조를 함께 가리키므로 조표만 보고 장조로 고정하지 않는다. 이번 파일에는 mode 정보가 없거나 `none`이다. 각 조표와 선율의 중심음·종지, 악장 정보를 함께 검토했고, 애매했던 3번 E단조와 6번 C장조는 사용자가 명시적으로 확인했다. 2번은 두 개의 샤프를 유지하면서 A♯ 이끎음과 끝의 B 종지에 맞춘 B단조 기준 음계를 제공한다. 5번은 교향곡 전체 제목의 E단조를 쓰지 않고 발췌 조표의 E장조를 사용한다. 각 판단은 `provenance.json`에 기록한다.

8번(교향곡 2번 3악장, 57–64마디)은 두 꾸밈음이 있어 현재 엄격한 단선율 재생 프로필에서 제외했다. 꾸밈음을 삭제하거나 박자를 재작성하지 않았다. 89–106마디의 쉼표 전용 구간도 제외했다. 나머지는 정확히 8개의 완전한 마디이며 음정·리듬·쉼표·붙임줄을 원본과 대조한다.

3/2와 6/4를 앱·박자 템플릿·예비박·서버 템포 정책에서 지원한다. 3/2는 2분음표=48, 6/4는 4분음표=96으로 재생하며 예비박은 각각 3개의 2분음표 박, 6개의 4분음표 박이다. 두 음계 모두 15개 음의 상행·하행을 2개의 완전한 마디에 담는다. 단조는 자연단음계이며 반음 간격도 검사한다.

정답은 기존 MuseScore 4.6.3 파이프라인으로 4+4마디 두 단에 렌더링한다. 음표가 많은 3/2만 `brahms-dense-v1.mss`의 작은 오선 크기를 사용하고, 각 정답의 스타일 해시를 별도로 기록한다. 기존 이미지와 전역 스타일 해시는 바꾸지 않는다. 빈 오선에는 조표·박자표·가까운 두 단·끝세로줄이 적용된다.

작품 정보 참고: [바이올린 협주곡](https://imslp.org/wiki/Violin_Concerto,_Op.77_(Brahms,_Johannes)), [교향곡 4번](https://imslp.org/wiki/Symphony_No.4,_Op.98_(Brahms,_Johannes)), [교향곡 2번](https://imslp.org/wiki/Symphony_No.2,_Op.73_(Brahms,_Johannes)). 발췌의 음표·조표는 인터넷 악보로 교체하지 않고 사용자 제공 파일을 유지한다.

재생성은 이미 보관된 소스만 사용한다.

오프라인 Python 검사 57개를 통과했고 기존 2,171개 자산 중 원래 음악·오선·정답·4개 카탈로그가 바이트 단위로 유지되는 것을 확인했다. 바뀐 기존 자산은 템포 정책, 새 정답 항목을 추가한 두 매니페스트, 작곡가 목록뿐이다. Swift/iPad 및 Django DB 검사는 Windows 환경에서 실행하지 못했으며 기존 CI 테스트에 회귀 검사를 추가했다.

```powershell
$sheetCode = Get-Content -Raw -LiteralPath scripts/build_classical_sheets.ps1
& ([scriptblock]::Create($sheetCode)) -Repository (Get-Location).Path -Compact
python scripts/import_brahms_questions.py --render
python scripts/test_classical_questions.py
```

서버 적용은 `sori/`에서 다음 명령을 실행한다. API 이미지를 다시 빌드해야 새 카탈로그가 포함된다. DB와 답안 볼륨은 유지한다.

```powershell
docker compose --env-file backend/.env up -d --build --wait api worker
docker compose --env-file backend/.env exec -T api python manage.py seed_questions
```
