import XCTest
import SwiftUI
@testable import IPadApp

@MainActor final class ExamRatingIntegrationTests: XCTestCase {
    private let demoScope = "exam-test-"+UUID().uuidString
    func testLoadingSelectionGradingAndNoRepeatAfterRestart() async throws {
        let model = AppModel(demoScope:demoScope); model.demo = true; model.demoOutcome = "completed"; await model.connect()
        await model.startRecommendedExam()
        XCTAssertNil(model.error); XCTAssertEqual(model.screen,.examSelection)
        let offer = try XCTUnwrap(model.examOffer)
        try offer.validate()
        let renderer = ImageRenderer(content:ExamSelectionView(model:model).frame(width:1180,height:792))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        let attachment = XCTAttachment(image:image); attachment.name = "exam-selection-raised-cards"
        attachment.lifetime = .keepAlways; add(attachment)
        let choice = try XCTUnwrap(offer.choices.first { $0.questionId != nil })
        XCTAssertFalse(model.questions.contains { $0.id == choice.questionId })
        await model.chooseExam(choice); XCTAssertEqual(model.screen,.question)
        let reservedId = try XCTUnwrap(model.session?.id)
        XCTAssertNil(model.session?.attempt.startedAt)
        await model.begin(); XCTAssertNil(model.error)
        let attempt = try XCTUnwrap(model.session?.attempt)
        XCTAssertEqual(attempt.examRatingSnapshot?.difficultyScore,choice.difficultyScore)
        await model.start(); model.player.pause(); await model.submit()
        XCTAssertFalse(model.canChooseNextExam)
        model.navigate(.main); XCTAssertEqual(model.screen,.main)
        await model.startRecommendedExam()
        XCTAssertEqual(model.screen,.result); XCTAssertEqual(model.session?.id,reservedId)
        XCTAssertFalse(model.canChooseNextExam); XCTAssertNil(model.examOffer)
        let waiting = AppModel(demoScope:demoScope); waiting.demo = true; await waiting.connect(); await waiting.startRecommendedExam()
        XCTAssertEqual(waiting.screen,.result); XCTAssertEqual(waiting.session?.id,reservedId)
        XCTAssertNil(waiting.examOffer)
        try await Task.sleep(for:.seconds(4.2)); await model.refreshResult()
        XCTAssertNil(model.error)
        XCTAssertTrue(model.canChooseNextExam)
        let change = try XCTUnwrap(model.session?.grading?.ratingChange)
        XCTAssertEqual(change.before,offer.rating.value,accuracy:0.0000001)
        await model.refreshResult()
        XCTAssertEqual(model.session?.grading?.ratingChange,change)
        let restored = AppModel(demoScope:demoScope); restored.demo = true; await restored.connect()
        await restored.startRecommendedExam()
        XCTAssertEqual(restored.examOffer?.rating.value,change.after)
        XCTAssertFalse(try XCTUnwrap(restored.examOffer).choices.contains { $0.questionId == choice.questionId })
        // A stale selection from another device must not leave a stuck pending receipt.
        await model.chooseExam(choice)
        XCTAssertNil(model.error); XCTAssertFalse(model.pendingCreation); XCTAssertEqual(model.screen,.examSelection)
        restored.switchAccount(); XCTAssertNil(restored.examOffer)
    }

    func testPreparedExamReservationRejectsNewAttemptButReplaysSameKey() async throws {
        let api = try DemoExamAPI(outcome:"completed",storageScope:demoScope)
        let question = try await api.recommendedQuestion(), key = UUID()
        let a = try await api.createAttempt(question:question,mode:.exam,key:key)
        let b = try await api.createAttempt(question:question,mode:.exam,key:key)
        XCTAssertEqual(a.id,b.id)
        do {
            _ = try await api.createAttempt(question:question,mode:.exam,key:UUID())
            XCTFail("A seen exam must not create another attempt")
        } catch { }
        let next = try await api.examRecommendations()
        XCTAssertEqual(next.activeAttemptId,a.id); XCTAssertTrue(next.choices.isEmpty)
    }

    func testUnselectedOfferSurvivesHomeAndAppRestart() async throws {
        let model = AppModel(demoScope:demoScope); model.demo = true; await model.connect()
        await model.startRecommendedExam()
        let offer = try XCTUnwrap(model.examOffer)
        model.navigate(.main); await model.startRecommendedExam()
        XCTAssertEqual(model.screen,.examSelection); XCTAssertEqual(model.examOffer,offer)
        let restored = AppModel(demoScope:demoScope); restored.demo = true; await restored.connect()
        XCTAssertEqual(restored.examOffer,offer)
        await restored.startRecommendedExam()
        XCTAssertEqual(restored.screen,.examSelection); XCTAssertEqual(restored.examOffer,offer)
        XCTAssertTrue(restored.history.isEmpty)
    }

