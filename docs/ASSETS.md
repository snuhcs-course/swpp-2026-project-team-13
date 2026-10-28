# 악보와 음원 자산

## MuseScore 정답 이미지

MuseScore Studio 4.6.3 설치 후 저장소 루트에서 python scripts/build_score_previews.py를 실행합니다. Windows 기본 설치 경로를 지원하며 다른 경로는 --musescore로 지정합니다. 생성된 backend/content/engraving 및 앱 Resources의 이미지는 커밋합니다. 배포·앱 실행에는 MuseScore 설치가 필요하지 않습니다. 기본 렌더러 설정에 의존하지 않고 compact-v1 스타일을 사용합니다. 다른 MuseScore 버전으로 갱신할 때는 세 문제를 다시 눈으로 확인하고 버전·스타일을 함께 갱신합니다.

4+4마디, 마디 번호 없음, Leland 글꼴, 좁은 두 줄 간격입니다. 직전 마디 변화음 뒤의 권장 제자리표는 표시 사본에만 들어갑니다. 정답 원본·AI 인식 MusicXML을 렌더링 결과로 덮어쓰지 않습니다. PNG는 현재 표시용, SVG는 추후 확대 표시용 원본입니다. CLI 문서는 과거 버전 옵션을 포함하므로 여기서 검증한 -S/-j/-T/-r만 사용합니다. [공식 내보내기 설명](https://handbook.musescore.org/file-management/file-export), [CLI](https://handbook.musescore.org/appendix/command-line-usage).

## 선택 가능한 음색

빌드 전에 python scripts/fetch_soundfont.py를 실행합니다. GeneralUser GS 2.0.3의 고정된 커밋 684543d5e5efaef08d02be50dcda8d552478fa60에서 약 31 MB SF2와 원문 라이선스를 받습니다. 이미 받은 파일은 SHA-256으로 확인하며 python scripts/fetch_soundfont.py --check는 네트워크 없이 검사합니다. 다운로드된 은행 파일과 manifest는 Git에서 제외하며 CI가 iPad 빌드 전에 받습니다. 앱에는 파일·해시 manifest·원문 라이선스를 포함하므로 기기 실행은 오프라인입니다.

프리셋 정의는 frontend/IPadApp/IPadApp/Resources/instruments.json 한 곳에 있습니다. 기본 그랜드 피아노(0), 전기 피아노(4), 하프시코드(6), 비브라폰(11), MIDI bank 0을 사용합니다. 추가할 때 목록과 실제 AVAudioUnitSampler 오프라인 재생 검사를 함께 갱신합니다. 음높이/템포/예비박과 음색 선택은 독립입니다. 기존 SORI 자체 음원은 과거 검증 자산으로 보존합니다.

제작자: S. Christian Collins. [GeneralUser GS 공식 저장소](https://github.com/mrbumpy409/GeneralUser-GS), [원문 이용 조건](https://github.com/mrbumpy409/GeneralUser-GS/blob/684543d5e5efaef08d02be50dcda8d552478fa60/documentation/LICENSE.txt). 제작자는 소프트웨어 포함과 변형을 허용하지만 일부 과거 샘플의 최초 출처를 완전히 확인할 수 없다는 설명도 명시합니다. 이를 CC0 음원으로 표기하지 않습니다. 앱 설정의 음원 출처 화면에서 원문을 볼 수 있습니다. AVAudioUnitSampler에서 모든 프리셋의 실제 재생 검사가 통과해야 배포합니다.
# 멜로디 런 클래식 피아노 추가

미니게임용 피아노는 [FreePats YDP Grand Piano](https://freepats.zenvoid.org/Piano/acoustic-grand-piano.html) 2016-08-04판을 사용합니다. Yamaha Disklavier Pro 실녹음이며 Zenph Studios / Dr. Mikhail Krishtal와 팀, SoundFont 제작 Roberto를 표시합니다. 이용조건은 [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/)입니다. 기존 시험의 GeneralUser GS는 유지합니다.

Mac에서 앱을 빌드하기 전에 다음을 실행합니다. GitHub CI는 두 명령을 모두 실행합니다.

```sh
python3 scripts/fetch_soundfont.py
python3 scripts/fetch_classical_piano.py
```

새 설치 스크립트는 버전이 명시된 원본 아카이브에서 SF2와 원본 제작자 정보를 읽어 고정된 번들 파일로 저장합니다. 음원은 수정하지 않고, 미니게임의 듣기·입력·결과 재생 모두 velocity 76으로 재생합니다. 캐시·번들 검증에는 생성된 SHA-256과 바이트 수를 사용합니다. 다운로드한 음원·해시 기록·제작자 정보는 Git에서 제외하고 CI 캐시로 보존합니다. `melody-piano-profile.json`과 설치 스크립트는 소스에 포함합니다.

Windows의 `scripts/test_classical_piano.py`는 기존 원본 SF2를 사용하여 설치·해시·크레딧 보존을 검사합니다. 원본 YDP의 실제 sampler 로딩과 C1–C8 출력은 Mac CI의 `frontend/scripts/audio-check/main.swift`에서 검사합니다. 이 PC에서는 DNS 제한으로 원본 다운로드와 실청을 하지 못했습니다.
