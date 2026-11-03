# MXL 전달과 iPad 합성 재생 — v0.3

서버는 문제 버전별 main 8마디와 scale 2마디를 MXL로 제공합니다. 앱은 파일 크기·SHA-256·제한된 XML 프로파일을 검사한 뒤 로컬 MIDI를 만들고 기존 sori-piano-v1 SoundFont로 재생합니다.

## 새 프로파일

sori-monophonic-v2는 MusicXML 4.0, part_id=P1, 높은음자리표, C Major 단선율, 고정 템포입니다. 지원 박자는 4/4·3/4·6/8입니다. 온음표부터 16분음표와 대응 쉼표, 최대 겹점, 임시표, 붙임줄, 3:2 셋잇단음표와 1·2단 빔을 지원합니다. 화음·다성부·박자/템포의 중간 변경·못갖춘마디·반복 진행은 지원하지 않습니다.

기존 sori-monophonic-v1 fixture는 회귀 검증을 위해 유지합니다. 실제 세 문제는 모두 v2입니다. XML의 인쇄 지시와 DTD는 서버의 등록 단계에서 정리하며, 원본 XML도 backend/content/source에 보관합니다. 정답의 음표와 리듬을 단순화하거나 학생 필기에 맞춰 바꾸지 않습니다.

## 정확한 시간과 구간

PPQ=480, MIDI와 XML의 템포 단위는 4분음표입니다. 마디 길이는 numerator × 480 × 4 / denominator ticks입니다. 4/4는 1920, 3/4와 6/8은 1440 ticks입니다.

길이는 XML의 duration 정수이며 기보상 type·dot·time-modification과 일치해야 합니다. 기본 길이 1920/960/480/240/120에 점과 3:2 비율을 정확한 정수 곱셈으로 검증합니다. 표시에는 type·dot·tuplet·beam을 보존합니다.

같은 음의 붙임줄은 연속성을 검사하고 먼저 합칩니다. 구간 [a,b]의 경계는 [(a-1)×마디길이, b×마디길이)이고, 걸친 음은 교집합만 잘라 구간 시작 기준으로 옮깁니다. 앞뒤 쉼을 삭제하지 않습니다. MIDI의 end-of-track과 실제 대기 시간도 같은 마디 길이를 사용합니다.

제시 순서는 기존 11개 구간을 유지합니다: 1–8 / 1–2 / 1–2 / 1–4 / 3–4 / 3–6 / 5–6 / 5–8 / 7–8 / 7–8 / 1–8. 먼저 같은 박자의 2마디 C Major scale을 제시합니다. 스케일 끝 3000ms, 각 구간 끝 5000ms 대기와 300ms release tail을 유지합니다.

## 표시와 저장

빈 오선은 박자별 새 템플릿 ID와 해시를 사용합니다. 좌표는 기존 논리 1330×846, 두 단·각 네 마디를 유지합니다. 내보내기는 2660×1692 불투명 PNG이며, .pngdata 번들 확장자로 Xcode의 PNG 최적화에 따른 해시 변경을 피합니다.

정답 렌더러는 박자별 음표 간격, 16분음표, 빔, 셋잇단음표를 표시합니다. 정답 렌더링과 학생 이미지의 주석 좌표는 서로 독립입니다. 캐시 파서 버전은 sori-parser-2로 올렸습니다.

## 확인

scripts/build_question_assets.py는 원본 음표를 비교한 뒤 결정적인 MXL bytes를 생성합니다. scripts/test_content.py는 원본과 등록 악보의 음악 정보를 대조합니다. 프론트의 ThreeQuestionTests는 실제 세 MXL의 파싱·박자·재생 구간·스케일·해시를 검증합니다. Swift 및 실제 iPad 검증은 Mac에서 수행해야 합니다.


## 예비박과 시간표 v3

처음·마지막 전체 재생은 클릭 트랙과 피아노 트랙을 하나의 format-1 MIDI에 넣습니다. 4/4·3/4·6/8은 각각 4·3·6 클릭이며 첫 박 velocity 110, 나머지 70입니다. 별도 짧은 PCM 클릭 샘플을 사용합니다. 예비박과 문제 사이 별도 시퀀서 재시작은 없습니다. 시간표·전체 길이는 API-CONTRACT.md를 따릅니다.

Apple sampler의 loadAudioFiles(at:)와 트랙 destinationAudioUnit을 사용합니다: https://developer.apple.com/documentation/avfaudio/avaudiounitsampler/loadaudiofiles(at:) , https://developer.apple.com/documentation/avfaudio/avmusictrack/destinationaudiounit . 실제 음량·기기 재생은 Mac 빌드 후 확인해야 합니다.