    func testSelectionLocksImmediatelyAndCannotBeChangedFromAStaleOffer() async throws {
        let first = AppModel(demoScope:demoScope); first.demo = true; await first.connect(); await first.startRecommendedExam()
        let second = AppModel(demoScope:demoScope); second.demo = true; await second.connect(); await second.startRecommendedExam()
        let offer = try XCTUnwrap(first.examOffer)
        let choices = offer.choices.filter { $0.questionId != nil }
        XCTAssertGreaterThanOrEqual(choices.count,2)
        await first.chooseExam(choices[0])
        let id = try XCTUnwrap(first.session?.id)
        XCTAssertEqual(first.session?.attempt.status,"ready"); XCTAssertNil(first.session?.attempt.startedAt)
        // The second instance still holds its old, unselected offer.
        await second.chooseExam(choices[1])
        XCTAssertNil(second.error); XCTAssertEqual(second.session?.id,id); XCTAssertEqual(second.screen,.question)
        first.navigate(.main); await first.startRecommendedExam()
        XCTAssertEqual(first.session?.id,id); XCTAssertEqual(first.screen,.question)
        XCTAssertNil(first.examOffer)
        let api = try DemoExamAPI(outcome:"completed",storageScope:demoScope)
        XCTAssertEqual(try api.store.all().filter { $0.attempt.studyMode == .exam }.count,1)
    }

    func testServerRestoresSelectedExamWithoutLocalHistory() async throws {
        let api = try DemoExamAPI(outcome:"completed",storageScope:demoScope)
        let question = try await api.recommendedQuestion()
        let a = try await api.createAttempt(question:question,mode:.exam,key:UUID())
        let model = AppModel(demoScope:demoScope); model.demo = true; await model.connect()
        XCTAssertTrue(model.history.isEmpty)
        await model.startRecommendedExam()
        XCTAssertNil(model.error); XCTAssertEqual(model.screen,.question); XCTAssertEqual(model.session?.id,a.id)
        XCTAssertNil(model.session?.attempt.startedAt)
    }

    func testFailedGradingStillRequiresSameAnswerRetry() async throws {
        let model = AppModel(demoScope:demoScope); model.demo = true; model.demoOutcome = "failed"; await model.connect()
        await model.startRecommendedExam()
        await model.chooseExam(try XCTUnwrap(model.examOffer?.choices.first { $0.questionId != nil }))
        await model.begin(); await model.start(); model.player.pause(); await model.submit()
        let id = try XCTUnwrap(model.session?.id)
        try await Task.sleep(for:.seconds(4.2)); await model.refreshResult()
        XCTAssertEqual(model.session?.grading?.status,"failed"); XCTAssertFalse(model.canChooseNextExam)
        model.navigate(.main); await model.startRecommendedExam()
        XCTAssertEqual(model.screen,.result); XCTAssertEqual(model.session?.id,id); XCTAssertNil(model.examOffer)
        await model.retryGrading()
        XCTAssertEqual(model.session?.grading?.status,"queued"); XCTAssertFalse(model.canChooseNextExam)
    }

    func testNextExamButtonRequiresCompletedGradingAndSubmittedExam() throws {
        let model = AppModel(demoScope:demoScope)
        var record = SessionRecord(attempt:try Bundled.decode("attempt-submitted"))
        var grading: Grading = try Bundled.decode("grading-completed")
        for status in ["queued","processing","failed","needs_review"] {
            grading.status = status; record.grading = grading; model.session = record
            XCTAssertFalse(model.canChooseNextExam,status)
        }
        grading.status = "completed"; record.grading = grading; model.session = record
        XCTAssertTrue(model.canChooseNextExam)
        record.attempt.status = "in_progress"; model.session = record
        XCTAssertFalse(model.canChooseNextExam)
        record.attempt.status = "submitted"; record.attempt.mode = "practice"; model.session = record
        XCTAssertFalse(model.canChooseNextExam)
    }

    func testUncertainSelectionRecoversTheServersExistingExam() async throws {
        let api = try DemoExamAPI(outcome:"completed",storageScope:demoScope)
        let offer = try await api.examRecommendations()
        let choices = offer.choices.filter { $0.questionId != nil }
        let first = try await api.question(try XCTUnwrap(choices.first?.questionId))
        let other = try await api.question(try XCTUnwrap(choices.last?.questionId))
        let attempt = try await api.createAttempt(question:first,mode:.exam,key:UUID())
        let model = AppModel(demoScope:demoScope); model.demo = true; await model.connect()
        let local = try LocalStore(scope:api.scope+":"+(try XCTUnwrap(model.profile)).id.uuidString)
        try local.savePending(PendingCreation(question:other,key:UUID(),mode:.exam))
        await model.startRecommendedExam()
        XCTAssertNil(model.error); XCTAssertFalse(model.pendingCreation)
        XCTAssertEqual(model.screen,.question); XCTAssertEqual(model.session?.id,attempt.id)
    }
}
