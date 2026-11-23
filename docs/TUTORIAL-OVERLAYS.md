# Tutorial overlays

## User flow

- The home entry is named **Minigames**.
- Echo Dragon, Memory run and Rhythm puzzle prepare their stage without playing.
  The bottom-right **시작** button begins the first question. Subsequent questions
  retain the existing stage flow. That same position then holds **제출**.
- First entry per account/game opens a short introduction, followed by spotlights.
  The shared questionmark.circle button (44 pt hit area) reopens the guide.
- Every step has 이전 / 다음 / 건너뛰기 and a step count. The last action is
  **안내 끝내기**. Finishing/skipping returns to the prepared game without autoplay.
- Minigame guides use a disposable example screen with the real keyboard,
  note renderers and answer-editing types. Trying the controls cannot affect an actual answer,
  lives, stage progress, exam score, rating or learning journal.
- Opening a guide during a minigame stops its sound and preserves its answer.
  On closing it, **계속하기** explicitly resumes play.
- Rhythm pieces with unusual lengths/tuplets have a separate first-use hint,
  shown only when such a visible choice actually appears.

## Minigame interaction

- The introductory purple label is **Tutorial**; the black title names the game.
- The normal full-width demo is retained. There is no scaled demo, left column,
  or reserved instruction rail. Only the floating popup moves between steps.
  Each stage uses the approved control-relative position. The code never searches
  for an unrelated empty corner. Page changes replace the whole popup without
  movement animations or a pressed button trailing behind the panel.
- Memory notation is top-aligned in its scroll area, like the real question.
  The input/editing popups occupy the remaining gap between notation and keys.
- Rhythm actions follow the choices immediately, like the real question. A
  flexible spacer must not push the controls down to the iPad's bottom edge.
  On larger iPads the board, choices and actions are centred as one group,
  matching the large-screen layout from PR #27 without separating its controls.
- Memory input/editing steps expose both the score and keyboard. Undo and the
  eraser work on real disposable MelodyAnswers and preserve the other measure.
- Rhythm step 3 requires tapping the first answer piece, then dragging the actual
  second answer piece (four sixteenths in this example) to its designated slot.
  It then unlocks all twelve choices and the full eight-beat board for free input.
  Next advances to step 4; there is no redundant completion sentence.
  Step 5 requires enabling tie mode and connecting the
  two highlighted notes. An animated finger shows each gesture; reduce-motion
  users get a static cue. Next stays disabled until completion; Skip stays usable.
- The visual mask does not intercept minigame gestures. Each lesson explicitly
  enables the relevant controls, including score/keyboard editing together.
- Tutorial count-in uses MIDI 60 for the original click sample, exactly like the
  games. The actual meter determines its beat spacing and total duration; accent
  is applied with velocity rather than transposing the sample to MIDI 84/76.

## Shared Practice / Exam guide: 시험 모드

Only the actual Practice/Exam writing screen opens the shared guide. Practice
entry, level selection, question bank, Exam recommendations and Ready to listen
have no help icon or automatic tutorial presentation. The first card shows
**Tutorial / 시험 모드**. The actual prepared writing screen opens it once per
account across both modes; a restored running attempt never automatically opens
help. The writing-screen icon is inset 14pt further from the trailing edge.

During an actual question the overlay uses the **actual writing screen**, without
replacing, resizing or reflowing its score or controls. Highlights have a dashed
border; controls are read-only throughout the guide. No eye badges, location
labels or "안내 중에는…" captions are shown. The overlay is hosted above the
navigation container and covers safe areas without changing the writing layout.
Playback, its exact audio position and the remaining writing time pause in both
Practice and Exam. Closing resumes only if playback was running before opening;
an existing pause is preserved. Foreground restoration cannot bypass this guard.

The small-pack read-only preview remains an offline rendering test fixture;
production navigation never opens it. Help during a real question uses that
question's actual writing screen.

Next section exists in the same fixed slot from the prepared state onward. It
is grey/disabled before starting and during audio, enabled during an active
writing wait, and disabled during help, pauses and the final section. Its
highlight is never substituted with the progress bar. Start and Submit reserve
the same 150pt action slot so the adjacent Next button does not shift sideways.

