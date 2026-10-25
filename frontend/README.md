# SORI iPad frontend

Native SwiftUI / PencilKit app for the SORI v0.5.0 personal-practice contract. iPadOS 17+, Xcode 16+; no external Swift packages or network-loaded rendering code.

## Run

Open `IPadApp/IPadApp.xcodeproj`, select the shared `IPadApp` scheme and an iPad simulator, and Run. The default **local demo** works without a server. The app includes the exact API fixtures, staff template, MXL examples, a native notation renderer, and a fixed synthesized piano SoundFont. Demo results are explicitly marked as examples and do not analyze handwriting.

Use **연결 설정** to switch to the backend. Enter an absolute base URL ending `/api/v1/` and a backend-issued Bearer token. The token is stored in this device's Keychain, never UserDefaults or source control. Release requires HTTPS. Debug permits HTTP for local development. For a physical iPad use the backend PC's LAN address; `localhost` on an iPad means the iPad itself. A blank token field reuses the Keychain token for that server.

The Django backend implements the versioned SORI operations with PostgreSQL and an OpenRouter worker. Follow ../docs/IPAD-SETUP.md to start the server and issue development tokens. Local demo is deliberately separate from live API errors.

For Windows installation without a Mac, follow [the Sideloadly guide](../docs/WINDOWS-IPAD.md). Successful push CI runs publish the unsigned device Debug IPA as **SORI-iPad-install**; signing takes place on the user’s Windows PC.

## Screens and contract behavior

- Practice room: current user, five learning goals, paginated question list, pending creation recovery, saved unfinished attempt.
- Question instructions and preparation: use the attempt's immutable snapshot; download and verify template, main/scale MXL, validate the limited profile, prepare every segment and the bundled piano before `start`.
- Exam: fixed logical 1330×846 PencilKit canvas, black pens, vector eraser, undo/redo, Pencil or finger input, 100/150/200% zoom, continuous monotonic advisory timer (including system sleep). No automatic submission when time reaches zero.
- Playback: scale, tail, gap, exactly 11 ordered main segments; 480-PPQ MIDI, A4=440 Hz, velocity 80, fixed tempo. Merge ties before clipping; preserve leading/trailing silence. Native AVAudioSequencer and AVAudioUnitSampler schedule notes. Pause, background, interruptions and unplugged headphones stop all notes. User action resumes from the current segment, or restarts the interrupted gap.
- Submission: lock editing, save original PKDrawing, persist exact opaque sRGB PNG and UUIDs before uploading. Retry the same bytes and keys after uncertain network outcomes; pin the returned answer ID explicitly. Reconcile `GET attempt` before recovery to avoid uploading after a committed submit.
- Results: foreground-only polling, queued/processing, completed including genuine zero, needs_review with no score, failed with conditional retry, unknown-state fallback. After 60 seconds the user can leave and return via history. Submitted image annotations use normalized full-image coordinates; the separately rendered answer score is visible only after submission.
- History: records local to the authenticated user and API origin. Changing tokens for the same user retains access to local records. Missing raw drawing is never reconstructed from a PNG.

## Structure

| Directory | Responsibility |
| --- | --- |
| `IPadApp/IPadApp/Core/` | Codable contract models, origin security, HTTP/multipart/retry logic, bounded ZIP/XML parsing, normalized integer-tick events, MIDI, monotonic clock |
| `IPadApp/IPadApp/Services/` | durable app state and mock backend, protected local journal, Keychain, PencilKit/export, native piano playback |
| `IPadApp/IPadApp/Views/` | iPad screens, annotation overlay and limited native score renderer |
| `Tests/SORICoreTests/` | Swift Package contract and real URLSession transport tests with URLProtocol fixtures |
| `Tests/IPadAppTests/` | iPad-hosted export, journal, preparation/start/submit/restore demo terminal-state and complete 11-segment playback integration tests |
| `scripts/` | original SoundFont generator and actual Sampler offline audio verification |

Server enum fields decode as strings and branch explicitly. Added unknown values never crash decoding. Contract JSON uses one snake_case strategy and accepts ISO 8601 timestamps with or without fractional seconds. All authenticated assets must use the configured API origin. Redirects are refused, including public template redirects, to prevent credential leakage. Public templates receive no Authorization header. Downloads are streamed with explicit limits; CRC, compressed/uncompressed size, ZIP entry names, and XML shape are checked before use.

## Validation

From the repository root:

```sh
swift test --package-path frontend
xcodebuild -project frontend/IPadApp/IPadApp.xcodeproj -scheme IPadApp \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project frontend/IPadApp/IPadApp.xcodeproj -scheme IPadApp \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test
swift frontend/scripts/check_piano.swift frontend/IPadApp/IPadApp/Resources/sori-piano-v1.sf2
```

Select any installed iPad simulator name when your Xcode has a different device set. Physical Apple Pencil pressure, device speakers/headphones, signing and a live Django/recognition backend require device/integration checks beyond simulator coverage.

## Instrument profile

`sori-piano-v1.sf2` is original additive piano-like synthesis, not a recording of an acoustic piano. No third-party samples, fonts or runtime downloads are used. Its CC0-1.0 dedication, bank/program, gain, tuning, byte count and SHA-256 are in `Resources/instrument-profile.json`. The committed SF2 bytes are canonical. The generator is included for auditability; floating-point regeneration on a different platform is not a replacement for those bytes. If sound or mapping changes, assign a new profile ID and coordinate the contract change with the backend. The native renderer supports the limited sori-monophonic-v1 and sori-monophonic-v2 profiles; v2 includes 3/4, 6/8, sixteenth notes and 3:2 tuplets. It does not support arbitrary MusicXML.


## Tempo, audio recovery and Pencil updates

New v4 plans use quarter=80 in 4/4 and 3/4, dotted-quarter=55 in 6/8 (quarter BPM 82.5). The source policy is backend/content/playback-settings.json; scripts/build_question_assets.py generates TempoDefaults.swift. Existing v2/v3 snapshots and v1 resources remain supported. The new scale has 15 ascending/descending notes and its asset determines its length.

PianoAudioGraph is shared by the app and the macOS offline audio regression check. It creates fresh sampler nodes after a problem change or playback interruption. MIDI contains no program-change event that can override the loaded piano/click. New plans use the original synthesized sori-piano-v2.sf2; its generator and identity are frontend/scripts/generate_piano_v2.py and Resources/instrument-profile-v2.json. It is a synthesized piano timbre, not a recording.

The drawing canvas installs one UIPencilInteraction and respects the system double-tap preference for pen/eraser or previous-tool switching. Disabled double taps and locked submissions do not change tools. Physical Pencil behavior still requires an iPad check.
