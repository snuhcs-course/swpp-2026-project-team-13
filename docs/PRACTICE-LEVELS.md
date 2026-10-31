# 연습실 난이도와 새 8마디 문제

나의 연습실에서 큰 **초급 / 중급 / 고급** 카드를 고르면 해당 문제 목록으로 이동한다. 문제 선택 이후에는 기존 준비·음계·예비박·11개 재생 구간·필기·제출·정답·기록 복구 흐름을 사용한다. 클래식 11문제는 작곡가별 탭에 그대로 둔다.

| 분류 | 문제 수 | 자료 |
| --- | ---: | --- |
| 초급 | 40 | 1,047 XML 자료 중 선별한 완전한 8마디 |
| 중급 | 14 | 기존 청음 연습 1–3 + Pages 1–2의 11문제 |
| 고급 | 59 | 기존 고난도 청음 01–59 |
| 클래식 | 11 | 기존 작곡가별 문제 |

연습실은 113문제, 클래식까지 총 124문제다. API의 모든 페이지를 읽은 뒤 난이도별로 분류하므로 뒤 페이지의 초급·중급도 처음부터 선택할 수 있다.

## Pages 1–2 분리

사용자가 검증한 `Melodic Exercises - Pages 1-2.musicxml`의 96마디를 1–8, 9–16처럼 고정된 8마디씩 나눈다. **41–48마디는 모든 음표가 쉼표여서 제외**하고 나머지 11개는 모두 수록한다. 파일에 남아 있는 과거의 잠정 판독 주석으로 추가 제외하지 않는다.

각 구간 시작까지의 박자·조표·divisions를 이어받고 마디 번호를 1–8로 다시 매긴다. 음높이·길이·쉼표·붙임줄·셋잇단음표의 비율은 원본과 대조한다. Flat의 선택적인 잇단음표 표시 세부 정보는 기존 앱이 읽는 start/stop 형식으로 정리한다. 원본 파일과 구간·해시·검증 결정은 `backend/content/source/practice-import/provenance.json`에 보관한다.

## 초급 40문제 선정

`ear_training_8bars_1047_XML_only/ear_training_8bars_1047`의 일반 8마디 961개를 검토하고 못갖춘마디 86개는 제외한다. 지원하는 단선율·음역·박자·리듬과 온전한 붙임줄을 검사한다. 다음 기준으로 너무 단순하거나 초급 범위를 벗어나는 문제를 걸러낸다.

- 최소 20음, 서로 다른 음높이 5개, 완전5도 음역, 서로 다른 음길이 2종류.
- 최대 48음·19반음 음역·조표 3개·8분음표보다 짧지 않은 음길이.
- 조성 밖의 음 2개 이하, 셋잇단음표 음 6개 이하, 최대 도약 1옥타브.
- 같은 선율 중복을 피하고 교재·박자·조성이 고르게 섞이도록 40개를 선정.

선정 결과는 9개 교재, 2/2·2/4·3/4·4/4·6/8의 5개 박자와 장·단조를 포함한다. 출처는 **The Trained Ear · Andre Mount · CC BY-SA 4.0**이며 원전별 표기와 전체 라이선스는 `TRAINED-EAR-LICENSE.md`에 유지한다.

새 문제는 별도 `additional-practice-catalog.json`과 UUID 기반 자산 이름을 사용한다. 기존 62문제·클래식 11문제의 ID, 버전, XML, 빈 오선, 정답 그림과 과거 응시 스냅샷을 변경하지 않는다. 조표는 두 단의 빈 오선에 표시하며, 자연 장·단음계와 MuseScore Studio 4.6.3 정답 그림을 함께 제공한다.

## 개발 토큰 저장