The segment timer is driven by the persisted playback cursor. The server's
recommended_end_at is advisory, not an enforced submission deadline; no server
migration or timer endpoint is required for this pause behavior.

Practice and Exam share the same `.exam` completion key. Entering either mode
first reaches the actual writing screen shows the guide once; the other does
not show it again. Help can reopen it from the writing screen. Keep the existing
per-account v2 history when updating copy.

## Approved placement

Every intro is centred. Button callouts sit 14pt above their named button;
screen-edge clamping is the only horizontal adjustment.

| Guide | Steps | Placement |
|---|---|---|
| Echo Dragon | 1 / 2 / 5 | Above Start / Replay / Submit; keep the dragon's face visible on Submit |
| Echo Dragon | 3 / 4 | Above the keyboard, aligned with the first key / keyboard centre |
| Memory run | 1 / 2 / 5 | Above Start / both Replay controls / Submit |
| Memory run | 3 / 4 | Same shallow popup in the score-to-keyboard gap |
| Rhythm puzzle | 1 / 2 / 6 | Above Start / both Replay controls / Submit |
| Rhythm puzzle | 3, all three actions | Same shallow popup immediately above the staff; staff, palette and drag route exposed |
| Rhythm puzzle | 4 | Immediately below the staff, trailing side; may cover choices |
| Rhythm puzzle | 5 | Above Tie before and after enabling it; staff and connection route exposed |
| Writing | 1 / 5 | Below the section progress bar, centred |
| Writing | 2 | Below the timer, trailing aligned |
| Writing | 3 | Below the pen/eraser tools, leading aligned |
| Writing | 4 | Lower trailing area of the sheet; leave the left staff visible |
| Writing | 6 / 7 | Above the actual Next control / main Submit action slot |

## Approved copy (2026-11-23)

- Echo 4: **같은 음정으로 답해요** / 드래곤과 같은 음정으로 두 번째 음을 눌러요.
- Echo 5: **드래곤에게 답해볼까요?** / 제출을 눌러서 드래곤의 반응을 확인해보세요.
- Rhythm 3: **리듬 조각을 넣어보세요**. Show only the purple tap instruction,
  then the purple drag instruction. Free input says: 리듬 조각을 **터치하거나
  끌어놓아서** 악보를 채워 보세요.
- Rhythm 4: **입력된 리듬 조각도 옮길 수 있어요** / 조각을 터치하면 지워져요.
  드래그해서 다른 칸으로 옮기거나, 악보 밖으로 끌어내 지울 수도 있어요.
- Rhythm 5: **이어지는 음은 타이로** / 타이를 켜고, 두 조각을 손가락으로 이어줘요.
- Writing intro: **시험 모드** / 8마디 단선율을 들으면서, 빈 오선 악보를 완성해요.
- Writing 1: **구간별로 들어요** / 스케일을 들은 뒤, 표시된 마디 구간을 순서대로 들어요.
- Writing 2: **남은 필기 시간을 확인해요** / 각 구간 사이에는 20초의 필기 시간이
  주어져요. 시간이 끝나면 다음 구간으로 넘어가요. 마지막 1~8마디 재생 후에는
  제출 전까지 2분이 주어져요.
- Writing 3: **쓰고, 고쳐보세요** / 펜과 지우개를 전환하거나, 펜 굵기를 변경할 수 있어요.
  The only footnote is: 더블 탭으로도 펜/지우개 전환이 가능해요.
  (Apple Pencil Pro 또는 Apple Pencil 2세대)
- Writing 4: **들은 선율을 적어요** / Apple Pencil로 빈 오선에 악보를 그려요.
- Writing 5: **Practice와 Exam의 차이** / Practice 모드에서는 구간을 터치하면 해당
  구간으로 바로 넘어갈 수 있어요. Exam 모드에서는 구간을 되돌리거나 진행을 일시정지할 수 없어요.
- Writing 6: **구간 대기를 건너뛰고 싶다면** / 일찍 필기를 마쳤다면, 바로 다음 구간으로 넘어갈 수 있어요.
- Writing 7 (both modes): **답안을 제출해요** / 제출 후에는 답안을 수정할 수 없어요.

