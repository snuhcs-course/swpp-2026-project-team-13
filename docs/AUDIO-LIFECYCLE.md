# Audio playback lifecycle

## Evidence

- Integrated `f1e0b2c` reloaded the Practice piano/sequence five times and
  captured zero Rhythm frames on answer playback.
- Removing all I/O fencing while separating resource validity (`d951a3a`)
  passed 35 isolated audio executions, but full run `45116039930` still
  crashed in Rhythm immediately after MIDI stop.
- Faulting I/O stack: `_Block_copy -> AUHALOutputUnit_RenderNotifyCallback`.
  Main thread was already copying captured buffers after `audio.stop()`.
  The sequencer/graph remained in scope: deinit alone is not a sufficient diagnosis.
- Rhythm also compared a decayed fixed-time tail against an early-sustain
  harmonic threshold. The shared fresh-note probe fixes that measurement error
  without lowering thresholds, changing capture duration or accepting stale notes.

The native crash establishes an unsafe callback boundary in the mixed flow.
It does not identify an Apple-only defect or justify more timing padding.

## Invariants

1. Prepared resources and current output activity are distinct. A paused engine
   still owns its samples; `!isRunning` alone must not trigger bank replacement.
2. MIDI stop/edit/seek is performed with output paused so the render-notify
   callback cannot concurrently copy a block being changed.
3. Stop leaves output paused. It NEVER restarts I/O implicitly or hides start
   failure with `try?`. This avoids the earlier stop/start/pause/start cycles.
4. Playback and live-key input explicitly call the same throwing
   `startOutput()`: prepare output, start if needed, propagate failure.
5. Live-key startup does not restart the reference timeline. Memory resumes
   output at key input, including the transition from listening to recall.
6. Voice change / explicit invalidation rebuilds once. Normal pause, replay and
   tempo changes preserve the sampler and sequence.
7. Both PianoAudioGraph and PianoSequenceTransport stop their exact engine
   before releasing resources. The graph-level owner also covers sampler-only
   players that never create a sequencer.
8. Configuration notifications mark invalidation; disposal/rebuild is deferred
   until explicit preparation, outside notification delivery.

| Operation | Timeline | Output / resources |
| --- | --- | --- |
| Stop / seek / edit | Quiesce I/O, stop MIDI, mutate stopped tracks | Paused; retain bank and sequence |
| Play / resume | Explicit seek/preroll/start | Explicit throwing output startup |
| Live key | Reference remains stopped | Explicit throwing output startup, then live sampler |
| Configuration change | Stop logical playback; invalidate | Rebuild on next explicit preparation |
| Shutdown / owner release | Stop before sequence disposal | Stop output before node properties are released |

## Verification

Diagnostic branches `diagnostics/audio-*` run the production audio paths in a
slim iPad simulator bundle, sequentially, five repetitions without retry masking.
The selected cases cover resource retention, explicit recovery, graph disposal,
live-key output without reference restart, exam pause/resume/jump, Memory piano,
rapid Practice seeks and immediate Rhythm count-in/replay changes.

The intended focused count is ten cases x five = fifty executions. Live-key
verification waits for measured quiet output frames and then requires a fresh,
harmonically rich piano note; it does not insert a production startup delay.
All RMS/harmonic thresholds remain unchanged and Rhythm additionally checks A4
pitch. Tap-based tests stop output before removing their measurement taps.

PRs and main retain all backend/frontend, full/slim simulator and device checks.
An isolated green run is insufficient: the full mixed flow must pass before
merging or distributing a UAT release. Current results are recorded in PR #28.

## API references

- [MIDI stop preserves position and is separate from engine stop](https://developer.apple.com/documentation/avfaudio/avaudiosequencer/stop%28%29).
- [Engine pause retains prepared resources](https://developer.apple.com/documentation/avfaudio/avaudioengine/pause%28%29).
- [Do not deallocate an engine inside its configuration notification](https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/avaudioengineconfigurationchange).
