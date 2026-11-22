import XCTest
import SwiftUI
@testable import IPadApp

@MainActor final class ClassicalIntegrationTests: XCTestCase {
    func testComposerBankLoadsWhenOpenedDirectlyFromHistory() async throws {
        let model=AppModel();model.demo=true
        await model.connect();XCTAssertNil(model.error)
        XCTAssertFalse(model.classicalLoaded)
        model.selectedComposer="브람스"
        let host=UIHostingController(rootView:ClassicalExamLibraryView(model:model))
        let window=UIWindow(frame:CGRect(x:0,y:0,width:1194,height:834))
        window.rootViewController=host;window.makeKeyAndVisible()
        defer { window.isHidden=true }
        let deadline=ProcessInfo.processInfo.systemUptime+10
        while !model.classicalLoaded && model.error == nil && ProcessInfo.processInfo.systemUptime<deadline { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertNil(model.error);XCTAssertTrue(model.classicalLoaded)
        XCTAssertEqual(model.classicalQuestions.count,34)
    }
    func testClassicalBankUsesTheSharedFiltersAndCompletedMarkersWithoutChangingPractice() async throws {
        let model=AppModel(); model.demo=true
        await model.connect(); await model.loadClassical()
        XCTAssertNil(model.error)
        let first=try XCTUnwrap(model.classicalQuestions.first)
        model.selectedComposer=first.composer
        let originalPractice=model.practiceFilter
        let index=try XCTUnwrap(model.classicalQuestions.firstIndex { $0.id==first.id })
        model.classicalQuestions[index].practiceCompleted=true
        let selected=model.classicalQuestions.filter { $0.composer==first.composer }
        XCTAssertTrue(model.completedPracticeQuestionIDs.contains(first.id))
        XCTAssertFalse(model.classicalFilter.apply(to:selected,completedQuestionIDs:model.completedPracticeQuestionIDs).contains { $0.id==first.id })
        model.classicalFilter.showCompleted=true; model.classicalFilter.meter=first.timeSignature
        model.classicalFilter.keySelection = .individual([first.keySignature])
        let visible=model.classicalFilter.apply(to:selected,completedQuestionIDs:model.completedPracticeQuestionIDs)
        XCTAssertTrue(visible.contains { $0.id==first.id })
        XCTAssertTrue(visible.allSatisfy { $0.timeSignature==first.timeSignature && $0.keySignature==first.keySignature })
        XCTAssertEqual(model.practiceFilter,originalPractice)
        for size in [CGSize(width:1024,height:768),CGSize(width:1194,height:834)] {
            let renderer=ImageRenderer(content:ClassicalExamLibraryView(model:model).frame(width:size.width,height:size.height))
            let attachment=XCTAttachment(image:try XCTUnwrap(renderer.uiImage));attachment.name="classical-filtered-bank-\(Int(size.width))";attachment.lifetime = .keepAlways;add(attachment)
        }
        model.selectedComposer=nil
        XCTAssertEqual(model.classicalFilter,QuestionFilter())
    }
    func testDemoClassicalAssetsAndReferencesUseTheExistingRoutes() async throws {
        let api = try DemoExamAPI(outcome:"completed")
        let practice = try await api.questions(page:1)
        let bank: PracticeDifficultyManifest = try Bundled.decode("practice-difficulty")
        XCTAssertEqual(practice.results.count,1550)
        let classical = try await api.classicalQuestions(page:1)
        XCTAssertEqual(classical.results.count,34)
        let order: [UUID] = try Bundled.decode("classical-question-order")
        XCTAssertEqual(classical.results.map(\.id),order)
        for summary in classical.results {
            let q = try await api.question(summary.id); try q.validate()
            XCTAssertNotNil(summary.difficultyScore)
            XCTAssertEqual(summary.difficultyScore,q.difficultyScore)
            XCTAssertNil(q.practiceLevelNumber,"Classical must remain outside the nine-level Practice bank")
            if q.composer == "말러" || q.composer == "브람스" {
                XCTAssertEqual(q.tempo?.policyId,"sori-score-tempo-1")
                let attempt = try await api.createAttempt(question:q,mode:.practice,key:UUID())
                XCTAssertEqual(attempt.playbackPlan.tempo,q.tempo)
                XCTAssertEqual(attempt.playbackPlan.tempoBpm,q.tempo?.quarterBpm)
                // Brahms: v1 → tempo v2 → aligned v3 → MuseScore sheet v4.
                if q.composer == "브람스" { XCTAssertEqual(q.version,4); XCTAssertTrue(q.sheetLayout.id.hasSuffix("-v6")) }
            }
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
        let bank: PracticeDifficultyManifest = try Bundled.decode("practice-difficulty")
        XCTAssertNil(model.error); XCTAssertEqual(model.questions.count,1550); XCTAssertEqual(model.classicalQuestions.count,34)
        let view = ImageRenderer(content:ClassicalExamLibraryView(model:model).frame(width:1024,height:768))
        view.scale = 2
        let screenshot = try XCTUnwrap(view.uiImage)
        let attachment = XCTAttachment(image:screenshot); attachment.name = "classical-composer-selection"; attachment.lifetime = .keepAlways; add(attachment)
        let q = try XCTUnwrap(model.classicalQuestions.first(where: { $0.keySignature.mode == "minor" }))
        model.selectedComposer = q.composer
        await model.choose(q.id,mode:.practice); await model.begin()
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
