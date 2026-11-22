import XCTest
@testable import SolfegeCore

final class EchoIntervalStageTests: XCTestCase {
    func testTenStagesMatchRequestedIntervalCurriculum() {
        let expected=[[1,2],[3,4],Array(1...4),[5,6,7],Array(1...7),[8,9],[10,11],Array(1...12),Array(1...12),Array(1...24)]
        let stairs=DrillStairs.stages.filter { $0.game == .echoDragon }
        XCTAssertEqual(stairs.count,10)
        for (index,stair) in stairs.enumerated() {
            let stage=EchoIntervalStage(index+1)
            XCTAssertEqual(EchoIntervalStage.forStair(stair.number),stage)
            XCTAssertEqual(stage.intervals,expected[index]); XCTAssertEqual(stage.questions.count,10)
            XCTAssertEqual(stage.questions,stage.questions,"A stage is pinned, not redrawn between questions")
            XCTAssertEqual(Set(stage.questions.map(\.id)).count,10)
            XCTAssertEqual(stage.questions.filter { $0.distance>0 }.count,5)
            XCTAssertEqual(stage.questions.filter { $0.distance<0 }.count,5)
            for q in stage.questions {
                XCTAssertTrue(expected[index].contains(abs(q.distance)))
                XCTAssertNotEqual(q.call[0],q.replyStart,"Reply must always start on a different note")
                XCTAssertEqual(q.call[1]-q.call[0],q.distance)
                XCTAssertTrue(q.answer.allSatisfy(q.keyboardRange.contains))
                XCTAssertTrue(q.call.allSatisfy((48...84).contains))
                XCTAssertTrue(q.accepts(q.answer))
                XCTAssertFalse(q.accepts(q.call),"Literal pitch imitation is not the requested answer")
            }
            if stage.intervals.count == 2 {
                for interval in stage.intervals { XCTAssertEqual(stage.questions.filter { abs($0.distance)==interval }.count,5) }
            }
        }
        XCTAssertNil(EchoIntervalStage.forStair(2)); XCTAssertNil(EchoIntervalStage.forStair(99))
        XCTAssertNotEqual(EchoIntervalStage(8).questions.map(\.distance),EchoIntervalStage(9).questions.map(\.distance))
        XCTAssertTrue(EchoIntervalStage(10).questions.contains { abs($0.distance) == 24 })
    }
    func testSignedIntervalAndGivenStartingNoteAreBothRequired() {
        for level in 1...10 {
            for q in EchoIntervalStage(level).questions {
                XCTAssertFalse(q.accepts([q.replyStart]))
                XCTAssertFalse(q.accepts([q.replyStart,q.replyStart-q.distance]))
                XCTAssertFalse(q.accepts(q.answer.map { $0+1 }))
                XCTAssertFalse(q.accepts([q.replyStart,q.answer[1]+12]))
                XCTAssertFalse(q.accepts(q.answer+[q.replyStart]))
            }
        }
    }
    func testThreeErrorsAreSharedAcrossWholeStageAndThirdFails() {
        var run=EchoIntervalRun(stage:EchoIntervalStage(1))
        func wrong(_ q: EchoIntervalQuestion) -> [Int] { [q.replyStart,q.answer[1]+1] }
        XCTAssertNil(run.grade([run.question.replyStart])); XCTAssertEqual(run.hearts,3)
        XCTAssertEqual(run.grade(wrong(run.question)),false); XCTAssertEqual(run.hearts,2)
        XCTAssertEqual(run.grade(run.question.answer),true)
        XCTAssertNil(run.grade(run.question.answer),"Repeated submit must not grade a solved turn twice")
        run.advance(); XCTAssertEqual(run.index,1); XCTAssertEqual(run.hearts,2)
        XCTAssertEqual(run.grade(wrong(run.question)),false); XCTAssertEqual(run.hearts,1)
        XCTAssertEqual(run.grade(run.question.answer),true); run.advance()
        XCTAssertEqual(run.grade(wrong(run.question)),false)
        XCTAssertEqual(run.hearts,0); XCTAssertTrue(run.failed); XCTAssertFalse(run.complete)
        XCTAssertNil(run.grade(run.question.answer)); run.advance(); XCTAssertEqual(run.index,2)
    }
    func testTenCorrectAnswersClearEvenAfterTwoRetriesAndRestartRestoresHearts() {
        var run=EchoIntervalRun(stage:EchoIntervalStage(4))
        for _ in 0..<2 { run.grade([run.question.replyStart,run.question.answer[1]+1]) }
        for turn in 0..<10 {
            XCTAssertEqual(run.index,turn); XCTAssertFalse(run.complete)
            XCTAssertEqual(run.grade(run.question.answer),true)
            run.advance()
        }
        XCTAssertTrue(run.complete); XCTAssertFalse(run.failed); XCTAssertEqual(run.hearts,1)
        XCTAssertEqual(run.errors.reduce(0,+),2)
        run=EchoIntervalRun(stage:run.stage)
        XCTAssertEqual(run.hearts,3); XCTAssertEqual(run.index,0); XCTAssertFalse(run.complete)
    }
}
