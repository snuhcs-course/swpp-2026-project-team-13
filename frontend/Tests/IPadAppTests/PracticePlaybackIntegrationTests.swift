import XCTest
import SwiftUI
@testable import IPadApp

@MainActor final class PracticePlaybackIntegrationTests: XCTestCase {
    private func score(bars: Int = 8) -> MusicScore {
        MusicScore(tempo:80,measures:bars,events:(0..<(bars*4)).map {
            MusicEvent(midi:60+$0%8,onset:$0*480,duration:480)
        },symbols:[])
    }
    func testReviewCanSeekRapidlyAcrossTemposPauseResumeAndStop() async throws {
        let player = PracticeReviewPlayback(); defer { player.shutdown() }
        let music = score()
        for bpm in [60.0,144,84] {
            print("Review audio: prepare tempo \(bpm)")
            try await player.play(score:music,range:PracticeReviewRange(from:3,through:4),bpm:bpm,voice:"grand-piano")
            XCTAssertEqual(player.instrumentLoadCount,1,"Tempo changes must reuse the loaded sampler")
            XCTAssertEqual(player.sequenceCreationCount,1,"Tempo changes must not detach and replace a rendering sequence")
            let began = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for:.milliseconds(350))
            XCTAssertEqual(player.positionSeconds+0.12,ProcessInfo.processInfo.systemUptime-began,accuracy:0.15,"Tempo changes must not accelerate the next playback")
            player.pause(); XCTAssertFalse(player.isPlaying); XCTAssertTrue(player.isPaused)
            let saved = player.positionSeconds
            try await Task.sleep(for:.milliseconds(150))
            XCTAssertEqual(player.positionSeconds,saved,accuracy:0.025)
            try await player.resume()
            try await Task.sleep(for:.milliseconds(150))
            XCTAssertGreaterThan(player.positionSeconds,saved+0.06)
        }
        for _ in 0..<3 {
            for bar in [1,8,2,7,3,6,4,5] {
                print("Review audio: seek measure \(bar)")
                try await player.play(score:music,range:PracticeReviewRange(from:bar,through:bar),bpm:84,voice:"grand-piano")
                XCTAssertEqual(player.measure,bar)
            }
        }
        let old = Task { try await player.play(score:music,range:PracticeReviewRange(from:1,through:2),bpm:84,voice:"grand-piano") }
        // Task.yield() does not promise that the older request has started.
        // Establish request order before verifying that its late return is harmless.
        let startDeadline = ProcessInfo.processInfo.systemUptime+2
        while player.range != PracticeReviewRange(from:1,through:2), ProcessInfo.processInfo.systemUptime < startDeadline {
            try await Task.sleep(for:.milliseconds(1))
        }
        XCTAssertEqual(player.range,PracticeReviewRange(from:1,through:2))
        try await player.play(score:music,range:PracticeReviewRange(from:7,through:8),bpm:84,voice:"grand-piano")
        _ = await old.result
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertTrue(player.isPlaying); XCTAssertEqual(player.range,PracticeReviewRange(from:7,through:8))
        player.stop(); XCTAssertFalse(player.isPlaying); XCTAssertFalse(player.isPaused)
        XCTAssertEqual(player.positionSeconds,0,accuracy:0.025)
        XCTAssertEqual(player.range,PracticeReviewRange(from:7,through:8))
        print("Review audio: change tempo after stop")
        try await player.play(score:music,range:PracticeReviewRange(from:8,through:8),bpm:200,voice:"grand-piano")
        XCTAssertEqual(player.instrumentLoadCount,1,"Stopping and changing tempo must not reload the bank")
        XCTAssertEqual(player.sequenceCreationCount,1,"Rapid seeks and stop/replay must keep the same sequence")
        let deadline = ProcessInfo.processInfo.systemUptime+3
        while player.isPlaying && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertFalse(player.isPlaying,"Playback must stop at the chosen end, not continue through the prepared sequence")
    }
    func testPracticePauseIsImmediateAndFreezesTheWritingCountdown() async throws {
        let player = PianoPlayback(); defer { player.invalidateAudio() }
        try player.prepare(main:score(),scale:score(bars:1),plan:.exam(meter:TimeSignature(numerator:4,denominator:4),scaleMeasures:1))
        player.restore(PlaybackCursor(index:3,phase:"gap",remainingWaitMs:20000))
        player.resume(); XCTAssertTrue(player.isPlaying)
        try await Task.sleep(for:.milliseconds(150))
        player.pause(); XCTAssertFalse(player.isPlaying)
        let left = try XCTUnwrap(player.cursor.remainingWaitMs)
        try await Task.sleep(for:.milliseconds(150))
        XCTAssertEqual(player.cursor.remainingWaitMs,left)
        for _ in 0..<10 {
            player.resume(); XCTAssertTrue(player.isPlaying)
            player.pause(); XCTAssertFalse(player.isPlaying)
        }
        player.jump(to:0)
        XCTAssertEqual(player.cursor.index,0); XCTAssertTrue(player.isPlaying)
    }
    func testTimerProgressAndMarkedReviewRenderAcrossIPadSizes() async throws {
        let api = try DemoExamAPI(outcome:"completed",storageScope:UUID().uuidString,smallContent:true)
        defer { try? api.store.removeAll() }
        let list = try await api.questions(page:1)
        let q = try await api.question(try XCTUnwrap(list.results.first?.id))
        let reference = try XCTUnwrap(q.correctScore)
        let referenceData = try await api.asset(reference.url,authenticated:true,limit:2_097_152)
        let paper = try await api.asset(q.sheetLayout.templatePngUrl,authenticated:false,limit:10_485_760)
        var attempt: Attempt = try Bundled.decode("attempt-submitted")
        attempt.mode = "practice"; attempt.question = q
        var record = SessionRecord(attempt:attempt)
        record.practiceEdits = [MeasureError(measure:1,types:["pitch","rhythm","other"]),MeasureError(measure:8,types:["rhythm"])]
        let model = AppModel(demoScope:UUID().uuidString); model.demo = true
        model.session = record; model.screen = .result
        model.submittedImage = try XCTUnwrap(UIImage(data:paper))
        model.correctScoreImage = try XCTUnwrap(UIImage(data:referenceData)); model.mainScore = score()
        for (width,height) in [(744.0,600.0),(1024.0,768.0),(1194.0,834.0)] {
            let renderer = ImageRenderer(content:PracticeResultView(model:model).frame(width:width,height:height))
            renderer.scale = 1
            let attachment = XCTAttachment(image:try XCTUnwrap(renderer.uiImage))
            attachment.name = "practice-review-controls-\(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
            let header = ImageRenderer(content:HStack {
                SegmentProgressBar(cursor:PlaybackCursor(index:3,phase:"gap",shortenedGap:true))
                WritingTimer(cursor:PlaybackCursor(index:3,phase:"gap",remainingWaitMs:4000),plan:nil)
            }.frame(width:width-56,height:80).padding().background(.white))
            header.scale = 1
            let timer = XCTAttachment(image:try XCTUnwrap(header.uiImage))
            timer.name = "practice-progress-timer-\(Int(width))"; timer.lifetime = .keepAlways; add(timer)
        }
    }
}
