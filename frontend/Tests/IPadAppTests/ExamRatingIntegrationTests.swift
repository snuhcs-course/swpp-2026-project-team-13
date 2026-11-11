import XCTest
import SwiftUI
@testable import IPadApp

@MainActor final class ExamRatingIntegrationTests: XCTestCase {
    func testLoadingSelectionGradingAndNoRepeatAfterRestart() async throws {
        let model = AppModel(); model.demo = true; model.demoOutcome = "completed"; await model.connect()
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
        await model.begin(); XCTAssertNil(model.error)
        let attempt = try XCTUnwrap(model.session?.attempt)
        XCTAssertEqual(attempt.examRatingSnapshot?.difficultyScore,choice.difficultyScore)
        await model.start(); model.player.pause(); await model.submit()
        try await Task.sleep(for:.seconds(4.2)); await model.refreshResult()
        XCTAssertNil(model.error)
        let change = try XCTUnwrap(model.session?.grading?.ratingChange)
        XCTAssertEqual(change.before,offer.rating.value,accuracy:0.0000001)
        await model.refreshResult()
        XCTAssertEqual(model.session?.grading?.ratingChange,change)
        let restored = AppModel(); restored.demo = true; await restored.connect()
        await restored.startRecommendedExam()
        XCTAssertEqual(restored.examOffer?.rating.value,change.after)
        XCTAssertFalse(try XCTUnwrap(restored.examOffer).choices.contains { $0.questionId == choice.questionId })
        restored.switchAccount(); XCTAssertNil(restored.examOffer)
    }

    func testPreparedExamReservationRejectsNewAttemptButReplaysSameKey() async throws {
        let api = try DemoExamAPI(outcome:"completed")
        let question = try await api.recommendedQuestion(), key = UUID()
        let a = try await api.createAttempt(question:question,mode:.exam,key:key)
        let b = try await api.createAttempt(question:question,mode:.exam,key:key)
        XCTAssertEqual(a.id,b.id)
        do {
            _ = try await api.createAttempt(question:question,mode:.exam,key:UUID())
            XCTFail("A seen exam must not create another attempt")
        } catch { }
        let next = try await api.examRecommendations()
        XCTAssertFalse(next.choices.contains { $0.questionId == question.id })
    }
}
