import XCTest
@testable import SolfegeCore

final class DrillStairsTests: XCTestCase {
    func testStagesMatchTheE2Stairs() {
        let stages = DrillStairs.stages
        XCTAssertEqual(stages.count,30)
        XCTAssertEqual(stages.first?.name,"C1"); XCTAssertEqual(stages[7].name,"C2"); XCTAssertEqual(stages.last?.name,"D5")
        // Game per key, read bottom to top from the Figma frame.
        let figma = "EMRERMMER" + "EMRERMMER" + "EMRERMMER" + "EMR"
        let codes = stages.map { $0.game == .echoDragon ? "E" : $0.game == .memoryRun ? "M" : "R" }.joined()
        XCTAssertEqual(codes,figma)
        XCTAssertEqual(stages[11].name,"G2"); XCTAssertEqual(stages[11].game,.rhythmPuzzle)
        XCTAssertEqual(stages[12].name,"A2"); XCTAssertEqual(stages[12].game,.echoDragon)
        XCTAssertEqual(stages[10].name,"F2"); XCTAssertEqual(stages[10].game,.memoryRun)
    }
    func testEchoStagesOpenEachNewSoundInOrder() {
        let echo = DrillStairs.stages.filter { $0.game == .echoDragon }
        XCTAssertEqual(echo.map(\.number),[1,4,8,10,13,17,19,22,26,28])
        XCTAssertEqual(echo.compactMap(\.echoLevel),DrillStairs.echoLevels)
        XCTAssertTrue(DrillStairs.stages.filter { $0.game != .echoDragon }.allSatisfy { $0.echoLevel == nil })
        for level in DrillStairs.echoLevels where level != 25 {
            XCTAssertNotNil(EchoDragonLevel(number:level).introducedInterval,"Echo stage \(level) introduces a new interval")
        }
        XCTAssertEqual(EchoDragonLevel(number:25).rule,.mirror)
    }
    func testDifficultyRisesEveryTenStages() {
        XCTAssertEqual(DrillStairs.stage(1)?.difficulty,.beginner); XCTAssertEqual(DrillStairs.stage(10)?.difficulty,.beginner)
        XCTAssertEqual(DrillStairs.stage(11)?.difficulty,.intermediate); XCTAssertEqual(DrillStairs.stage(20)?.difficulty,.intermediate)
        XCTAssertEqual(DrillStairs.stage(21)?.difficulty,.advanced); XCTAssertEqual(DrillStairs.stage(30)?.difficulty,.advanced)
        XCTAssertNil(DrillStairs.stage(0)); XCTAssertNil(DrillStairs.stage(31))
    }
    func testWaveAndBlackKeysFollowTheDesignRules() {
        XCTAssertEqual(DrillStairs.designX.count,DrillStairs.count)
        for n in 1...DrillStairs.count { XCTAssertLessThanOrEqual(abs(DrillStairs.designX[n-1]-DrillStairs.wave(n)),25,"key \(n)") }
        let black = (1..<DrillStairs.count).filter(DrillStairs.hasBlackKey(above:))
        XCTAssertEqual(black.count,21)
        XCTAssertFalse(DrillStairs.hasBlackKey(above:3)); XCTAssertFalse(DrillStairs.hasBlackKey(above:7)); XCTAssertFalse(DrillStairs.hasBlackKey(above:30))
        XCTAssertEqual(DrillStairs.blackKeyName(above:1),"C#1"); XCTAssertEqual(DrillStairs.blackKeyName(above:29),"C#5")
        // At the design width every key and black key lands exactly where the Figma frame has it.
        XCTAssertEqual(DrillStairs.spread(width:1180),1)
        for n in 1...DrillStairs.count { XCTAssertEqual(DrillStairs.keyLeft(n,width:1180),DrillStairs.designX[n-1],accuracy:0.001) }
        // C#1 starts 24pt inside D1, the more right-hand of C1/D1 (Figma x = 439).
        XCTAssertEqual(DrillStairs.blackKeyLeft(above:1,width:1180),439,accuracy:0.001)
        XCTAssertEqual(DrillStairs.blackKeyLeft(above:4,width:1180),529,accuracy:0.001)
    }
    func testNarrowScreensSqueezeTheWaveButKeepEveryKeyOnScreen() {
        // Portrait iPad mini (744), portrait 11" (834), landscape mini (1133), landscape 13" (1376).
        for width in [744.0,820,834,1133,1376] {
            for n in 1...DrillStairs.count {
                let left = DrillStairs.keyLeft(n,width:width)
                XCTAssertGreaterThanOrEqual(left,DrillStairs.sideMargin-0.001,"key \(n) at \(width)")
                XCTAssertLessThanOrEqual(left+DrillStairs.keySize.width,width-DrillStairs.sideMargin+0.001,"key \(n) at \(width)")
            }
        }
        XCTAssertLessThan(DrillStairs.spread(width:744),1); XCTAssertGreaterThan(DrillStairs.spread(width:744),0.8)
        XCTAssertEqual(DrillStairs.spread(width:1376),1,"Wide screens keep the design wave, not a wider one")
    }
    func testAnyStageCanBeSolvedInAnyOrderAndStaysPressed() throws {
        var progress = DrillStairsProgress()
        XCTAssertEqual(progress.next,1); XCTAssertEqual(progress.state(1),.next); XCTAssertEqual(progress.state(20),.open)
        XCTAssertTrue(progress.clear(20),"A stage above the suggested one can be solved first")
        XCTAssertEqual(progress.state(20),.done); XCTAssertEqual(progress.next,1,"The suggested key stays the lowest unsolved one")
        XCTAssertTrue(progress.blackKeyPressed(above:20)); XCTAssertFalse(progress.blackKeyPressed(above:19)); XCTAssertFalse(progress.blackKeyPressed(above:1))
        XCTAssertFalse(progress.clear(20),"Solving a stage again changes nothing")
        XCTAssertTrue(progress.clear(1)); XCTAssertEqual(progress.next,2); XCTAssertTrue(progress.blackKeyPressed(above:1))
        XCTAssertFalse(progress.clear(0)); XCTAssertFalse(progress.clear(31))
        for n in 1...30 { progress.clear(n) }
        XCTAssertTrue(progress.isComplete); XCTAssertEqual(progress.next,31)
        XCTAssertTrue((1...30).allSatisfy { progress.state($0) == .done })
    }
    func testLoadKeepsEverySolvedStageAndDropsUnknownOnes() throws {
        XCTAssertEqual(try DrillStairsProgress.load(nil),DrillStairsProgress())
        let data = Data(#"{"cleared":[1,2,3,5,40,-1]}"#.utf8)
        let progress = try DrillStairsProgress.load(data)
        XCTAssertEqual(progress.cleared,[1,2,3,5]); XCTAssertEqual(progress.next,4)
        XCTAssertThrowsError(try DrillStairsProgress.load(Data("nope".utf8)))
        let saved = try JSONEncoder().encode(progress)
        XCTAssertEqual(try DrillStairsProgress.load(saved),progress)
    }
}
