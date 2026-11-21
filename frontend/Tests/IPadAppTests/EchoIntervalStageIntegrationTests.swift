import XCTest
import SwiftUI
@testable import IPadApp

@MainActor final class EchoIntervalStageIntegrationTests: XCTestCase {
    private func intervalSettled(_ game: EchoIntervalStageModel) async throws {
        let deadline=ProcessInfo.processInfo.systemUptime+10
        while game.phase.busy && ProcessInfo.processInfo.systemUptime<deadline { try await Task.sleep(for:.milliseconds(2)) }
        XCTAssertFalse(game.phase.busy); XCTAssertNil(game.error)
    }
    private func enter(_ notes: [Int], into game: EchoIntervalStageModel) {
        for note in notes { game.keyDown(note); game.keyUp(note) }
    }
    func testIntervalReplyIsReplayedBeforeReactionAndDuplicateSubmitIsIgnored() async throws {
        let audio=IntervalTestPiano()
        let game=EchoIntervalStageModel(stage:EchoIntervalStage(1),audio:audio,noteDuration:.milliseconds(1),gapDuration:.milliseconds(1))
        defer { game.suspend() }
        game.listen(); try await intervalSettled(game)
        XCTAssertEqual(audio.notes,game.run.question.call)
        XCTAssertTrue(game.inputs.isEmpty,"The given first note is not auto-entered")
        let answer=game.run.question.answer
        game.keyDown(answer[0]); game.keyUp(answer[0]); game.submit()
        XCTAssertEqual(game.inputs,[answer[0]]); XCTAssertEqual(game.phase,.waiting)
        game.keyDown(answer[1]); game.keyUp(answer[1]); audio.notes=[]
        audio.onNote = { [weak game] in
            XCTAssertEqual(game?.phase,.answerPlayback)
            XCTAssertEqual(game?.run.hearts,3)
            XCTAssertEqual(game?.run.solved.first,false,"A reaction cannot appear while either answer note is sounding")
        }
        game.submit(); game.submit()
        XCTAssertEqual(game.phase,.answerPlayback); XCTAssertFalse(game.canSubmit)
        try await intervalSettled(game)
        XCTAssertEqual(audio.notes,answer,"Exactly the two pressed pitches must be replayed, once")
        XCTAssertEqual(game.phase,.happy); XCTAssertEqual(game.run.hearts,3)
        XCTAssertTrue(game.run.solved[0])
    }
    func testCancelledAnswerPlaybackNeverConsumesAHeartOrGradesAndCanRecover() async throws {
        let audio=IntervalTestPiano()
        let game=EchoIntervalStageModel(stage:EchoIntervalStage(4),audio:audio,noteDuration:.milliseconds(1),gapDuration:.milliseconds(1))
        defer { game.suspend() }
        game.listen(); try await intervalSettled(game)
        let answer=game.run.question.answer; enter(answer,into:game)
        audio.onNote = { [weak game] in if game?.phase == .answerPlayback { game?.suspend() } }
        game.submit(); try await intervalSettled(game)
        XCTAssertEqual(game.phase,.idle); XCTAssertEqual(game.run.hearts,3); XCTAssertFalse(game.run.solved[0])
        audio.onNote=nil; game.resume(); try await intervalSettled(game)
        XCTAssertEqual(game.inputs,answer); game.submit(); try await intervalSettled(game)
        XCTAssertEqual(game.phase,.happy)
    }
    func testWrongStartIsOnlyACueAndThirdWrongIntervalEndsStage() async throws {
        let audio=IntervalTestPiano()
        let game=EchoIntervalStageModel(stage:EchoIntervalStage(1),audio:audio,noteDuration:.milliseconds(1),gapDuration:.milliseconds(1))
        defer { game.suspend() }
        game.listen(); try await intervalSettled(game)
        let q=game.run.question
        let alternate=q.keyboardRange.first { $0 != q.replyStart && $0 != q.answer[1] }!
        game.keyDown(alternate); game.keyUp(alternate)
        XCTAssertTrue(game.startReminder); XCTAssertTrue(game.inputs.isEmpty); XCTAssertEqual(game.run.hearts,3)
        for remaining in [2,1,0] {
            enter([q.replyStart,alternate],into:game); game.submit()
            XCTAssertEqual(game.phase,.answerPlayback)
            try await intervalSettled(game)
            XCTAssertEqual(game.run.hearts,remaining)
            XCTAssertEqual(game.phase,remaining == 0 ? .failed : .puzzled)
        }
        let oldNotes=audio.notes
        game.listen(); game.submit(); enter(q.answer,into:game)
        XCTAssertEqual(game.phase,.failed); XCTAssertEqual(audio.notes,oldNotes)
    }
    func testCompletingTenTurnsUsesOneStageLifePool() async throws {
        let audio=IntervalTestPiano()
        let game=EchoIntervalStageModel(stage:EchoIntervalStage(10),audio:audio,noteDuration:.milliseconds(1),gapDuration:.milliseconds(1))
        defer { game.suspend() }
        game.listen(); try await intervalSettled(game)
        for index in 0..<10 {
            XCTAssertEqual(game.run.index,index)
            enter(game.run.question.answer,into:game); game.submit(); try await intervalSettled(game)
            if index<9 { XCTAssertEqual(game.phase,.happy); game.next(); try await intervalSettled(game) }
        }
        XCTAssertEqual(game.phase,.completed); XCTAssertEqual(game.run.hearts,3)
        game.next(); XCTAssertEqual(game.run.index,9)
    }
    func testEveryEchoStairIsAvailableWithoutFetchingAScoreBank() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("echo-course-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let stairs=DrillStairsModel(connection:nil,root:root)
        XCTAssertNil(stairs.course)
        for stage in DrillStairs.stages where stage.game == .echoDragon { XCTAssertTrue(stairs.canStart(stage)) }
        XCTAssertFalse(stairs.canStart(try XCTUnwrap(DrillStairs.stage(2))))
    }
    func testApricotSpritesAndIntervalGameRenderAtLandscapeIPadSizes() async throws {
        for name in ["waiting","singing","puzzled","happy"] { XCTAssertNotNil(UIImage(named:"echo-dragon-"+name)) }
        let key="echo-interval-tutorial-v1", old=UserDefaults.standard.object(forKey:"echo-interval-tutorial-v1")
        UserDefaults.standard.set(true,forKey:key)
        defer { if let old { UserDefaults.standard.set(old,forKey:key) } else { UserDefaults.standard.removeObject(forKey:key) } }
        for size in [CGSize(width:1133,height:744),CGSize(width:1180,height:820)] {
            let model=EchoIntervalStageModel(stage:EchoIntervalStage(4),audio:IntervalTestPiano(),noteDuration:.milliseconds(1),gapDuration:.milliseconds(1))
            let stage=try XCTUnwrap(DrillStairs.stage(10))
            let host=UIHostingController(rootView:EchoIntervalStageView(stage:stage,model:model,mastered:{},exit:{}))
            let window=UIWindow(frame:CGRect(origin:.zero,size:size))
            window.rootViewController=host; window.makeKeyAndVisible()
            try await Task.sleep(for:.milliseconds(120)); host.view.layoutIfNeeded()
            let image=UIGraphicsImageRenderer(bounds:host.view.bounds).image { _ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true) }
            let attachment=XCTAttachment(image:image); attachment.name="echo-apricot-\(Int(size.width))"; attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden=true; model.suspend()
        }
    }
}

@MainActor private final class IntervalTestPiano: EchoIntervalPlaying {
    var notes: [Int] = []
    var onNote: (() -> Void)?
    func prepare() throws { }
    func noteOn(_ midi: Int) { notes.append(midi); onNote?() }
    func noteOff(_ midi: Int) { }
    func silence() { }
    func stop() { }
}
