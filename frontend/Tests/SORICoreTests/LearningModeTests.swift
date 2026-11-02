import XCTest
import Foundation
@testable import SORICore

final class LearningModeTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    func testLegacyAttemptsRemainExamAndNewPracticeIsExplicit() throws {
        let data = try Data(contentsOf:root.appendingPathComponent("docs/sori-api/examples/attempt-ready.json"))
        let old = try ContractJSON.decoder().decode(Attempt.self,from:data)
        XCTAssertEqual(old.studyMode,.exam)
        XCTAssertNil(old.mode)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        object["mode"] = "practice"; object["grading_mode"] = "self"
        let current = try ContractJSON.decoder().decode(Attempt.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertEqual(current.studyMode,.practice)
        XCTAssertEqual(try ContractJSON.decoder().decode(Attempt.self,from:ContractJSON.encoder().encode(current)),current)
    }

    func testMultipleErrorTypesCanBeSelectedAndIndividuallyCleared() throws {
        var edits: [MeasureError] = []
        edits = try SelfAssessmentEdits.toggling(edits,measure:3,type:.rhythm,measureCount:8)
        edits = try SelfAssessmentEdits.toggling(edits,measure:3,type:.pitch,measureCount:8)
        XCTAssertEqual(edits,[MeasureError(measure:3,types:["pitch","rhythm"])])
        edits = try SelfAssessmentEdits.toggling(edits,measure:3,type:.pitch,measureCount:8)
        XCTAssertEqual(edits,[MeasureError(measure:3,types:["rhythm"])])
        edits = try SelfAssessmentEdits.toggling(edits,measure:3,type:.rhythm,measureCount:8)
        XCTAssertTrue(edits.isEmpty)
    }

    func testInvalidOrDuplicateMeasureRecordsAreRejected() {
        for errors in [[MeasureError(measure:0,types:["pitch"])], [MeasureError(measure:9,types:["pitch"])],
                       [MeasureError(measure:1,types:[])], [MeasureError(measure:1,types:["pitch","pitch"])],
                       [MeasureError(measure:1,types:["pitch"]),MeasureError(measure:1,types:["rhythm"])]] {
            XCTAssertThrowsError(try SelfAssessmentEdits.normalized(errors,measureCount:8))
        }
        XCTAssertThrowsError(try SelfAssessmentEdits.toggling([],measure:1,type:.pitch,measureCount:0))
    }

    func testPendingAndCompletedEmptyReviewAreDifferent() throws {
        let url = root.appendingPathComponent("docs/sori-api/examples/practice-assessment-pending.json")
        let pending = try ContractJSON.decoder().decode(PracticeAssessment.self,from:Data(contentsOf:url))
        XCTAssertFalse(pending.isCompleted)
        XCTAssertNil(pending.completedAt)
        try pending.validate(attemptId:pending.attemptId,answerId:pending.answerId,measureCount:8)
        var complete = pending
        complete.status = "completed"; complete.revision = 1; complete.completedAt = complete.updatedAt
        XCTAssertTrue(complete.isCompleted)
        XCTAssertTrue(complete.errors.isEmpty)
        try complete.validate(attemptId:complete.attemptId,answerId:complete.answerId,measureCount:8)
        complete.completedAt = nil
        XCTAssertThrowsError(try complete.validate(attemptId:complete.attemptId,answerId:complete.answerId,measureCount:8))
    }

    func testEveryMeasureHasOneValidHitRegionInEachBundledLayout() throws {
        let resources = root.appendingPathComponent("frontend/IPadApp/IPadApp/Resources")
        let files = ["practice-catalog.json","sheet-revisions.json"]
        for file in files {
            let questions = try ContractJSON.decoder().decode([Question].self,from:Data(contentsOf:resources.appendingPathComponent(file)))
            for q in questions {
                let strips = AnswerSystemCrop.strips(layout:q.sheetLayout)
                let regions = strips.flatMap { $0.measureRegions(layout:q.sheetLayout) }
                XCTAssertEqual(regions.map(\.id),Array(1...8),q.title)
                XCTAssertTrue(regions.allSatisfy { $0.bounds.isValid },q.title)
                for strip in strips {
                    let values = strip.measureRegions(layout:q.sheetLayout)
                    for pair in zip(values,values.dropFirst()) {
                        XCTAssertEqual(pair.0.bounds.x+pair.0.bounds.width,pair.1.bounds.x,accuracy:0.000001)
                    }
                }
            }
        }
    }
}
