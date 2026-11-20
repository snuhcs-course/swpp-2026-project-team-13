import XCTest
import SwiftUI
@testable import IPadApp

@MainActor final class FeedbackRatingIntegrationTests: XCTestCase {
    func testCompletedExamSurveyPersistsAcrossReloadWithoutChangingGradeOrRating() async throws {
        let scope = "feedback-test-"+UUID().uuidString
        let model = AppModel(demoScope:scope); model.demo = true; model.demoOutcome = "completed"
        await model.connect(); await model.startRecommendedExam()
        let offer = try XCTUnwrap(model.examOffer)
        await model.chooseExam(try XCTUnwrap(offer.choices.first { $0.questionId != nil }))
        await model.begin(); await model.start(); model.player.pause(); await model.submit()
        XCTAssertNil(model.error)
        let api = try DemoExamAPI(outcome:"completed",storageScope:scope)
        let attempt = try XCTUnwrap(model.session?.id)
        var record = try api.store.load(attempt)
        record.grading?.createdAt = Date().addingTimeInterval(-5); try api.store.save(record)
        _ = try await api.result(attempt); await model.refreshResult()
        let before = try XCTUnwrap(model.session?.grading)
        let state = try XCTUnwrap(before.feedbackRating)
        XCTAssertTrue(state.enabled)
        let feedbackId = try XCTUnwrap(state.feedbackId)
        _ = try await model.saveFeedbackRating(jobId:before.jobId,feedbackId:feedbackId,stars:4,reason:"마디 비교가 도움이 됐어요.")
        await model.refreshResult()
        XCTAssertEqual(model.session?.grading?.feedbackRating?.rating?.stars,4)
        XCTAssertEqual(model.session?.grading?.score,before.score)
        XCTAssertEqual(model.session?.grading?.ratingChange,before.ratingChange)
        let restored = try await api.result(attempt)
        XCTAssertEqual(restored.feedbackRating?.rating?.reason,"마디 비교가 도움이 됐어요.")
        let renderer = ImageRenderer(content:ExamResultView(model:model).frame(width:1180,height:792))
        renderer.scale = 1
        let attachment = XCTAttachment(image:try XCTUnwrap(renderer.uiImage))
        attachment.name = "exam-result-short-coach-survey"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
