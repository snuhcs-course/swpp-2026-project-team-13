import XCTest
import SwiftUI
@testable import IPadApp

@MainActor final class MelodyRunIntegrationTests: XCTestCase {
    private func makeGame(mode: MelodyMode, early: Bool = false) -> MelodyRunModel {
        let game = MelodyRunModel()
        game.selection = "Batchellor-Charmbury-1884a_1-1-018"
        game.settings.mode = mode; game.settings.bars = 2; game.settings.bpm = 180
        game.settings.gapBeats = 0; game.settings.inputBars = 1; game.settings.advanceEarly = early
        return game
    }
    private func waitUntil(_ predicate: ()->Bool, seconds: Double = 15) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime+seconds
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(predicate(),"Game did not reach the expected audio-clock phase")
    }
    func testMemoryAndBothGroovePoliciesCompleteWithPerfectResults() async throws {
        for (mode,early) in [(MelodyMode.memory,false),(.groove,false),(.groove,true)] {
            let game = makeGame(mode:mode,early:early)
            await game.start(); XCTAssertNil(game.error)
            let round = try XCTUnwrap(game.round)
            let deadline = ProcessInfo.processInfo.systemUptime+15
            while game.page == .playing, ProcessInfo.processInfo.systemUptime < deadline {
                if game.canEnter, let answers = game.answers, let target = answers.next(in:game.measure) {
                    let pitch = round.targets[target].midi
                    game.keyDown(pitch); game.keyUp(pitch)
                }
                if mode == .memory, game.allEntered { game.finish() }
                try await Task.sleep(for:.milliseconds(25))
            }
            XCTAssertEqual(game.page,.result); XCTAssertNil(game.error)
            XCTAssertEqual(game.answers?.result.accuracy,100)
            game.replay(user:false); XCTAssertNotNil(game.replaying)
            game.replay(user:true); XCTAssertEqual(game.replaying,"내 연주")
            game.stopReplay(); XCTAssertNil(game.replaying)
            game.stop()
        }
    }
    func testPauseDuringRecallPreservesInputAndAllowsUndoAfterResuming() async throws {
        let game = makeGame(mode:.memory)
        defer { game.stop() }
        await game.start(); XCTAssertNil(game.error)
        try await waitUntil({game.canEnter})
        let pitch = try XCTUnwrap(game.round?.targets.first?.midi)
        game.keyDown(pitch); game.keyUp(pitch)
        let before = game.answers?.pitches
        game.pause(); XCTAssertTrue(game.paused)
        game.keyDown(99); XCTAssertEqual(game.answers?.pitches,before)
        game.resume(); XCTAssertNil(game.error); XCTAssertFalse(game.paused)
        XCTAssertEqual(game.answers?.pitches,before)
        game.undo(); XCTAssertNil(game.answers?.pitches.first ?? nil)
    }
    func testMiniGameDoesNotReplacePreparedExamAttempt() async throws {
        let exam = AppModel(); exam.demo = true
        await exam.connect(); await exam.choose(try XCTUnwrap(exam.questions.first?.id)); await exam.begin()
        XCTAssertNil(exam.error)
        let id = try XCTUnwrap(exam.session?.id), score = exam.mainScore
        exam.navigate(.minigames)
        let game = makeGame(mode:.memory)
        await game.start(); XCTAssertNil(game.error); game.stop()
        XCTAssertEqual(exam.session?.id,id); XCTAssertEqual(exam.mainScore,score)
        exam.navigate(.exam); await exam.start(); exam.player.pause()
        XCTAssertNil(exam.error); XCTAssertEqual(exam.session?.attempt.status,"in_progress")
    }
    func testLandscapeKeyboardAndBothClefsRender() async throws {
        let game = makeGame(mode:.memory)
        await game.start(); XCTAssertNil(game.error)
        defer { game.stop() }
        let round = try XCTUnwrap(game.round), answers = try XCTUnwrap(game.answers)
        let score = round.display(measure:1,answers:answers.pitches)
        let renderer = ImageRenderer(content:VStack(spacing:16) {
            Text("멜로디 런 · 메모리").font(.title.bold())
            MelodyStaff(score:score.0,fifths:0,clef:"G",pending:score.1)
            MelodyStaff(score:score.0,fifths:-3,clef:"F",pending:score.1)
        }.padding(24).frame(width:1194).background(.white))
        let image = try XCTUnwrap(renderer.uiImage)
        let attachment = XCTAttachment(image:image); attachment.name = "melody-run-staff-landscape"; attachment.lifetime = .keepAlways; add(attachment)
        let keyboard = MelodyPianoKeyboard(frame:CGRect(x:0,y:0,width:1146,height:280))
        keyboard.configure(range:48...72,enabled:true,onDown:{_ in},onUp:{_ in})
        XCTAssertTrue(keyboard.isMultipleTouchEnabled)
        keyboard.layer.displayIfNeeded()
        let piano = UIGraphicsImageRenderer(size:keyboard.bounds.size).image { keyboard.layer.render(in:$0.cgContext) }
        let keys = XCTAttachment(image:piano); keys.name = "melody-run-multitouch-keyboard"; keys.lifetime = .keepAlways; add(keys)
    }
}
