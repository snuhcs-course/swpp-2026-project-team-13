import XCTest
import SwiftUI
@testable import IPadApp

@MainActor final class ClassicalIntegrationTests: XCTestCase {
    func testDemoClassicalAssetsAndReferencesUseTheExistingRoutes() async throws {
        let api = try DemoExamAPI(outcome:"completed")
        let practice = try await api.questions(page:1)
        XCTAssertEqual(practice.results.count,62)
        let classical = try await api.classicalQuestions(page:1)
        XCTAssertEqual(classical.results.count,11)
        for summary in classical.results {
            let q = try await api.question(summary.id); try q.validate()
            for asset in [q.scoreAssets.main,q.scoreAssets.scale] {
                let data = try await api.asset(asset.url,authenticated:true,limit:1_048_576)
                let score = try MusicXMLParser.parseMXL(data,asset:asset)
                XCTAssertEqual(score.keySignature,q.keySignature)
                XCTAssertEqual(score.timeSignature,q.timeSignature)
            }
            let png = try await api.asset(q.sheetLayout.templatePngUrl,authenticated:false,limit:10_485_760)
            _ = try AnswerExporter.validateTemplate(png,layout:q.sheetLayout)
            let reference = try XCTUnwrap(q.correctScore)
            let image = try await api.asset(reference.url,authenticated:true,limit:2_097_152)
            XCTAssertEqual(image.sha256,reference.sha256)
        }
    }

    func testClassicalExamPrepareSubmitRestoreAndComposerScreen() async throws {
        let model = AppModel(); model.demo = true; model.demoOutcome = "completed"
        await model.connect(); await model.loadClassical()
        XCTAssertNil(model.error); XCTAssertEqual(model.questions.count,62); XCTAssertEqual(model.classicalQuestions.count,11)
        let view = ImageRenderer(content:ClassicalExamLibraryView(model:model).frame(width:1024,height:768))
        view.scale = 2
        let screenshot = try XCTUnwrap(view.uiImage)
        let attachment = XCTAttachment(image:screenshot); attachment.name = "classical-composer-selection"; attachment.lifetime = .keepAlways; add(attachment)
        let q = try XCTUnwrap(model.classicalQuestions.first(where: { $0.keySignature.mode == "minor" }))
        model.selectedComposer = q.composer
        await model.choose(q.id); await model.begin()
        XCTAssertNil(model.error); XCTAssertTrue(model.prepared)
        XCTAssertEqual(model.mainScore?.keySignature,q.keySignature)
        let id = try XCTUnwrap(model.session?.id)
        await model.start(); model.player.pause(); await model.submit()
        XCTAssertNil(model.error); XCTAssertEqual(model.screen,.result)
        try await Task.sleep(for:.seconds(4.2)); await model.refreshResult()
        XCTAssertNotNil(model.correctScoreImage); XCTAssertNotNil(model.submittedImage)
        let restored = AppModel(); restored.demo = true; await restored.connect()
        await restored.open(try XCTUnwrap(restored.history.first(where: { $0.id == id })))
        XCTAssertNil(restored.error); XCTAssertEqual(restored.session?.attempt.question.collection,"classical")
        XCTAssertEqual(restored.selectedQuestion?.keySignature,q.keySignature)
        XCTAssertNotNil(restored.correctScoreImage)
    }
}
