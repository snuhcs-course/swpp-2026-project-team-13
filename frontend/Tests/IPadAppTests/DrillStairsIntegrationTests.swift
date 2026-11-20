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

    func testSolvedStagesAreSavedAtOnceButShownWhenTheGameCloses() throws {
        let stairs = DrillStairsModel(connection:nil,root:root)
        XCTAssertNil(stairs.error)
        let first = try XCTUnwrap(DrillStairs.stage(1)), far = try XCTUnwrap(DrillStairs.stage(17))
        XCTAssertEqual(stairs.state(first),.next); XCTAssertEqual(stairs.state(far),.open)
        XCTAssertTrue(stairs.canStart(far),"Any key starts, not only the lowest one")
        stairs.clear(17)
        XCTAssertEqual(stairs.state(far),.open,"The stairs behind the game do not change yet")
        XCTAssertEqual(stairs.reveal(),[17]); XCTAssertEqual(stairs.state(far),.done)
        XCTAssertEqual(stairs.shown.next,1); XCTAssertTrue(stairs.shown.blackKeyPressed(above:17))
        XCTAssertEqual(stairs.reveal(),[])
        stairs.clear(17); stairs.clear(99)
        XCTAssertEqual(stairs.reveal(),[],"Replaying a solved key changes nothing")
        stairs.clear(1); XCTAssertEqual(stairs.reveal(),[1]); XCTAssertEqual(stairs.shown.next,2)
        let reopened = DrillStairsModel(connection:nil,root:root)
        XCTAssertEqual(reopened.shown.cleared,[1,17])
    }
    func testRhythmStagesNeedTheServer() throws {
        let stairs = DrillStairsModel(connection:nil,root:root)
        let rhythm = try XCTUnwrap(DrillStairs.stage(3)); XCTAssertEqual(rhythm.game,.rhythmPuzzle)
        XCTAssertTrue(stairs.needsConnection(rhythm)); XCTAssertFalse(stairs.canStart(rhythm))
        XCTAssertFalse(stairs.needsConnection(try XCTUnwrap(DrillStairs.stage(2))))
    }
    func testUnreadableClimbIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let file = root.appendingPathComponent("drill-stairs-v1.json")
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
