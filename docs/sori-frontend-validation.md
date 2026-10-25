> 이 문서는 받은 v0.2.0 프론트엔드의 이전 기록입니다. 이번 v0.3.0 수정본의 검증 상태는 [VALIDATION.md](VALIDATION.md)를 따릅니다.

# SORI frontend validation

Date: 2026-10-23. Local environment: Xcode 27.1, iPad Pro 13-inch (M5) simulator running iPadOS 27.0.

- Swift Package tests: **28 passed, 0 failed**. Decode all canonical responses; preserve future enum values and real zero; fractional timestamps; compare every main/scale event and provided boundary fixture; ties, rests, corrupt/oversized ZIP, DTD, unsupported notation, tempo and measure checks; explicit MIDI tempo/480 PPQ/trailing silence; monotonic timer; annotations; multipart bytes; cross-origin bearer protection; 401 behavior and retry timing. URLProtocol-backed real URLSession calls cover all **13 operations** and their headers, methods and paths.
- iPad-hosted integration tests: **5 passed, 0 failed**. Export a real PencilKit stroke into opaque 8-bit 2660×1692 PNG and inspect the expected pixel location; persist raw drawing and stable submission keys; prepare/start/upload/submit/result and recreate the app model to recover the same submitted answer; durable mock idempotency and needs_review/failed/retry behavior; play the entire scale and **all 11 segments** through the native engine without errors. Whole-plan playback runs at 200 BPM with optional gaps set to zero to exercise every transition in about 55 seconds. Canonical 96 BPM content and clipping are independently checked by contract tests.
- Actual Apple Sampler offline render: bundled SF2 loads and produces non-silent MIDI 69; detected fundamental **440 Hz**. No external soundbank is required.
- Debug iOS Simulator app build: **passed**.
- Release generic iOS/arm64 app build with code signing disabled: **passed**.
- Manual simulator UI: practice room, instructions, preparation, countdown, black-pen toolbar, full staff canvas and initial playback inspected. Manual playback exposed a segment-transition error; the player now reuses one sequencer and clears notes without resetting the active sampler, covered by the whole-plan test.
- `git diff --check`: passed.

An initial export test exposed Xcode's PNG-byte optimization; the final app copies the raw template using `.pngdata`, preserving its published hash. An initial whole-plan run was interrupted when the simulator stopped; the subsequent full suite with a 120-second test allowance passed. Xcode emits beta-runtime AVAudioSession performance advisories during test setup; these are not test failures.

Not validated: a deployed SORI server, real recognition/grading engine, physical Apple Pencil pressure, physical device audio routes/latency, App Store signing/distribution. The existing Django scaffold only has a health endpoint. Demo scores are fixed API examples and are always labeled; they do not recognize handwriting.
