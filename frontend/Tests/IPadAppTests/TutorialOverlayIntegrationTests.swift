import XCTest
import SwiftUI
@testable import IPadApp

@MainActor final class TutorialOverlayIntegrationTests: XCTestCase {
    func testEchoWaitsForStartAndHelpPreservesTheReplyAndHearts() async throws {
        let audio = TutorialQuietPiano()
        let game = EchoIntervalStageModel(stage: EchoIntervalStage(1), audio: audio,
                                          noteDuration: .milliseconds(1), gapDuration: .milliseconds(1))
        defer { game.suspend() }
        game.resume()
        XCTAssertFalse(game.hasStarted)
        XCTAssertTrue(audio.notes.isEmpty)
        game.suspendForTutorial(); game.finishTutorial(); game.resume()
        XCTAssertFalse(game.hasStarted)
        game.start()
        let deadline = ProcessInfo.processInfo.systemUptime+5
        while game.phase.busy && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(game.hasStarted); XCTAssertEqual(game.phase, .waiting)
        let first = game.run.question.replyStart
        game.keyDown(first); game.keyUp(first)
        game.suspendForTutorial()
        game.keyDown(game.run.question.answer[1])
        XCTAssertEqual(game.inputs, [first]); XCTAssertEqual(game.run.hearts, 3)
        game.finishTutorial(); game.resume()
        XCTAssertEqual(game.inputs, [first])
        XCTAssertTrue(game.canEnter)
    }
    func testMemoryPreparationAndGuideDoNotStartTheListeningClock() async throws {
        let course: DrillStageCourse = try DemoContent.decode("drill-stage-sets-v3")
        let question = try XCTUnwrap(course.stages.first(where: { $0.game == .memoryRun })?.questions.first)
        let game = MelodyRunModel(stageMode: true)
        defer { game.stop() }
        game.requireManualStart()
        game.newStageRound(question)
        let deadline = ProcessInfo.processInfo.systemUptime+15
        while (game.round == nil || game.working) && game.error == nil && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(game.error)
        XCTAssertNotNil(game.round)
        XCTAssertTrue(game.awaitingStart)
        XCTAssertFalse(game.canEnter)
        XCTAssertEqual(game.progress, 0)
        game.suspendForTutorial(); game.resume(); game.finishTutorial(); game.resume()
        XCTAssertTrue(game.awaitingStart)
        XCTAssertEqual(game.progress, 0)
        game.startPreparedRound()
        XCTAssertFalse(game.awaitingStart)
        XCTAssertEqual(game.phase, .countIn)
        XCTAssertNil(game.error)
    }
    func testRhythmPreparationForegroundAndGuideCannotRecordAListen() throws {
        let course: DrillStageCourse = try DemoContent.decode("drill-stage-sets-v3")
        let question = try XCTUnwrap(course.stages.first(where: { $0.game == .rhythmPuzzle })?.questions.first)
        let api = try DemoExamAPI(outcome: "completed", storageScope: UUID().uuidString)
        let connection = RhythmConnection(api: api, profileId: UUID(), demo: true, generation: UUID())
        let folder = try LocalStore(scope: connection.scope).root
        defer { try? FileManager.default.removeItem(at: folder) }
        let game = RhythmPuzzleModel(connection: connection, stageMode: true)
        defer { game.close() }
        game.requireManualStart(); game.newStageRound(question)
        XCTAssertNil(game.error); XCTAssertTrue(game.awaitingStart)
        game.activate(); game.listen()
        game.suspendForTutorial(); game.finishTutorial(); game.activate()
        XCTAssertEqual(game.draft?.record.listens.count, 0)
        XCTAssertEqual(game.draft?.record.activeMs, 0)
        XCTAssertEqual(game.draft?.record.interruptions, 0)
        XCTAssertFalse(game.canEdit); XCTAssertFalse(game.canSubmit)
        game.startPreparedRound()
        XCTAssertFalse(game.awaitingStart)
        XCTAssertEqual(game.draft?.record.listens.count, 1)
        XCTAssertTrue(game.playing)
        let answerBefore = game.board
        game.suspendForTutorial(); game.activate()
        XCTAssertFalse(game.canEdit)
        game.finishTutorial()
        XCTAssertTrue(game.tutorialPaused)
        XCTAssertEqual(game.board, answerBefore)
        game.continueAfterTutorial()
        XCTAssertTrue(game.canEdit)
    }
    func testMemoryTutorialEditsKeepOtherBarsAndSupportUndoAndEraser() throws {
        let session = MiniTutorialSession(kind: .memoryRun)
        session.showPage(4)
        let original = try XCTUnwrap(session.memory?.pitches)
        XCTAssertTrue(original.allSatisfy { $0 != nil })
        session.selectBar(1)
        XCTAssertTrue(session.enter(60))
        let replaced = try XCTUnwrap(session.memory?.pitches)
        XCTAssertEqual(Array(replaced.suffix(4)), Array(original.suffix(4)))
        XCTAssertEqual(replaced[0], 60)
        XCTAssertTrue(replaced[1...3].allSatisfy { $0 == nil })
        session.undo()
        XCTAssertEqual(session.memory?.pitches, original)
        session.eraseBar()
        let erased = try XCTUnwrap(session.memory?.pitches)
        XCTAssertTrue(erased.prefix(4).allSatisfy { $0 == nil })
        XCTAssertEqual(Array(erased.suffix(4)), Array(original.suffix(4)))
        session.undo()
        XCTAssertEqual(session.memory?.pitches, original)
        XCTAssertTrue(session.highlights.contains(.keyboard))
        XCTAssertTrue(session.highlights.contains(.erase))
        XCTAssertTrue(session.highlights.contains(.undo))
    }
    func testRhythmTutorialRequiresATapThenARealDropIntoTheDesignatedSlot() throws {
        let session = MiniTutorialSession(kind: .rhythmPuzzle)
        let round = try XCTUnwrap(TutorialSamples.rhythmRound)
        let tap = try XCTUnwrap(session.tapTile), drag = try XCTUnwrap(session.dragTile)
        session.showPage(3)
        XCTAssertFalse(session.canAdvance)
        XCTAssertFalse(session.dropTile(drag, at: round.pulse))
        XCTAssertTrue(session.board.placements.isEmpty)
        XCTAssertTrue(session.tapChoice(tap))
        XCTAssertTrue(session.didTap); XCTAssertFalse(session.canAdvance)
        XCTAssertFalse(session.tapChoice(drag), "A second tap is not a drag")
        XCTAssertFalse(session.dropTile(drag, at: round.pulse*2), "Wrong-slot drops do not complete the exercise")
        XCTAssertTrue(session.dropTile(drag, at: round.pulse))
        XCTAssertTrue(session.canAdvance)
        XCTAssertEqual(session.board.placements.map(\.start), [.zero, round.pulse])
        session.showPage(4)
        let first = try XCTUnwrap(session.board.placements.first)
        session.move(first, to: round.pulse*2)
        XCTAssertTrue(session.board.placements.contains { $0.start == round.pulse*2 })
        session.remove(try XCTUnwrap(session.board.placements.first))
        XCTAssertEqual(session.board.placements.count, 1)
    }
    func testRhythmTieGuideWaitsForTheButtonThenConnectsTheHighlightedNotes() throws {
        let session = MiniTutorialSession(kind: .rhythmPuzzle)
        session.showPage(5)
        let pair = session.board.placements
        XCTAssertEqual(pair.count, 2)
        XCTAssertFalse(session.canAdvance)
        XCTAssertFalse(session.connect(pair[0], pair[1]))
        session.enableTie()
        XCTAssertTrue(session.highlights.contains(.tieStart))
        XCTAssertTrue(session.highlights.contains(.tieEnd))
        XCTAssertFalse(session.connect(pair[0], pair[0]))
        XCTAssertTrue(session.connect(pair[0], pair[1]))
        XCTAssertEqual(session.board.ties, [try XCTUnwrap(TutorialSamples.rhythmRound).pulse])
        XCTAssertTrue(session.canAdvance)
    }
    func testLivePracticeAndExamGuidesFreezeTimeWithoutMovingTheSheet() async throws {
        for mode in [StudyMode.practice, .exam] {
            let model = AppModel(demoScope: "writing-tutorial-"+UUID().uuidString)
            model.demo = true
            await model.connect()
            if mode == .practice { await model.choose(try XCTUnwrap(model.questions.first?.id), mode: .practice) }
            else {
                await model.startRecommendedExam()
                await model.chooseExam(try XCTUnwrap(model.examOffer?.choices.first { $0.questionId != nil }))
            }
            await model.begin(); await model.start(); model.player.pause()
            XCTAssertNil(model.error)
            model.player.restore(PlaybackCursor(index: 1, phase: "gap", remainingWaitMs: 5000))
            model.player.resume()
            let host = UIHostingController(rootView: ExamView(model: model, drawing: model.drawing, player: model.player))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1133, height: 744))
            window.rootViewController = host; window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(150)); host.view.layoutIfNeeded()
            let before = model.drawing.canvas.convert(model.drawing.canvas.bounds, to: host.view)
            let strokes = model.drawing.canvas.drawing.dataRepresentation()
            model.openWritingTutorial(); host.view.layoutIfNeeded()
            let frozen = model.player.cursor
            XCTAssertTrue(model.writingTutorialOpen); XCTAssertFalse(model.player.isPlaying)
            XCTAssertFalse(model.drawing.canvas.isUserInteractionEnabled)
            model.player.resume(); model.player.jump(to: 3)
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertEqual(model.player.cursor, frozen)
            let during = model.drawing.canvas.convert(model.drawing.canvas.bounds, to: host.view)
            XCTAssertEqual(before.minX, during.minX, accuracy: 0.5)
            XCTAssertEqual(before.minY, during.minY, accuracy: 0.5)
            XCTAssertEqual(before.width, during.width, accuracy: 0.5)
            XCTAssertEqual(before.height, during.height, accuracy: 0.5)
            XCTAssertEqual(model.drawing.canvas.drawing.dataRepresentation(), strokes)
            let shot = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: shot); attachment.name = "tutorial-live-\(mode.rawValue)"
            attachment.lifetime = .keepAlways; add(attachment)
            model.closeWritingTutorial()
            XCTAssertTrue(model.player.isPlaying)
            XCTAssertTrue(model.drawing.canvas.isUserInteractionEnabled)
            try await Task.sleep(for: .milliseconds(100))
            model.player.pause()
            XCTAssertLessThan(model.player.cursor.remainingWaitMs ?? 5000, frozen.remainingWaitMs ?? 5000)
            model.openWritingTutorial(); model.closeWritingTutorial()
            XCTAssertFalse(model.player.isPlaying, "A pre-existing pause must be preserved")
            window.isHidden = true; model.player.pause()
        }
    }
}

