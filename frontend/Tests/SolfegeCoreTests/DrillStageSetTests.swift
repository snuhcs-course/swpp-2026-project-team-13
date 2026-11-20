import XCTest
@testable import SolfegeCore

final class DrillStageSetTests: XCTestCase {
    private func course() throws -> DrillStageCourse {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try ContractJSON.decoder().decode(DrillStageCourse.self,from:Data(contentsOf:root.appendingPathComponent("IPadApp/IPadApp/Resources/drill-stage-sets-v1.json")))
    }
    func testFixedSetsHaveSixFourFiveQuestionsAndEchoAlwaysHasTwoActualNotes() throws {
        let c=try course();try c.validate()
        XCTAssertEqual(c.stages.map { $0.questions.count },[6,4,5,6,5,4])
        for set in c.stages where set.game == .echoDragon {
            for q in set.questions { XCTAssertEqual(q.notes?.count,2) }
        }
    }
    func testOnlyAllCorrectUnrevealedResultsMasterAStage() throws {
        let c=try course(), set=try XCTUnwrap(c.stages.first { $0.game == .memoryRun })
        var attempt=DrillSetAttempt(set:set,version:c.version)
        XCTAssertFalse(attempt.complete);XCTAssertFalse(attempt.mastered)
        attempt.results=Array(repeating:DrillRoundResult(accuracy:100,revealed:false,elapsedMs:1000),count:4)
        XCTAssertTrue(attempt.mastered)
        attempt.results[1]=DrillRoundResult(accuracy:100,revealed:true,elapsedMs:1000)
        XCTAssertTrue(attempt.complete);XCTAssertFalse(attempt.mastered)
        attempt.results[1]=DrillRoundResult(accuracy:50,revealed:false,elapsedMs:1000)
        XCTAssertFalse(attempt.mastered)
    }
    func testReorderedOrReplacedQuestionsCannotInheritPreviousProgress() throws {
        let c=try course(), set=try XCTUnwrap(c.stages.first)
        let attempt=DrillSetAttempt(set:set,version:c.version)
        XCTAssertTrue(attempt.matches(set:set,version:c.version))
        XCTAssertFalse(attempt.matches(set:set,version:"next-course"))
        XCTAssertFalse(attempt.matches(set:DrillStageSet(number:set.number,game:set.game,questions:Array(set.questions.reversed())),version:c.version))
    }
}
