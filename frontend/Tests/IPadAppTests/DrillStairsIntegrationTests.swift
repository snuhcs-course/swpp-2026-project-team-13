import XCTest
@testable import IPadApp

@MainActor final class DrillStairsIntegrationTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("drill-stairs-"+UUID().uuidString,isDirectory:true)
        suite = "drill-stairs-tests-"+UUID().uuidString
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at:root)
        UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite)
    }

    func testSolvedStagesAreSavedAtOnceButShownWhenTheGameCloses() async throws {
        let stairs = DrillStairsModel(connection:nil,root:root)
        XCTAssertNil(stairs.error)
        await stairs.prepareCourse()
        let first = try XCTUnwrap(DrillStairs.stage(1)), far = try XCTUnwrap(DrillStairs.stage(4))
        XCTAssertEqual(stairs.state(first),.next); XCTAssertEqual(stairs.state(far),.open)
        XCTAssertTrue(stairs.canStart(far),"Any key starts, not only the lowest one")
        stairs.clear(4)
        XCTAssertEqual(stairs.state(far),.open,"The stairs behind the game do not change yet")
        XCTAssertEqual(stairs.reveal(),[4]); XCTAssertEqual(stairs.state(far),.done)
        XCTAssertEqual(stairs.shown.next,1); XCTAssertTrue(stairs.shown.blackKeyPressed(above:4))
        XCTAssertEqual(stairs.reveal(),[])
        stairs.clear(4); stairs.clear(99)
        XCTAssertEqual(stairs.reveal(),[],"Replaying a solved key changes nothing")
        stairs.clear(1); XCTAssertEqual(stairs.reveal(),[1]); XCTAssertEqual(stairs.shown.next,2)
        let reopened = DrillStairsModel(connection:nil,root:root)
        XCTAssertEqual(reopened.shown.cleared,[1,4])
    }
    func testRhythmStagesNeedTheServer() throws {
        let stairs = DrillStairsModel(connection:nil,root:root)
        let rhythm = try XCTUnwrap(DrillStairs.stage(3)); XCTAssertEqual(rhythm.game,.rhythmPuzzle)
        XCTAssertTrue(stairs.needsConnection(rhythm)); XCTAssertFalse(stairs.canStart(rhythm))
        XCTAssertFalse(stairs.needsConnection(try XCTUnwrap(DrillStairs.stage(2))))
    }
    func testUnfinishedStageIsDiscardedAndOnlyCompletedSetIsSaved() throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let course: DrillStageCourse = try DemoContent.decode("drill-stage-sets-v1")
        let set=try XCTUnwrap(course.stages.first { $0.game == .memoryRun })
        let game=DrillStageSession(set:set,version:course.version,root:root)
        game.report(DrillRoundResult(accuracy:50,revealed:false,elapsedMs:0))
        let resumed=DrillStageSession(set:set,version:course.version,root:root)
        XCTAssertNil(resumed.error);XCTAssertEqual(resumed.attempt.index,0)
        XCTAssertTrue(resumed.attempt.results.allSatisfy { $0 == nil })
        resumed.report(DrillRoundResult(accuracy:50,revealed:false,elapsedMs:0));resumed.next()
        for _ in 1..<set.questions.count {
            resumed.report(DrillRoundResult(accuracy:100,revealed:false,elapsedMs:0)); resumed.next()
        }
        XCTAssertTrue(resumed.summary);XCTAssertTrue(resumed.attempt.complete);XCTAssertFalse(resumed.attempt.mastered)
        let finished=DrillStageSession(set:set,version:course.version,root:root)
        XCTAssertTrue(finished.summary); XCTAssertFalse(finished.attempt.mastered)
        resumed.restart();XCTAssertEqual(resumed.attempt.index,0);XCTAssertTrue(resumed.attempt.results.allSatisfy { $0 == nil })
    }
    func testMemoryStageStartsThePinnedExcerptAndTempoInsteadOfRandomSampling() throws {
        let course: DrillStageCourse = try DemoContent.decode("drill-stage-sets-v1")
        let q=try XCTUnwrap(course.stages.first { $0.game == .memoryRun }?.questions.first)
        let api=try DemoExamAPI(outcome:"completed",storageScope:UUID().uuidString)
        let connection=RhythmConnection(api:api,profileId:UUID(),demo:true,generation:UUID())
        let game=MelodyRunModel(connection:connection);defer { game.stop() }
        game.newStageRound(q)
        XCTAssertNil(game.error);XCTAssertEqual(game.excerpt?.id,q.catalogId);XCTAssertEqual(game.excerpt?.bars,2)
        game.stop();game.newStageRound(q)
        XCTAssertEqual(game.excerpt?.id,q.catalogId)
    }
    func testRhythmStageDoesNotPersistPartialPlayBeforeStageCommit() throws {
        let course: DrillStageCourse = try DemoContent.decode("drill-stage-sets-v1")
        let q=try XCTUnwrap(course.stages.first { $0.game == .rhythmPuzzle }?.questions.first)
        let api=try DemoExamAPI(outcome:"completed",storageScope:UUID().uuidString)
        let connection=RhythmConnection(api:api,profileId:UUID(),demo:true,generation:UUID())
        let folder=try LocalStore(scope:connection.scope).root
        defer { try? FileManager.default.removeItem(at:folder) }
        let game=RhythmPuzzleModel(connection:connection,stageMode:true)
        defer { game.close() }
        let store=try RhythmPuzzleStore(root:folder)
        game.newStageRound(q); game.revealAndSkip(); game.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.file.path))
        try game.commitStage()
        let saved=try store.load()
        XCTAssertNil(saved.draft); XCTAssertEqual(saved.records.count,1)
    }
    func testEchoRequiresBothLiteralNotesAndDoesNotAutoFillTheGivenStart() async throws {
        let course: DrillStageCourse = try DemoContent.decode("drill-stage-sets-v1")
        let q=try XCTUnwrap(course.stages.first { $0.game == .echoDragon }?.questions.first)
        let audio=MelodyRunAudio();defer { audio.stop() }
        let game=EchoFollowModel(question:q,audio:audio);defer { game.stop() }
        XCTAssertTrue(game.inputs.isEmpty)
        game.listen()
        let deadline=ProcessInfo.processInfo.systemUptime+15
        while game.playing && ProcessInfo.processInfo.systemUptime<deadline { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertNil(game.error);XCTAssertTrue(game.heard)
        let notes=try XCTUnwrap(q.notes)
        game.keyDown(notes[0]);game.keyUp(notes[0]);game.submit()
        XCTAssertNil(game.result,"One note is never a complete answer, even when the first note is given")
        game.keyDown(notes[1]);game.keyUp(notes[1]);game.submit()
        XCTAssertEqual(game.inputs,notes);XCTAssertEqual(game.result?.accuracy,100)
    }
    func testUnreadableClimbIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let file = root.appendingPathComponent("drill-stage-set-progress-v1.json")
        try Data("broken".utf8).write(to:file)
        let stairs = DrillStairsModel(connection:nil,root:root)
        XCTAssertNotNil(stairs.error)
        stairs.clear(1)
        XCTAssertEqual(try Data(contentsOf:file),Data("broken".utf8))
    }
    func testEchoStageOpensItsLevelWithoutTouchingTheLevelMap() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        let game = EchoDragonModel(defaults:defaults,audio:QuietDragon())
        XCTAssertEqual(game.progress.unlocked,1)
        game.open(19); XCTAssertNil(game.challenge,"The level map still locks later levels")
        game.open(19,stage:true)
        let challenge = try XCTUnwrap(game.challenge)
        XCTAssertEqual(challenge.level.number,19); XCTAssertTrue(game.staged); XCTAssertFalse(game.preview)
        game.listen()
        for _ in 0..<400 where game.isPlaying { try await Task.sleep(for:.milliseconds(5)) }
        game.select(challenge.answer)
        for _ in 0..<400 where game.isPlaying { try await Task.sleep(for:.milliseconds(5)) }
        game.submit()
        XCTAssertEqual(game.result,.correct)
        XCTAssertEqual(game.progress.unlocked,1); XCTAssertNil(defaults.data(forKey:EchoDragonModel.storageKey))
        game.next(); XCTAssertEqual(game.challenge?.level.number,19,"The stairs, not the level map, decide what comes next")
    }
}

@MainActor private final class QuietDragon: EchoDragonPlaying {
    func prepare() throws { }
    func note(_ midi: Int) async throws { try Task.checkCancellation() }
    func pair(_ first: Int, _ second: Int) async throws { try Task.checkCancellation() }
    func silence() { }
    func stop() { }
    func needsRecovery(_ notification: Notification) -> Bool { false }
}
