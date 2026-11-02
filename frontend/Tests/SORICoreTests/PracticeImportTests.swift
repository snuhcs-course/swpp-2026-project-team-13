import XCTest
@testable import SORICore

final class PracticeImportTests: XCTestCase {
    private var resources: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("IPadApp/IPadApp/Resources") }
    private func questions(_ filename: String) throws -> [Question] {
        try ContractJSON.decoder().decode([Question].self,from:Data(contentsOf:resources.appendingPathComponent(filename+".json")))
    }
    func testLevelsPreserveOriginalIDsAndClassifyEveryPracticeQuestion() throws {
        let old = try questions("practice-catalog"), added = try questions("additional-practice-catalog")
        XCTAssertEqual(old.count,62); XCTAssertEqual(added.count,51)
        XCTAssertTrue(old.prefix(3).allSatisfy { $0.practiceLevel == .intermediate })
        XCTAssertTrue(old.dropFirst(3).allSatisfy { $0.practiceLevel == .advanced })
        let all = old + added
        XCTAssertEqual(Set(all.map(\.id)).count,113)
        XCTAssertEqual(all.filter { $0.practiceLevel == .beginner }.count,40)
        XCTAssertEqual(all.filter { $0.practiceLevel == .intermediate }.count,14)
        XCTAssertEqual(all.filter { $0.practiceLevel == .advanced }.count,59)
        XCTAssertEqual(added.filter { $0.title.contains("Pages") }.count,11)
        XCTAssertFalse(added.contains { $0.title.contains("Pages 06") })
        // Old saved attempts have no difficulty property and still decode/classify.
        for q in old.prefix(3) {
            let restored = try ContractJSON.decoder().decode(Question.self,from:ContractJSON.encoder().encode(q))
            XCTAssertNil(restored.difficulty); XCTAssertEqual(restored.practiceLevel,.intermediate)
        }
    }
    func testEveryImportedScoreAndScalePrepareAllExistingExamSegments() throws {
        for q in try questions("additional-practice-catalog") {
            try q.validate()
            let prefix = "practice-\(q.id.uuidString.lowercased())"
            let main = try MusicXMLParser.parseMXL(Data(contentsOf:resources.appendingPathComponent(prefix+"-main.mxl")),asset:q.scoreAssets.main)
            let scale = try MusicXMLParser.parseMXL(Data(contentsOf:resources.appendingPathComponent(prefix+"-scale.mxl")),asset:q.scoreAssets.scale)
            XCTAssertEqual(main.keySignature,q.keySignature); XCTAssertEqual(scale.keySignature,q.keySignature)
            XCTAssertEqual(main.timeSignature,q.timeSignature); XCTAssertEqual(scale.timeSignature,q.timeSignature)
            XCTAssertEqual(main.totalTicks,8*q.timeSignature.ticksPerMeasure)
            XCTAssertFalse(main.events.compactMap(\.midi).isEmpty)
            XCTAssertEqual(scale.events.compactMap(\.midi).count,15)
            let plan = PlaybackPlan.exam(meter:q.timeSignature,scaleMeasures:scale.measures)
            try plan.validate()
            for step in plan.steps {
                let events = try main.segment(from:step.fromMeasure,through:step.toMeasure)
                XCTAssertFalse(MIDIFile.withCountIn(events:events,totalTicks:(step.toMeasure-step.fromMeasure+1)*main.ticksPerMeasure,tempo:plan.tempoBpm,countIn:try XCTUnwrap(plan.countIn)).isEmpty)
            }
            XCTAssertEqual(try Data(contentsOf:resources.appendingPathComponent(q.sheetLayout.id+".pngdata")).sha256,q.sheetLayout.templateSha256)
        }
    }
    @MainActor func testLevelSelectionIncludesQuestionsFromLaterServerPages() async throws {
        let q = try questions("additional-practice-catalog")
        let summaries = q.map { QuestionSummary(id:$0.id,version:$0.version,title:$0.title,source:$0.source,keySignature:$0.keySignature,timeSignature:$0.timeSignature,measureCount:8,recommendedDurationSeconds:300,difficulty:$0.difficulty) }
        var calls = [Int]()
        let list = try await PracticeQuestionList.load { page in
            calls.append(page)
            if page == 1 { return QuestionPage(count:51,next:URL(string:"https://server/api/v1/questions/?page=2"),previous:nil,results:Array(summaries.prefix(11))) }
            return QuestionPage(count:51,next:nil,previous:nil,results:Array(summaries.dropFirst(11)))
        }
        XCTAssertEqual(calls,[1,2]); XCTAssertEqual(list.lastPage,2)
        XCTAssertEqual(list.questions.filter { $0.practiceLevel == .beginner }.count,40)
        XCTAssertEqual(list.questions.filter { $0.practiceLevel == .intermediate }.count,11)
    }
    @MainActor func testRepeatedPaginationStopsInsteadOfLoopingForever() async throws {
        let q = try questions("practice-catalog")[0]
        let summary = QuestionSummary(id:q.id,version:q.version,title:q.title,source:q.source,keySignature:q.keySignature,timeSignature:q.timeSignature,measureCount:8,recommendedDurationSeconds:300)
        var calls = 0
        do {
            _ = try await PracticeQuestionList.load { _ in
                calls += 1
                return QuestionPage(count:62,next:URL(string:"https://server/api/v1/questions/?page=2"),previous:nil,results:[summary])
            }
            XCTFail("Repeated pages must be rejected")
        } catch { XCTAssertEqual(calls,2) }
    }
}
