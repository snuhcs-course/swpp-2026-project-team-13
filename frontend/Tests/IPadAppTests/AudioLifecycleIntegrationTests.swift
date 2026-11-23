import XCTest
import AVFoundation
@testable import IPadApp

@MainActor final class AudioLifecycleIntegrationTests: XCTestCase {
    func testGraphOwnerStopsOutputEvenWhenTheEngineIsRetained() throws {
        let profile=try ClassicalPiano.load()
        var graph:PianoAudioGraph?=PianoAudioGraph()
        try graph?.rebuild(bank:profile.url,program:profile.program,bankMSB:profile.bankMsb,
                           bankLSB:profile.bankLsb,clickURL:nil,gain:1)
        let engine=try XCTUnwrap(graph?.engine)
        defer { engine.stop() }
        try engine.start()
        graph=nil
        XCTAssertFalse(engine.isRunning,"The graph owns output lifetime even without a sequencer")
    }
    private func score() -> MusicScore {
        MusicScore(tempo:80,measures:8,events:(0..<32).map {
            MusicEvent(midi:69,onset:$0*480,duration:480)
        },symbols:[])
    }

    func testLiveKeysResumeOutputWithoutRestartingTheReferenceClock() async throws {
        let graph=PianoAudioGraph(), audio=MelodyRunAudio(graph:graph), probe=PianoTimbreProbe()
        try audio.prepare()
        let mixer=graph.engine.mainMixerNode, rate=mixer.outputFormat(forBus:0).sampleRate
        graph.engine.pause()
        mixer.installTap(onBus:0,bufferSize:1024,format:nil) { buffer,_ in probe.append(buffer) }
        defer { audio.stop(); mixer.removeTap(onBus:0) }
        try audio.replay(events:[MusicEvent(midi:69,onset:0,duration:1920)],ticks:1920,bpm:120)
        let reference=try await probe.waitForNote(rate:rate)
        XCTAssertNotNil(reference)
        audio.stopClock()
        let stoppedTick=audio.tick
        probe.reset()
        try audio.startOutput()
        let deadline=ProcessInfo.processInfo.systemUptime+2
        let quietFrames=Int(rate*0.03)
        while ProcessInfo.processInfo.systemUptime<deadline {
            let baseline=probe.snapshot()
            if baseline.count>=quietFrames && PianoTimbreProbe.rms(Array(baseline.suffix(quietFrames)))<0.0001 { break }
            try await Task.sleep(for:.milliseconds(5))
        }
        XCTAssertGreaterThanOrEqual(probe.snapshot().count,Int(rate*0.03),"Live-key output must actually render")
        XCTAssertLessThan(PianoTimbreProbe.rms(Array(probe.snapshot().suffix(quietFrames))),0.0001)
        audio.noteOn(69)
        let captured=try await probe.waitForNote(rate:rate)
        let live=try XCTUnwrap(captured,"Live keys must remain audible after stopping reference playback")
        XCTAssertGreaterThan(PianoTimbreProbe.rms(live),0.0001)
        XCTAssertGreaterThan(PianoTimbreProbe.harmonicFraction(live,rate:rate),0.005)
        XCTAssertLessThanOrEqual(abs(audio.tick-stoppedTick),1,"Live input must not restart the reference timeline")
        audio.noteOff(69)
    }

    func testPausedOutputDoesNotDiscardThePreparedPianoOrSequence() async throws {
        let graph=PianoAudioGraph(), player=PracticeReviewPlayback(graph:graph), probe=PianoTimbreProbe()
        let music=score()
        try await player.play(score:music,bpm:80,voice:"grand-piano")
        player.stop()
        let engine=graph.engine, sampler=graph.piano
        // Paused I/O retains prepared resources. It is not a missing instrument
        // and must not enter the bank-reload path when tempo changes next.
        engine.pause()
        let rate=sampler.outputFormat(forBus:0).sampleRate
        sampler.installTap(onBus:0,bufferSize:1024,format:nil) { buffer,_ in probe.append(buffer) }
        defer { player.shutdown(); sampler.removeTap(onBus:0) }
        try await player.play(score:music,bpm:132,voice:"grand-piano")
        XCTAssertTrue(graph.engine === engine && graph.piano === sampler)
        XCTAssertEqual(player.instrumentLoadCount,1)
        XCTAssertEqual(player.sequenceCreationCount,1)
        let captured=try await probe.waitForNote(rate:rate)
        let rendered=try XCTUnwrap(captured,"Resuming prepared I/O must produce a complete new piano note")
        XCTAssertGreaterThan(PianoTimbreProbe.rms(rendered),0.0001)
        XCTAssertGreaterThan(PianoTimbreProbe.harmonicFraction(rendered,rate:rate),0.005)
    }

    func testConfigurationInvalidationDefersDisposalAndRebuildsExactlyOnce() async throws {
        let graph=PianoAudioGraph(), player=PracticeReviewPlayback(graph:graph)
        defer { player.shutdown() }
        let music=score()
        try await player.play(score:music,bpm:80,voice:"grand-piano")
        let engine=graph.engine
        engine.pause()
        player.configurationChanged(Notification(name:.AVAudioEngineConfigurationChange,object:engine))
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(graph.engine === engine,"Notification delivery must not deallocate the reporting engine")
        XCTAssertEqual(player.instrumentLoadCount,1)
        try await player.play(score:music,bpm:80,voice:"grand-piano")
        XCTAssertFalse(graph.engine === engine)
        XCTAssertEqual(player.instrumentLoadCount,2)
        XCTAssertEqual(player.sequenceCreationCount,2)
        player.stop()
        try await player.play(score:music,bpm:120,voice:"grand-piano")
        XCTAssertEqual(player.instrumentLoadCount,2,"Ordinary replay must not repeat recovery")
    }
}