## Where to edit

- Views/TutorialOverlay.swift: common icon, spotlight/mask, navigation and
  game-specific text/step order.
- Views/TutorialDemoScreen.swift: disposable interactive UI examples and piano
  playback. Memory's authored eight-note example is code, not a problem-bank item.
  Rhythm uses only the existing small offline sample pack, even in full builds.
- Services/MiniTutorialSession.swift: lesson actions and completion gates.
- Views/WritingScreenLayout.swift: shared live/preview layout components.
- Services/AppModel.swift and ScorePlaybackEngine.swift: writing-guide pause,
  exact-position resume and interaction guards.
- Core/TutorialProgress.swift: account-scoped completion storage and count-in.
- Core/TutorialPopupLayout.swift: approved per-step anchor rules and bounds.
- Each minigame model has an explicit preparation/start boundary and tutorial
  suspension guard. Existing model callers keep their previous automatic behavior
  unless they opt into requireManualStart().

Completion is in tutorial-overlays-v2.json under LocalStore's per-origin,
per-user directory. It is not the old device-global AppStorage boolean.
The revision intentionally reintroduces the revised guide once for existing users.
Deleting the local account removes the history too. This version is device-local;
the same account on a new iPad is guided again.

No generated mockup PNGs or full problem banks are added to the app bundle.

## Validation

- swift test --package-path frontend includes account/game isolation, corrupt
  completion-file preservation, control-relative popup placement and meter/click tests.
- TutorialOverlayIntegrationTests checks manual start, preserved Echo reply/hearts,
  Memory replacement/undo/erase, mandatory Rhythm tap/drop/tie completion, and
  live Practice/Exam clock freezing, geometry preservation and exact resume.
- TutorialOfflineIntegrationTests checks small-pack examples and renders every
  tutorial step at several landscape/narrow window sizes. It runs in both the
  full simulator and slim device-policy test hosts in CI.
- python scripts/test_content_delivery.py verifies that the slim resource policy
  and sample pack remain intact.

## UAT integration

PR #27's learning-goal removal and large-iPad fixes are included in the integrated
tutorial branch. Writing-sheet centring lives in the shared WritingSheetFrame,
so opening help cannot undo the 12.9/13-inch layout fix. The server must apply
migration 0011 along with this app: goal selection and PATCH /me/ are removed.
Docker's API entrypoint runs migrations before serving requests.

The Practice replay stress-test crash exposed an unsafe sequencer lifetime:
AVAudioSequencer was released while AVAudioEngine could still be rendering.
PracticeReviewPlayback now uses the same persistent PianoSequenceTransport as
the minigames. Tempo/score changes edit stopped tracks without replacing the
sequence or restarting its loaded piano graph. Full shutdown/instrument changes
stop the engine before releasing the sequence. The existing rapid-seek,
tempo-change, pause/resume and instrument-load-count test remains enabled and
also verifies that every tempo and range reuses the same sequence.

The same lifetime issue also surfaced in the live exam pause/resume/jump test.
PianoPlayback now caches each section's notes and count-in separately and
reconfigures the same transport's stopped tracks. It keeps the original click
pitch, velocities, count-in offset and saved playback position. Graph recovery
stops the engine before disposal. The live jump regression waits until the
requested section is actually loaded and checks that the sequence was reused.
The shared transport also stops its own engine in deinit, before Swift releases
its sequence, so a paused screen/model disappearing cannot leave an active
render callback pointing at a disposed sequence. A real-graph disposal test
checks this cleanup independently of a caller's explicit shutdown method.

The initial output pause fence and timing-lead fix did not establish reliable
replay: a subsequent run reloaded Practice's bank five times and captured zero
frames on Rhythm's answer playback. MIDI callback changes now occur with output
paused; playback and live keys restart output explicitly and propagate errors. Resource
invalidation is explicit rather than inferred from `engine.isRunning`; output
start errors propagate to the UI. Full shutdown still stops output before
sequence disposal. See [Audio lifecycle](AUDIO-LIFECYCLE.md) for the evidence,
ownership rules and focused five-repeat verification before release CI.
