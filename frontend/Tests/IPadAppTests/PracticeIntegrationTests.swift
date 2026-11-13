import XCTest
import SwiftUI
@testable import IPadApp

@MainActor final class PracticeIntegrationTests: XCTestCase {
    func testOnlyStartedPracticeReplacesTheSlotAndCompletionDoesNotRestoreAnOlderOne() async throws {
        let scope = "practice-slot-" + UUID().uuidString
        let model = AppModel(demoScope: scope); model.demo = true
        await model.connect(); XCTAssertNil(model.error)
        XCTAssertNil(model.resumablePractice)
        let question = try XCTUnwrap(model.questions.first)
        await model.choose(question.id, mode: .practice); await model.begin()
        XCTAssertNil(model.resumablePractice, "Preparing a problem must not claim the slot")
        await model.start(); model.player.pause(); XCTAssertNil(model.error)
        let first = try XCTUnwrap(model.resumablePractice)

        model.navigate(.home); model.navigate(.practiceLevels)
        model.selectPracticeLevel(.level2)
        XCTAssertEqual(model.screen, .practiceQuestions)
        model.navigate(.classical)
        await model.choose(question.id, mode: .practice); await model.begin()
        XCTAssertEqual(model.resumablePractice?.id, first.id, "Browsing and preparing must preserve handwriting")
        // Foregrounding a newly prepared problem must also preserve the old slot.
        await model.foregroundAgain(); XCTAssertNil(model.error)
        await model.start(); model.player.pause(); XCTAssertNil(model.error)
        let second = try XCTUnwrap(model.resumablePractice)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(model.canOpenHistoryRecord(first))
        model.navigate(.history)
        await model.open(first)
        XCTAssertNotNil(model.error, "History must not bypass the single-slot rule")
        XCTAssertEqual(model.session?.id, second.id); model.error = nil

        let restored = AppModel(demoScope: scope); restored.demo = true
        await restored.connect(); XCTAssertEqual(restored.resumablePractice?.id, second.id)
        await restored.open(try XCTUnwrap(restored.resumablePractice))
        XCTAssertNil(restored.error); XCTAssertEqual(restored.screen, .exam)
        await restored.submit(); XCTAssertNil(restored.error)
        XCTAssertEqual(restored.resumablePractice?.id, second.id, "Submission still needs self-assessment")
        await restored.savePracticeAssessment(completed: false); XCTAssertNil(restored.error)
        XCTAssertEqual(restored.resumablePractice?.id, second.id)
        await restored.savePracticeAssessment(completed: true); XCTAssertNil(restored.error)
        XCTAssertNil(restored.resumablePractice)
        let completed = AppModel(demoScope: scope); completed.demo = true
        await completed.connect(); XCTAssertNil(completed.error)
        XCTAssertNil(completed.resumablePractice, "Completing the current slot must not resurrect the older one")
        XCTAssertTrue(completed.history.contains { $0.id == first.id }, "Learning history stays available")
        completed.switchAccount(); XCTAssertNil(completed.practiceResumeId)
    }

    func testPracticeSlotMigrationEmptyMarkerAndAccountIsolation() throws {
        let store = try LocalStore(scope: "practice-slot-store-" + UUID().uuidString)
        let other = try LocalStore(scope: "practice-slot-other-" + UUID().uuidString)
        defer { try? store.removeAll(); try? other.removeAll() }
        var old = SessionRecord(attempt: try Bundled.decode("attempt-started"))
        old.attempt.mode = "practice"; old.attempt.gradingMode = "self"
        old.attempt.createdAt = Date(timeIntervalSince1970: 100)
        var latest = old; latest.attempt.id = UUID(); latest.attempt.createdAt = Date(timeIntervalSince1970: 200)
        latest.attempt.status = "submitted"
        latest.selfAssessment = PracticeAssessment(attemptId: latest.id, answerId: UUID(), mode: "practice",
            gradingMode: "self", source: "self", featureAnalysisId: nil, status: "completed", revision: 1,
            errors: [], completedAt: Date(), updatedAt: Date(), serverTime: Date())
        XCTAssertNil(try store.practiceResume(records: [old, latest]), "Migrate the latest Practice, not the latest unfinished one")
        XCTAssertNil(try store.practiceResume(records: [old]), "An explicit empty slot survives later launches")
        try store.savePracticeResume(old.id)
        XCTAssertEqual(try store.practiceResume(records: [old, latest]), old.id)
        XCTAssertNil(try other.practiceResume(records: []))
        var exam = old; exam.attempt.mode = "exam"; exam.attempt.gradingMode = "demo"
        XCTAssertNil(try store.practiceResume(records: [exam]), "Exam is never a Practice resume target")
        XCTAssertNil(try store.practiceResume(records: [old]), "An invalid pointer must be cleared durably")
    }

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
        catch { XCTAssertEqual((error as? SolfegeError)?.code,"SELF_ASSESSMENT_REVISION_CONFLICT") }
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
