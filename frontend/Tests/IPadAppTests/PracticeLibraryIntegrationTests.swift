import XCTest
import SwiftUI
@testable import IPadApp

@MainActor final class PracticeLibraryIntegrationTests: XCTestCase {
    func testEveryImportedDemoAssetUsesTheExistingExamRoutes() async throws {
        let api = try DemoExamAPI(outcome:"completed")
        let list = try await api.questions(page:1)
        XCTAssertEqual(list.results.count,113)
        XCTAssertEqual(list.results.filter { $0.practiceLevel == .beginner }.count,40)
        XCTAssertEqual(list.results.filter { $0.practiceLevel == .intermediate }.count,14)
        XCTAssertEqual(list.results.filter { $0.practiceLevel == .advanced }.count,59)
        let added: [Question] = try Bundled.decode("additional-practice-catalog")
        for item in added {
            let q = try await api.question(item.id); try q.validate()
            for asset in [q.scoreAssets.main,q.scoreAssets.scale] {
                let data = try await api.asset(asset.url,authenticated:true,limit:1_048_576)
                let score = try MusicXMLParser.parseMXL(data,asset:asset)
                XCTAssertEqual(score.keySignature,q.keySignature)
                XCTAssertEqual(score.timeSignature,q.timeSignature)
            }
            let template = try await api.asset(q.sheetLayout.templatePngUrl,authenticated:false,limit:10_485_760)
            _ = try AnswerExporter.validateTemplate(template,layout:q.sheetLayout)
            let reference = try XCTUnwrap(q.correctScore)
            let image = try await api.asset(reference.url,authenticated:true,limit:2_097_152)
            XCTAssertEqual(image.sha256,reference.sha256)
        }
    }
    func testPracticeLevelsScreenAndImportedExamRestore() async throws {
        let model = AppModel(); model.demo = true; model.demoOutcome = "completed"; await model.connect()
        XCTAssertNil(model.error); XCTAssertEqual(model.questions.count,113)
        let renderer = ImageRenderer(content:HomeView(model:model).frame(width:1180,height:1024)); renderer.scale = 2
        let attachment = XCTAttachment(image:try XCTUnwrap(renderer.uiImage)); attachment.name = "practice-level-selection"; attachment.lifetime = .keepAlways; add(attachment)
        let summary = try XCTUnwrap(model.questions.first { $0.practiceLevel == .beginner && $0.keySignature.fifths != 0 })
        model.selectedPracticeLevel = .beginner
        await model.choose(summary.id); await model.begin()
        XCTAssertNil(model.error); XCTAssertTrue(model.prepared)
        let id = try XCTUnwrap(model.session?.id)
        await model.start(); model.player.pause(); await model.submit()
        XCTAssertNil(model.error); XCTAssertEqual(model.screen,.result)
        let restored = AppModel(); restored.demo = true; await restored.connect()
        await restored.open(try XCTUnwrap(restored.history.first { $0.id == id }))
        XCTAssertNil(restored.error); XCTAssertEqual(restored.selectedPracticeLevel,.beginner)
        XCTAssertEqual(restored.selectedQuestion?.id,summary.id)
    }
}
