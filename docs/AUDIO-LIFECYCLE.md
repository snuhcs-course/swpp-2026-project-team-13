# Audio playback lifecycle

## Failure and cause

The integrated `f1e0b2c` push failed two real-audio regressions:

- Practice review loaded the bank and created a sequencer **five times** where
  the test requires one across tempo changes, stop/replay and rapid seeks.
- Rhythm's third playback (132 quarter BPM, answer playback) received **zero
  captured frames**, not merely a quiet first note. The 150 ms lead did not fix it.
- The same source passed the parallel PR run. A single green run therefore did
  not establish a reliable playback lifecycle.

There were two conflicting policies in the code. `PianoSequenceTransport`
paused and restarted the hardware output on MIDI stop, seek and track edits.
Callers also treated `!engine.isRunning` as proof that their prepared bank and
sequence must be replaced. `stop()` even swallowed output restart errors with
`try?`. Consequently an ordinary playback operation could change resource
lifetime or leave the UI playing against a failed output restart.

Previous native crashes were in `AUHALOutputUnit_RenderNotifyCallback` on the
I/O thread. That stack identifies the output callback boundary; it alone does
not prove a particular Apple implementation defect or that timing padding is a
solution. This repair removes unnecessary I/O transitions and preserves the
existing stop-before-disposal rule instead of adding another delay.

## Ownership and transitions

| Operation | MIDI timeline | Output engine / instrument |
| --- | --- | --- |
| Prepare score / change tempo | Stop, edit the same tracks | Keep prepared resources and existing I/O |
| Pause / stop / seek | Stop; preserve or explicitly set position | Keep output available for live keys |
| Start / resume | Preroll then start | Start only if needed; propagate errors |
| Audio interruption / media reset / leaving a game | Stop active tasks and notes | Explicitly invalidate or release |
| Engine configuration change | Stop logical playback, mark resources invalid | Defer disposal to the next explicit preparation |
| Voice change / invalidated preparation | Dispose old sequence after stopping engine | Rebuild once with the requested bank |
| Full shutdown / owner deinit | Release sequence | Stop this sequence's engine before disposal |

`ready` / `resourcesInvalidated` describe **resource validity**. `isRunning`
describes **current I/O activity**. These are independent: a healthy prepared
engine may be paused. Practice review must not infer resource corruption from
that flag. Its configuration notification handler marks invalidation without
deallocating the reporting engine during notification delivery.

The common transport never pauses/restarts I/O in `stop`, `prepareToPlay` or
`configure`. Only `start()` starts output, and its errors reach existing model/UI
error handling. No `try? engine.start()` recovery is hidden inside stop.

## Verification

`AudioLifecycleIntegrationTests` explicitly pauses a prepared output, changes
tempo and requires the **same sampler and sequence plus a newly rendered piano
note**. It separately verifies deferred configuration recovery, a single rebuild,
and subsequent replay without another rebuild. The transport regression checks
that warm output stays running across seek and track changes.

Existing Memory/Rhythm sampled-piano pitch/harmonic checks, Practice rapid seeks
and exam pause/resume/jump checks remain enabled. Tap-based tests stop output
before removing their measurement taps, so test cleanup does not reconfigure a
live render graph while its owner is being disposed.

Pushes to `diagnostics/audio-*` run only the dedicated audio job, using the real
app with its slim bundle. It repeats all selected regressions **five times**,
sequentially in the same simulator process. Repetitions are not retries that
erase failures. PRs and main retain the full backend/frontend checks, including
these lifecycle tests. After the focused run passes, run the normal release CI.

Verification is pending until the workflow results are recorded in the PR.

## API contracts

- [AVAudioSequencer.stop](https://developer.apple.com/documentation/avfaudio/avaudiosequencer/stop%28%29): stopping MIDI preserves its position and does not stop the associated engine.
- [AVAudioEngine.pause](https://developer.apple.com/documentation/avfaudio/avaudioengine/pause%28%29): pauses output while retaining prepared resources.
- [Configuration changes](https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/avaudioengineconfigurationchange): hardware format changes stop/uninitialize I/O; do not deallocate the engine within the notification handler.
