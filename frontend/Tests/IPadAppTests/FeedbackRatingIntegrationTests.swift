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
        XCTAssertTrue(model.canChooseNextExam)
        try captureResult(model,name:"completed")

        // Render the same screen while queued, recognizing, writing feedback and
        // after a retryable failure. None may unlock new rated recommendations.
        for (status,stage) in [("queued","queued"),("processing","recognizing"),("processing","feedback"),("failed","done")] {
            var pending = before
            pending.status = status; pending.stage = stage
            pending.score = nil; pending.ratingChange = nil; pending.feedback = nil
            pending.failure = status == "failed" ? GradingFailure(code:"RECOGNITION_TIMEOUT",message:"시간 내에 채점을 완료하지 못했어요.",retryable:true) : nil
            model.session?.grading = pending
            XCTAssertFalse(model.canChooseNextExam,"A \(status)/\(stage) result must keep the next-exam button disabled")
            XCTAssertEqual(model.session?.grading?.canRetry,status == "failed")
            try captureResult(model,name:status+"-"+stage)
        }
        model.session?.grading = before
        XCTAssertTrue(model.canChooseNextExam)
    }
    private func captureResult(_ model: AppModel,name: String) throws {
        for (width,height) in [(1024.0,768.0),(1194.0,834.0)] {
            let renderer = ImageRenderer(content:ExamResultView(model:model).frame(width:width,height:height))
            renderer.scale = 1
            let attachment = XCTAttachment(image:try XCTUnwrap(renderer.uiImage))
            attachment.name = "exam-result-\(name)-\(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}
