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
- Guides use a disposable example screen with the real keyboard, note renderers
  and PencilKit surface. Trying the controls cannot affect an actual answer,
  lives, stage progress, exam score, rating or learning journal.
- Opening a guide during a minigame stops its sound and preserves its answer.
  On closing it, **계속하기** explicitly resumes play.
- Rhythm pieces with unusual lengths/tuplets have a separate first-use hint,
  shown only when such a visible choice actually appears.

## Exam

The Exam selection screen, ready screen and writing screen use the same guide.
Automatic presentation is confined to selection/pre-start. A restored running
exam never automatically opens the guide. Manual help during an active exam
does **not** pause/extend the real exam, and the overlay states that time continues.
The example uses its own drawing controller, never AppModel's answer or API.
Practice-only playback controls are not presented as Exam controls.

The existing Practice entry guide remains a separate description of self-marking;
its help icon has the same shape and hit area.

## Where to edit

- Views/TutorialOverlay.swift: common icon, spotlight/mask, navigation and
  game-specific text/step order.
- Views/TutorialDemoScreen.swift: disposable interactive UI examples and piano
  playback. Memory's authored eight-note example is code, not a problem-bank item.
  Rhythm uses only the existing small offline sample pack, even in full builds.
- Core/TutorialProgress.swift: completion storage and responsive bubble layout.
- Each minigame model has an explicit preparation/start boundary and tutorial
  suspension guard. Existing model callers keep their previous automatic behavior
  unless they opt into requireManualStart().

Completion is in tutorial-overlays-v1.json under LocalStore's per-origin,
per-user directory. It is not the old device-global AppStorage boolean.
Deleting the local account removes the history too. This version is device-local;
the same account on a new iPad is guided again.

No generated mockup PNGs or full problem banks are added to the app bundle.

## Validation

- swift test --package-path frontend includes account/game isolation, corrupt
  completion-file preservation, and viewport/bubble layout tests.
- TutorialOverlayIntegrationTests checks that preparation/foreground/help cannot
  start playback early, and that help preserves an Echo reply and its hearts.
- TutorialOfflineIntegrationTests checks small-pack examples and renders every
  tutorial step at several landscape/narrow window sizes. It runs in both the
  full simulator and slim device-policy test hosts in CI.
- python scripts/test_content_delivery.py verifies that the slim resource policy
  and sample pack remain intact.