연결 설정에서 **이 서버의 토큰을 기기에 저장**을 선택하고 서버에 연결한다. 다음 실행·업데이트부터 입력칸을 비워 두어도 저장한 토큰을 재사용한다. 입력칸에 토큰을 다시 표시하지 않고 **저장된 토큰이 있어요**라는 상태를 표시한다. 체크를 해제하면 이 서버의 저장 사본을 지우며 현재 실행 중의 연결은 메모리의 토큰으로 계속 사용할 수 있다.

이전 Keychain 토큰은 성공적으로 연결한 뒤 새 저장소로 옮긴다. 앱 컨테이너 안에 iPad의 파일 보호를 적용한 사본을 보관하고 Keychain에도 저장을 시도한다. 이 폴더는 백업에서 제외하고 파일 권한을 0600으로 제한한다. 토큰 값은 UserDefaults·로그·Git에 기록하지 않는다. Keychain 접근 그룹이 바뀐 업데이트에서도 같은 앱 데이터가 보존되면 저장 사본으로 복구할 수 있다. 서버 주소의 대소문자·기본 포트·끝 슬래시는 저장 계정 비교 때 정규화한다.

이미 이전 Keychain 접근을 잃었다면 이번 버전에서 한 번 입력해 저장해야 한다. 앱을 삭제하거나 다른 Bundle ID로 설치하면 보존되는 업데이트가 아니므로 앱 데이터와 토큰 복구를 보장하지 않는다. 서버의 `issue_dev_token`은 기존 사용자 토큰을 재사용하며 서버 재시작마다 새 토큰을 발급하지 않는다.

설계 근거: [Apple의 Keychain 접근 그룹](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps), [파일 보호 등급](https://support.apple.com/en-ca/guide/security/secb010e978a/web).

## 앱과 서버에 반영

GitHub 공유 폴더에서 수정본을 업로드한다. 이 작업은 로컬 커밋까지 저장하며 push는 일반 PowerShell에서 실행한다.

```powershell
cd C:\Users\123wh\Desktop\solfege\sori-github
git status
git log -3 --oneline
git push origin feat/sori-ipad-integration
```

GitHub Actions에서 테스트와 IPA 생성이 끝나면 새 IPA를 **기존 앱 위에 같은 Bundle ID로** 설치한다. 서버 작업 폴더에서 다음을 실행한다. DB와 답안 볼륨은 삭제하지 않는다.

```powershell
cd C:\Users\123wh\Desktop\solfege\sori
docker compose --env-file backend/.env up -d --build --wait api worker
docker compose --env-file backend/.env exec -T api python manage.py seed_questions
```

API 시작 시에도 `boot.py`가 같은 등록을 수행한다. 재실행은 같은 문제 버전을 중복 생성하지 않는다. 앱에서 연습실을 새로고침하면 초급 40·중급 14·고급 59가 표시된다. 로컬 데모는 새 IPA의 같은 113문제를 서버 없이 제공한다.

## 재생성과 검사

첫 선정 이후에는 체크인한 원본과 provenance만으로 재생성한다. 기존 문제를 다시 만드는 스크립트는 실행하지 않는다.

```powershell
cd C:\Users\123wh\Desktop\solfege\sori-github
$sheetCode = Get-Content -Raw -LiteralPath scripts/build_classical_sheets.ps1
& ([scriptblock]::Create($sheetCode)) -Repository (Get-Location).Path
python scripts/import_practice_questions.py --render
python -m unittest discover -s scripts -p "test_*.py"
```

`test_practice_import.py`는 11구간·40개 선정·원본 음표·온전한 마디·자산 해시·조표·정답 번들을 검사한다. Swift의 `PracticeImportTests`는 실제 51개 XML과 모든 시험 구간 및 서버 페이지 이동을 검사한다. `SavedTokenStoreTests`는 업데이트에 따른 Keychain 접근 실패를 모사해 파일 복구·계정 분리·저장 해제를 검사한다. iPad의 `PracticeLibraryIntegrationTests`는 데모 자산·시험·기록 복구와 난이도 화면 캡처를 검사한다. 이 테스트들은 CI에 포함한다.