@MainActor private final class TutorialQuietPiano: EchoIntervalPlaying {
    var notes: [Int] = []
    func prepare() throws {}
    func noteOn(_ midi: Int) { notes.append(midi) }
    func noteOff(_ midi: Int) {}
    func silence() {}
    func stop() {}
}

// Run this class in both full-content and slim-device test hosts.
@MainActor final class TutorialOfflineIntegrationTests: XCTestCase {
    func testExamplesAreSelfContainedAndHaveNoAttemptOrStageJournal() throws {
        let bank = try XCTUnwrap(TutorialSamples.rhythm)
        try bank.validate()
        let engraving = try XCTUnwrap(TutorialSamples.engraving)
        XCTAssertTrue(bank.tiles.allSatisfy { engraving.tiles[$0.id] != nil })
        let round = try XCTUnwrap(TutorialSamples.memory)
        XCTAssertEqual(round.score.measures, 2)
        XCTAssertEqual(round.targets.count, 8)
        XCTAssertEqual(round.source.fifths, 0)
    }
    func testEveryOverlayStepRendersOnLandscapeIPadsAndNarrowWindows() throws {
        for kind in TutorialKind.allCases {
            for page in 0...kind.steps.count {
                for size in [CGSize(width: 1133, height: 744), CGSize(width: 1024, height: 768), CGSize(width: 700, height: 744)] {
                    try autoreleasepool {
                        let view = TutorialWalkthrough(kind: kind, initialPage: page, done: {})
                            .frame(width: size.width, height: size.height)
                        let image = try XCTUnwrap(ImageRenderer(content: view).uiImage)
                        XCTAssertEqual(image.size, size)
                    }
                }
            }
        }
    }
    func testHostedSpotlightsHaveReviewableScreenshots() async throws {
        let pages: [(TutorialKind, Int)] = [(.echoDragon, 1), (.memoryRun, 3), (.rhythmPuzzle, 3), (.exam, 3)]
        for (kind, page) in pages {
            let size = CGSize(width: 1133, height: 744)
            let host = UIHostingController(rootView: TutorialWalkthrough(kind: kind, initialPage: page, done: {}))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = host; window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(150))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image)
            attachment.name = "tutorial-\(kind.rawValue)-step-\(page)"
            attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true
        }
    }
}
