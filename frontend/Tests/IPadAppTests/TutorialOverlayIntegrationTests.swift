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
