# 표기 관습 피드백 검증

규칙 원본: backend/sori/notation-rules-v1.txt. 학생 원본 MusicXML/임시표/빔을 보존하고 음정·리듬과 표기 조언을 구분합니다. 새 규칙의 실제 인식률은 아직 측정하지 않았습니다. 아래 사례를 실제 iPad 필기로 제출하여 확인합니다. 기존 제출을 수정하지 말고 새 응시를 사용합니다. 유료 호출을 자동 반복하지 않습니다.

| 사례 | 예상 판정 |
|---|---|
| 앞 마디 F♯4, 다음 마디 F♮4를 명확하게 필기 | 다음 마디는 F4. ♮를 ♭로 읽지 않음, 권장 임시표를 오답 처리하지 않음 |
| 앞 마디 F♯4, 다음 마디 F4에 임시표 생략 | 실제 F4로 읽음. 필요하면 notation_suggestion, 음정 감점 없음 |
| ♮와 ♭ 구분이 어려운 필기 | recognition_uncertain. 추측으로 음정 오답 확정 금지 |
| 6/8의 8분음표 6개를 2+2+2로 묶음 | 음정·길이가 맞으면 그대로 인식하고 notation_error. 3+3을 설명 |
| 6/8의 정상 3+3 묶음 | 표기 오류 없음 |
| 셋잇단음표, 쉼표, 당김음의 관습적 묶음 | 무조건 빔 오류로 단정하지 않음 |
| 점이 빠져 실제 길이가 짧아짐 | rhythm_error. 정답의 점을 인식 XML에 자동 추가하지 않음 |
| 앞 마디에서 붙임줄로 넘어온 변화음 | 마디선 초기화를 기계적으로 적용하지 않고 붙임줄을 고려 |

피드백의 마디/음표 순서가 실제 필기와 맞는지도 기록합니다. 마디 전체 강조만 구현되어 있으며 정확한 이미지 음표 좌표 검출은 보류합니다.

근거: [Puget Sound, Common Rhythmic Notation Errors](https://musictheory.pugetsound.edu/mt21c/CommonRhythmicNotationErrors.html), [Texas A&M, Compound Meters](https://odp.library.tamu.edu/stepstomusictheory/chapter/compound-meters/), [Finale, Courtesy accidentals](https://usermanuals.finalemusic.com/PrintMusic2009Mac/Content/Courtesy_accidentals.htm), [MusicXML accidental](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/accidental/), [MusicXML alter](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/alter/), [MusicXML beam](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/beam/).
