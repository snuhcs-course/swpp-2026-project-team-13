# 고난도 청음 59문항

기존 청음 연습 3개 다음에 **고난도 청음 01–59**를 추가했습니다. 서버와 오프라인 데모 모두 총 62개를 제공합니다. API는 20개씩 페이지를 나누므로 앱에서 ‘문제 더 보기’로 다음 문제를 불러올 수 있습니다.

## 데이터와 재생

- 입력: `naver_monophonic_001-059_full_draft/naver_monophonic_001-059_final`의 2026-10-29 최종 수정본.
- 각 문항은 8마디입니다. 박자는 2/4, 3/4, 4/4, 6/8, 7/8, 9/8, 12/8입니다.
- 원본 MusicXML을 `backend/content/source/naver/`에 보존합니다. `provenance.json`에는 출처 URL, 원본 XML·정답 PNG 해시, 문항별 검토 상태가 있습니다. 원본의 검토 상태는 원본 설명 그대로 유지하며 모든 채보를 검증 완료로 간주하지 않습니다.
- 48 divisions를 480 PPQ로 정확히 변환합니다. 음높이·쉼표·임시표·음가·붙임줄·빔·셋잇단 표기를 보존합니다. 앱용 MXL은 `questions/naver-NNN/v2/`에 있습니다.
- 정답 화면은 원본 최종 PNG를 사용합니다. 새 MXL 해시로 정답 이미지를 찾습니다. 기존 3문항과 과거 버전은 그대로 보존합니다.
- 원본에 조표·확정 조성이 없으므로 앱은 **조표 없음**으로 표시합니다. 준비용 스케일은 기존과 같은 C 기준 상행·하행 15음입니다.
- 청음은 기존 MIDI 방식과 앱 음색·템포 정책을 사용합니다. 원음 MP3는 번들에 포함하지 않습니다. 6/8·9/8·12/8은 점4분음표=55, 나머지는 4분음표=80이며 예비박은 박자표 분모 단위로 한 마디를 제공합니다.

`sori-monophonic-v3`는 새 박자, 32분음표와 3단 빔, C3–B6 음역을 지원합니다. `unspecified` 조성은 조표가 없고 조성이 확정되지 않은 자료를 뜻합니다. 기존 v1/v2 프로필과 응시 스냅샷도 계속 읽습니다.

## 재생성

저장소 안의 원본만으로 전체 카탈로그·MXL·앱 번들을 재생성합니다.

```sh
python scripts/build_question_assets.py
```

외부 최종 폴더를 처음 가져오거나 명시적으로 교체할 때만 다음을 실행합니다. 이미 배포한 음악 내용을 변경하면 새 문제 버전을 발행해야 합니다.

```sh
python scripts/import_naver_questions.py --source ../naver_monophonic_001-059_full_draft/naver_monophonic_001-059_final
```

추가 박자 오선 PNG는 Windows에서 `scripts/build_extra_sheet_templates.ps1`로 생성했습니다. 생성물은 저장소에 포함되므로 Mac·CI에서 해당 스크립트를 실행할 필요가 없습니다. 기존 `build_score_previews.py`는 첫 3문항을 렌더링하고 가져온 최종 이미지 매핑을 보존합니다.

## 앱과 서버에 반영

앱은 새 번들을 포함해 Mac/Xcode 또는 기존 GitHub CI로 다시 빌드하고 iPad에 설치해야 합니다. 서버는 프로젝트 루트에서 다음 명령으로 재빌드하면 시작 시 `seed_questions`가 62문항을 등록합니다.

```sh
docker compose --env-file backend/.env up --build -d --wait
```

독립 검증은 `test_content.py`, `test_engraving.py`, `test_playback.py`로 실행합니다. Swift 코어 테스트는 62개 MXL·스케일·11개 재생 구간·예비박을 확인하며 iPad 통합 테스트는 데모의 실제 자산 라우팅과 템플릿을 확인합니다. Django 테스트는 전체 페이지 조회와 59개 문제의 정답·MXL 다운로드를 확인합니다.

2026-10-31 Windows 확인: 콘텐츠·정답 이미지·재생·채점 계약·기존 음원·멜로디 라이브러리의 독립 테스트 27개가 통과했습니다. 기존 3개의 ID·메타데이터·MXL bytes가 Git 기준과 같고, 저장소 원본으로 재생성한 전체 자산 해시가 변하지 않는 것도 확인했습니다. 이 환경에는 Swift/Xcode가 없고 Django 패키지가 설치되지 않았으며 Docker 엔진도 실행되지 않아 iPad 빌드·Swift 테스트·DB 기반 API 테스트는 실행하지 못했습니다.
