import XCTest
import SwiftUI
@testable import IPadApp

@MainActor final class PracticeIntegrationTests: XCTestCase {
    func testPracticeSubmitSelfAssessRestoreAndCompleteWithoutAI() async throws {
        let model = AppModel(); model.demo = true
        await model.connect(); XCTAssertNil(model.error)
        await model.choose(try XCTUnwrap(model.questions.first?.id),mode:.practice)
        await model.begin(); XCTAssertNil(model.error)
        let id = try XCTUnwrap(model.session?.id)
        XCTAssertEqual(model.session?.attempt.studyMode,.practice)
        await model.start(); model.player.pause()
        await model.submit(); XCTAssertNil(model.error)
        XCTAssertEqual(model.screen,.result)
        XCTAssertEqual(model.session?.selfAssessment?.status,"pending")
        XCTAssertNil(model.session?.grading)
        XCTAssertTrue(model.practiceComparisonReady)
        model.togglePracticeError(measure:3,type:.pitch)
        model.togglePracticeError(measure:3,type:.rhythm)
        await model.savePracticeAssessment(completed:false)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.session?.selfAssessment?.revision,1)
        XCTAssertEqual(model.practiceErrors,[MeasureError(measure:3,types:["pitch","rhythm"])])
        model.togglePracticeError(measure:5,type:.other)
        let restored = AppModel(); restored.demo = true
        await restored.connect()
        await restored.open(try XCTUnwrap(restored.history.first(where: { $0.id == id })))
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.practiceErrors.count,2)
        XCTAssertNotNil(restored.session?.practiceEdits)
        await restored.savePracticeAssessment(completed:true)
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.session?.selfAssessment?.status,"completed")
        XCTAssertEqual(restored.session?.selfAssessment?.revision,2)
        XCTAssertNil(restored.session?.practiceEdits)
        XCTAssertNil(restored.session?.grading)
        let renderer = ImageRenderer(content:ResultView(model:restored).frame(width:1024,height:1100))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage)
        let attachment = XCTAttachment(image:image)
        attachment.name = "practice-self-assessment"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testDemoReviewReplayAndRevisionConflictPreserveNewerState() async throws {
        let api = try DemoExamAPI(outcome:"completed")
        let page = try await api.questions(page:1)
        let q = try await api.question(try XCTUnwrap(page.results.first?.id))
        let a = try await api.createAttempt(question:q,mode:.practice,key:UUID())
        _ = try await api.start(a.id)
        let png = try Bundled.data(q.sheetLayout.id,ext:"png")
        let answer = try await api.upload(a.id,png:png,clientId:UUID(),layout:q.sheetLayout.id,key:UUID())
        let initial = try await api.submitPractice(a.id,answerId:answer.id,key:UUID())
        XCTAssertEqual(initial.revision,0)
        let key = UUID()
        let request = SelfAssessmentWrite(expectedRevision:0,errors:[MeasureError(measure:2,types:["pitch"])],completed:true)
        let first = try await api.saveSelfAssessment(a.id,request:request,key:key)
        _ = try await api.saveSelfAssessment(a.id,request:SelfAssessmentWrite(expectedRevision:1,errors:[],completed:true),key:UUID())
        let replay = try await api.saveSelfAssessment(a.id,request:request,key:key)
        XCTAssertEqual(replay,first)
        let current = try await api.practiceAssessment(a.id)
        XCTAssertEqual(current.revision,2)
        XCTAssertTrue(current.errors.isEmpty)
        do { _ = try await api.saveSelfAssessment(a.id,request:request,key:UUID()); XCTFail("Expected conflict") }
        catch { XCTAssertEqual((error as? SORIError)?.code,"SELF_ASSESSMENT_REVISION_CONFLICT") }
        do { _ = try await api.submit(a.id,answerId:answer.id,key:UUID()); XCTFail("Practice cannot enqueue AI") }
        catch { }
    }

    func testLocalReviewSaveJournalKeepsExactRetryPayload() throws {
        let store = try LocalStore(scope:"practice-journal-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:store.root) }
        var record = SessionRecord(attempt:try Bundled.decode("attempt-started"))
        record.attempt.mode = "practice"; record.attempt.gradingMode = "self"
        record.practiceEdits = [MeasureError(measure:1,types:["pitch","rhythm"])]
        record.practiceBaseRevision = 3
        let request = SelfAssessmentWrite(expectedRevision:3,errors:record.practiceEdits!,completed:true)
        record.selfAssessmentSave = PendingSelfAssessment(key:UUID(),request:request)
        try store.save(record)
        let restored = try store.load(record.id)
        XCTAssertEqual(restored.practiceEdits,record.practiceEdits)
        XCTAssertEqual(restored.selfAssessmentSave?.key,record.selfAssessmentSave?.key)
        XCTAssertEqual(restored.selfAssessmentSave?.request,request)
    }
}
