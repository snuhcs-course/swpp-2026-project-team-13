import XCTest
import AVFoundation
@testable import IPadApp

@MainActor final class AudioLifecycleIntegrationTests: XCTestCase {
    private func score() -> MusicScore {
        MusicScore(tempo:80,measures:8,events:(0..<32).map {
            MusicEvent(midi:69,onset:$0*480,duration:480)
        },symbols:[])
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
