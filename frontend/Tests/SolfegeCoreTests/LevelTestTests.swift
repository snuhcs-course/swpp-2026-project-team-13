import XCTest
@testable import SolfegeCore

final class LevelTestTests: XCTestCase {
    private let attempt1 = "7a1d0d55-5f0f-4a43-9a43-2b6f4bb7a001"
    private let attempt2 = "7a1d0d55-5f0f-4a43-9a43-2b6f4bb7a002"

    private func state(status: String, stages: String = "[]", next: String = "null", canFinish: Bool = false, rating: String = "null") throws -> LevelTestState {
        let json = """
        {"version":"level-test-1","status":"\(status)","pass_grade":80,"skip_rating":0.0,"stages":\(stages),
         "next_stage":\(next),"can_finish":\(canFinish),"rating":\(rating)}
        """
        let value = try ContractJSON.decoder().decode(LevelTestState.self, from:Data(json.utf8))
        try value.validate()
        return value
    }
    private func stage(_ number: Int, _ tier: String, _ id: String, grade: Int?) -> String {
        let g = grade.map(String.init) ?? "null"
        let passed = grade.map { $0 >= 80 ? "true" : "false" } ?? "null"
        return #"{"stage":\#(number),"tier":"\#(tier)","attempt_id":"\#(id)","grade":\#(g),"passed":\#(passed)}"#
    }

    func testNewAccountStartsWithTheIntro() throws {
        let value = try state(status:"required", next:"1")
        XCTAssertTrue(value.needsLevelTest)
        XCTAssertEqual(value.phase, .intro)
        XCTAssertNil(value.unresolvedAttemptId)
    }

    func testUngradedStageResumesItsAttempt() throws {
        let value = try state(status:"in_progress", stages:"[\(stage(1,"easy",attempt1,grade:nil))]")
        XCTAssertEqual(value.phase, .grading(stage:1))
        XCTAssertEqual(value.unresolvedAttemptId, UUID(uuidString:attempt1))
    }

    func testPassedStageOffersTheNextTierAndAMissEndsTheTest() throws {
        let passed = try state(status:"in_progress", stages:"[\(stage(1,"easy",attempt1,grade:92))]", next:"2", canFinish:true)
        XCTAssertEqual(passed.phase, .offer(stage:1, grade:92))
        let missed = try state(status:"in_progress", stages:"[\(stage(1,"easy",attempt1,grade:92)),\(stage(2,"medium",attempt2,grade:64))]", canFinish:true)
        XCTAssertEqual(missed.phase, .ended(stage:2, grade:64, passed:false))
    }

    func testFinishedTestShowsTheRatingAndOtherStatusesKeepTheExamFlow() throws {
        let done = try state(status:"completed", stages:"[\(stage(1,"easy",attempt1,grade:64))]", rating:"8.19")
        XCTAssertEqual(done.phase, .rating(8.19))
        XCTAssertFalse(done.needsLevelTest)
        XCTAssertFalse(try state(status:"skipped", rating:"0.0").needsLevelTest)
        XCTAssertFalse(try state(status:"not_applicable").needsLevelTest)
        XCTAssertFalse(LevelTestState.notApplicable.needsLevelTest)
        XCTAssertNoThrow(try LevelTestState.notApplicable.validate())
    }

    func testInconsistentProgressIsRejected() {
        XCTAssertThrowsError(try state(status:"unknown"))
        XCTAssertThrowsError(try state(status:"in_progress"))
        XCTAssertThrowsError(try state(status:"in_progress", stages:"[\(stage(1,"medium",attempt1,grade:90))]"))
        XCTAssertThrowsError(try state(status:"in_progress", stages:"[\(stage(2,"medium",attempt1,grade:90))]"))
        XCTAssertThrowsError(try state(status:"required", next:"3"))
        let wrongPass = #"{"stage":1,"tier":"easy","attempt_id":"\#(attempt1)","grade":70,"passed":true}"#
        XCTAssertThrowsError(try state(status:"in_progress", stages:"[\(wrongPass)]"))
    }

    func testStageQuestionAndFrozenSnapshotDecode() throws {
        let question = try ContractJSON.decoder().decode(LevelTestQuestion.self, from:Data("""
        {"stage":2,"tier":"medium","question_id":"\(attempt1)","question_version":3,"difficulty_score":21.4}
        """.utf8))
        XCTAssertNoThrow(try question.validate())
        var wrong = question; wrong.tier = "hard"
        XCTAssertThrowsError(try wrong.validate())
        let snapshot = try ContractJSON.decoder().decode(ExamRatingSnapshot.self, from:Data("""
        {"model_version":"exam-rating-1","pool_version":"question-pools-1","difficulty_version":"practice-difficulty-2",
         "difficulty_score":9.1,"level_test":{"version":"level-test-1","stage":1,"tier":"easy"}}
        """.utf8))
        XCTAssertEqual(snapshot.levelTest?.stage, 1)
        let regular = try ContractJSON.decoder().decode(ExamRatingSnapshot.self, from:Data("""
        {"model_version":"exam-rating-1","pool_version":"question-pools-1","difficulty_version":"practice-difficulty-2","difficulty_score":9.1}
        """.utf8))
        XCTAssertNil(regular.levelTest)
        XCTAssertEqual(LevelTestTier.stageTitle(3), "3단계 · 고급 문제")
    }
}
