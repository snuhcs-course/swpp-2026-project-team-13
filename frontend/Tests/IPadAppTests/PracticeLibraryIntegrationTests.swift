import XCTest
import SwiftUI
@testable import IPadApp

@MainActor final class PracticeLibraryIntegrationTests: XCTestCase {
    func testEveryImportedDemoAssetUsesTheExistingExamRoutes() async throws {
        let api = try DemoExamAPI(outcome:"completed")
        let list = try await api.questions(page:1)
        let manifest: PracticeDifficultyManifest = try Bundled.decode("practice-difficulty")
        XCTAssertEqual(list.results.count,1550)
        XCTAssertEqual(Set(list.results.map { $0.practiceLevel.number }),Set(1...9))
        for q in list.results {
            let entry = try XCTUnwrap(manifest.records[q.id.uuidString.lowercased()])
            XCTAssertEqual(q.practiceLevel.number,entry.level)
            XCTAssertEqual(try XCTUnwrap(q.difficultyScore),entry.score,accuracy:0.000001)
        }
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
    func testFilterNarrowsALevelSurvivesNavigationAndResetsWithTheLevel() async throws {
        let model = AppModel(); model.demo = true; await model.connect()
        XCTAssertNil(model.error)
        let level: (PracticeLevel) -> [QuestionSummary] = { value in model.questions.filter { $0.practiceLevel == value } }
        XCTAssertGreaterThan(QuestionFilter.keyOptions(in:level(.level2)).count,1)
        XCTAssertGreaterThan(QuestionFilter.keyOptions(in:level(.level9)).count,1)
        XCTAssertGreaterThan(QuestionFilter.meterOptions(in:level(.level9)).count,1)
        model.selectedPracticeLevel = .level2
        let key = try XCTUnwrap(QuestionFilter.keyOptions(in:level(.level2)).first)
        model.practiceFilter.key = key
        let filtered = model.practiceFilter.apply(to:level(.level2))
        XCTAssertEqual(filtered.count,level(.level2).filter { $0.keySignature == key }.count)
        XCTAssertTrue(filtered.allSatisfy { $0.keySignature == key })
        XCTAssertEqual(filtered.compactMap(\.difficultyScore),filtered.compactMap(\.difficultyScore).sorted())
        let renderer = ImageRenderer(content:HomeView(model:model).frame(width:1180,height:1024)); renderer.scale = 2
        let attachment = XCTAttachment(image:try XCTUnwrap(renderer.uiImage)); attachment.name = "practice-filter"; attachment.lifetime = .keepAlways; add(attachment)
        model.navigate(.question); model.navigate(.home); model.selectedPracticeLevel = .level2
        XCTAssertEqual(model.practiceFilter.key,key)
        model.selectedPracticeLevel = .advanced
        XCTAssertEqual(model.practiceFilter,QuestionFilter())
        model.practiceFilter.meter = TimeSignature(numerator:12,denominator:8)
        model.selectedPracticeLevel = nil
        XCTAssertFalse(model.practiceFilter.isActive)
    }
    func testCompletedPracticeIsHiddenUntilEnabledAndSurvivesCatalogReload() async throws {
        let scope = "practice-bank-ui-" + UUID().uuidString
        let model = AppModel(demoScope:scope); model.demo = true
        await model.connect(); XCTAssertNil(model.error)
        let q = try XCTUnwrap(model.questions.first { $0.practiceLevel == .level4 })
        model.selectPracticeLevel(.level4)
        await model.choose(q.id,mode:.practice); await model.begin(); await model.start(); model.player.pause()
        await model.submit(); await model.savePracticeAssessment(completed:true)
        XCTAssertNil(model.error); XCTAssertTrue(model.completedPracticeQuestionIDs.contains(q.id))
        model.navigate(.practiceQuestions)
        let level = model.questions.filter { $0.practiceLevel == .level4 }
        XCTAssertFalse(model.practiceFilter.apply(to:level,completedQuestionIDs:model.completedPracticeQuestionIDs).contains { $0.id == q.id })
        model.practiceFilter.showCompleted = true
        XCTAssertTrue(model.practiceFilter.apply(to:level,completedQuestionIDs:model.completedPracticeQuestionIDs).contains { $0.id == q.id })
        await model.refreshLibrary(destination:.practiceQuestions)
        XCTAssertEqual(model.questions.first { $0.id == q.id }?.practiceCompleted,true)
        for size in [CGSize(width:1180,height:792),CGSize(width:744,height:1000)] {
            let renderer = ImageRenderer(content:HomeView(model:model).frame(width:size.width,height:size.height)); renderer.scale = 1
            let attachment = XCTAttachment(image:try XCTUnwrap(renderer.uiImage))
            attachment.name = "practice-bank-\(Int(size.width))"; attachment.lifetime = .keepAlways; add(attachment)
        }
        model.navigate(.practiceLevels); model.selectPracticeLevel(.level2)
        XCTAssertFalse(model.practiceFilter.showCompleted)
        XCTAssertEqual(model.practiceFilter.sortOrder,.ascending)
    }
    func testPracticeLevelsScreenAndImportedExamRestore() async throws {
        let model = AppModel(); model.demo = true; model.demoOutcome = "completed"; await model.connect()
        let manifest: PracticeDifficultyManifest = try Bundled.decode("practice-difficulty")
        XCTAssertNil(model.error); XCTAssertEqual(model.questions.count,1550)
        let renderer = ImageRenderer(content:PracticeLevelSelectionView(model:model).frame(width:1180,height:792)); renderer.scale = 2
        let attachment = XCTAttachment(image:try XCTUnwrap(renderer.uiImage)); attachment.name = "practice-level-selection"; attachment.lifetime = .keepAlways; add(attachment)
        let entry = ImageRenderer(content:PracticeEntryView(model:model).frame(width:1180,height:792)); entry.scale = 2
        let entryAttachment = XCTAttachment(image:try XCTUnwrap(entry.uiImage)); entryAttachment.name = "practice-entry-empty"; entryAttachment.lifetime = .keepAlways; add(entryAttachment)
        let summary = try XCTUnwrap(model.questions.first { $0.practiceLevel == .level2 && $0.keySignature.fifths != 0 })
        model.selectedPracticeLevel = .level2
        await model.choose(summary.id,mode:.practice); await model.begin()
        XCTAssertNil(model.error); XCTAssertTrue(model.prepared)
        let id = try XCTUnwrap(model.session?.id)
        await model.start(); model.player.pause(); await model.submit()
        XCTAssertNil(model.error); XCTAssertEqual(model.screen,.result)
        let restored = AppModel(); restored.demo = true; await restored.connect()
        await restored.open(try XCTUnwrap(restored.history.first { $0.id == id }))
        XCTAssertNil(restored.error); XCTAssertEqual(restored.selectedPracticeLevel,.level2)
        XCTAssertEqual(restored.selectedQuestion?.id,summary.id)
    }
}
