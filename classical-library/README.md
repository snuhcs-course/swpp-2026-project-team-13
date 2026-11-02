# 클래식 청음 미리듣기

`CLASSICAL.html`을 Chrome/Edge/Safari에서 열고 곡의 **8마디 듣기**를 누르세요. 이 파일 하나로 인터넷 없이 재생할 수 있습니다. 조성·박자 표시, 작곡가 분류, 검색, 빠르기·반복·XML 다운로드를 제공합니다.

현재 앱 시험에 채택한 **7명·11개 선율**만 포함합니다. 원본 자체가 완전한 8마디인 XML을 사용하며, 못갖춘마디를 빼거나 마디를 자르고 쉼표를 보충한 자료, MIDI 추정본, 조성을 확인하지 못한 자료는 제외했습니다. 브람스·모차르트·말러·쇼스타코비치의 기존 조사 항목도 이 기준에 따라 이번 수록에서 제외했습니다.

HTML은 선곡·미리듣기용 합성 피아노입니다. 앱의 **클래식 탭 → 작곡가 → 문제**에서는 기존과 같은 청음 시험을 보며, 앱 음색은 미니게임과 공통인 YDP Grand Piano입니다. HTML과 앱은 같은 음높이·리듬의 XML을 사용하지만 HTML의 합성 음색은 앱의 샘플 피아노와 다릅니다.

앱 수록·조표·박자·정답 생성·검증 안내: [CLASSICAL-EXAMS.md](../docs/CLASSICAL-EXAMS.md). 원본 해시와 제외 사유는 `backend/content/source/classical/provenance.json`에 기록합니다. GTTM / musicparser 미러의 CC BY-NC-SA 4.0 출처 표기를 유지합니다.

시험 자산을 변경한 뒤 미리듣기를 맞추려면 저장소 루트에서 실행하세요.

```powershell
python classical-library/sync_exam_selection.py
python classical-library/validate_library.py
node classical-library/check_player.cjs
```

검사는 11개 XML의 마디 길이·붙임줄·다운로드 일치와 모의 Web Audio의 재생·정지·반복·필터를 확인합니다. 실제 브라우저 스피커 청음은 별도 확인이 필요합니다.
