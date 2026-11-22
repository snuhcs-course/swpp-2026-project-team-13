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
- Instructions occupy their own right rail (top rail in narrow windows), so the
  score, keyboard and drag destinations never sit underneath the coach card.
- Memory input/editing steps expose both the score and keyboard. Undo and the
  eraser work on real disposable MelodyAnswers and preserve the other measure.
- Rhythm step 3 requires tapping one highlighted piece, then dragging another to
  a designated empty slot. Step 5 requires enabling tie mode and connecting the
  two highlighted notes. An animated finger shows each gesture; reduce-motion
  users get a static cue. Next stays disabled until completion; Skip stays usable.
- The visual mask does not intercept minigame gestures. Each lesson explicitly
  enables the relevant controls, including score/keyboard editing together.

## Shared Practice / Exam guide: 시험 모드

The selection, ready and writing screens share one guide, including explicit
Practice-only pause/replay and self-marking explanations. The first card shows
**Tutorial / 시험 모드**. Automatic presentation is confined to selection/pre-start;
a restored running attempt never automatically opens help.

During an actual question the overlay uses the **actual writing screen**, without
replacing, resizing or reflowing its score or controls. Highlights have a dashed
border and an eye badge (**위치 안내**); controls are read-only throughout the guide.
Playback, its exact audio position and the remaining writing time pause in both
Practice and Exam. Closing resumes only if playback was running before opening;
an existing pause is preserved. Foreground restoration cannot bypass this guard.

Before selecting a question, a read-only preview uses the same extracted layout
components and an existing small-pack blank sheet. It has no AppModel, playback
engine, drawing controller, API calls or attempt side effects.

The segment timer is driven by the persisted playback cursor. The server's
recommended_end_at is advisory, not an enforced submission deadline; no server
migration or timer endpoint is required for this pause behavior.

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
- Core/TutorialProgress.swift: completion storage and responsive coach layout.
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
  completion-file preservation, and viewport/bubble layout tests.
- TutorialOverlayIntegrationTests checks manual start, preserved Echo reply/hearts,
  Memory replacement/undo/erase, mandatory Rhythm tap/drop/tie completion, and
  live Practice/Exam clock freezing, geometry preservation and exact resume.
- TutorialOfflineIntegrationTests checks small-pack examples and renders every
  tutorial step at several landscape/narrow window sizes. It runs in both the
  full simulator and slim device-policy test hosts in CI.
- python scripts/test_content_delivery.py verifies that the slim resource policy
  and sample pack remain intact.
