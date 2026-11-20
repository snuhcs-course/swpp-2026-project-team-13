# Drill 고정 세트 시제품

기준은 main `435e40e`의 건반 계단이다. 처음 6개 칸만 고정 문제로 연결하고,
7–30번은 준비 중으로 표시한다. 기존 계단 디자인과 자유로운 칸 선택을 유지한다.

| 칸 | 게임 | 문제 수 |
|---|---|---:|
| C1 / 1 | Echo Dragon | 6 |
| D1 / 2 | Memory run | 4 |
| E1 / 3 | Rhythm puzzle | 5 |
| F1 / 4 | Echo Dragon | 6 |
| G1 / 5 | Rhythm puzzle | 5 |
| A1 / 6 | Memory run | 4 |

## 플레이와 진행

- 같은 칸은 악보·구간·재생 속도가 고정된다. 리듬 보기의 위치만 섞을 수 있다.
- 상단 진행바: 정답 초록, 오답·정답 공개 붉은색, 현재 문제 보라, 미진행 옅은색.
  체크/마이너스 표시와 접근성 문구로 색 이외에도 구분한다.
- 한 문제를 마치면 다음, 마지막에는 결과 보기로 이동한다. 전 문제를 정답 공개 없이
  맞혔을 때 칸을 클리어한다. 틀린 세트도 다른 칸으로 자유롭게 이동할 수 있다.
- X는 계단으로 돌아간다. 완료한 문제의 결과는 보관하고, 다음 진입 시 첫 미완료
  문제부터 다시 듣는다. 진행 중이던 개별 문제의 입력 내용 복원은 이번 범위에 없다.
- Memory는 2마디 이하 선율을 건반으로 복원한다. 이 시제품은 모두 2마디다.
- Rhythm은 기존 조각·타이 입력과 첫 오답/두 번째 힌트/세 번째 정답 공개를 유지한다.

## 새 Echo Dragon

계단에서는 기존 EchoDragonView/Model 대신 EchoFollowView/Model을 사용한다.
기존 단독 체험 코드와 저장 자료는 삭제하지 않는다.

1. 실제 악보에서 추출한 두 음을 들려준다.
2. Memory run과 동일한 MelodyPianoView에서 첫 음의 건반을 표시한다.
3. 사용자가 첫 음과 두 번째 음을 모두 직접 누른다. 첫 음을 자동 입력하지 않는다.
4. MelodyRunAudio에 누른 MIDI 번호를 그대로 전달한다. 전조·거울 규칙이나
   후보 건반과 실제 소리 사이의 별도 매핑은 없다. 옥타브와 순서도 일치해야 한다.
5. 첫 두 번의 오답은 다시 시도할 수 있다. 세 번째에는 정답을 공개하고 붉은 칸으로
   마무리한다. 사용자가 정답 보고 넘기기를 선택할 수도 있다.

## 문제와 저장 위치

- 원본은 기존 Practice 문제은행 및 클래식 선율이다. Exam 전용 문제는 배제한다.
- 서버: `backend/content/drills/drill-stage-sets-v1.json`.
- 문제 ID, 원본 해시, 구간, 템포를 고정한다. 공개한 v1을 덮어쓰지 말고 새 버전으로
  발행한다. 신규 JSON은 client-content-manifest의 해시 검증과 캐시를 사용한다.
- 앱에는 동일한 6개 시제품 세트를 작은 오프라인 데모에 포함한다. 전체 문제은행은
  서버에 유지한다. 기존 작은 데모 악보·리듬 구간을 재사용하고 코스 설정만 추가했다.
- 진행과 세트별 정답률·정답 공개·문제별 전경 경과 시간은 계정별 기기 저장 공간에
  기록한다. 기존 무작위 한 문제 진행 파일은 보관하고 새 파일로 분리한다.
  기기 간 진행 동기화와 학습자 약점 분석은 후속 범위다.
- 문제 개수 4/5/6이 실제 소요 시간의 동등성을 뜻하지는 않는다. 기록된 elapsedMs를
  게임별로 비교하고, 직접 풀어본 뒤 문제 구성·개수를 조정한다. 시간을 맞추기 위한
  강제 대기는 추가하지 않는다.

## 생성·검증·실행

```powershell
python scripts/build_drill_stage_sets.py
python scripts/build_content_delivery.py
python scripts/test_drill_stage_sets.py
python scripts/test_content_delivery.py
```

Core의 DrillStageSetTests, iOS의 DrillStairsIntegrationTests에서 고정 문제 선택,
두 음 필수 입력, 정답 공개와 클리어 구분, 완료 문제 보관을 검증한다.
Windows에서는 iOS 테스트를 실행할 수 없으므로 GitHub macOS CI 결과를 확인한다.

서버에도 새 문제 구성이 필요하다. 이 브랜치의 코드를 받은 뒤 API와 worker를
재빌드하고 새 IPA를 설치한다. 기존 DB·답안 볼륨을 삭제할 필요는 없다.

```powershell
docker compose --env-file backend/.env up --build -d --wait
```

확인 순서: 1번에서 표시된 첫 음까지 두 번 직접 입력 → 2번 4문제 → 3번 5문제 →
오답·정답 공개의 붉은 바 → 마지막 결과 보기 → 계단 복귀 → 도중 종료 후 재진입.
