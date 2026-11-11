import XCTest
@testable import SolfegeCore

final class PracticeBankTests: XCTestCase {
    private var resources: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("IPadApp/IPadApp/Resources") }
    private func decode<T:Decodable>(_ name: String) throws -> T {
        try ContractJSON.decoder().decode(T.self,from:Data(contentsOf:resources.appendingPathComponent(name+".json")))
    }
    func testEveryNewQuestionUsesTheProductionParserAndActualScoreCutoffs() throws {
        let manifest: PracticeDifficultyManifest = try decode("practice-difficulty")
        try manifest.validate()
        let questions: [Question] = try decode("practice-bank-catalog")
        XCTAssertGreaterThan(questions.count,1000)
        XCTAssertEqual(PracticeLevel.allCases.map(\.number),Array(1...9))
        for q in questions {
            do {
                try q.validate()
                let entry = try XCTUnwrap(manifest.records[q.id.uuidString.lowercased()])
                let annotated = manifest.annotating(q)
                XCTAssertEqual(annotated.practiceLevel.number,entry.level)
                XCTAssertEqual(try XCTUnwrap(annotated.difficultyScore),entry.score,accuracy:0.00000001)
                XCTAssertEqual(annotated.practiceLevel.number,1+manifest.cutoffs.filter { entry.score >= $0 }.count)
                let prefix = "practice-\(q.id.uuidString.lowercased())"
                let main = try MusicXMLParser.parseMXL(Data(contentsOf:resources.appendingPathComponent(prefix+"-main.mxl")),asset:q.scoreAssets.main)
                let scale = try MusicXMLParser.parseMXL(Data(contentsOf:resources.appendingPathComponent(prefix+"-scale.mxl")),asset:q.scoreAssets.scale)
                XCTAssertEqual(main.timeSignature,q.timeSignature);XCTAssertEqual(main.keySignature,q.keySignature)
                XCTAssertEqual(scale.keySignature,q.keySignature)
                XCTAssertEqual(main.totalTicks,8*q.timeSignature.ticksPerMeasure)
                XCTAssertEqual(scale.events.compactMap(\.midi).count,15)
                let plan = PlaybackPlan.exam(meter:q.timeSignature,setting:q.tempo,scaleMeasures:scale.measures)
                try plan.validate()
            } catch {
                // Check the rest of the bank too, and identify every bad asset
                // in a single CI run instead of stopping at the first question.
                XCTFail("Question \(q.id.uuidString) (\(q.title)): \(error)")
            }
        }
    }
    func testNumericClassificationOverridesLegacyLabelsAndNewFieldsRoundTrip() throws {
        var q: Question = try decode("question")
        q.difficulty="beginner";q.practiceLevelNumber=8;q.difficultyScore=70.123;q.difficultyVersion="practice-difficulty-1"
        XCTAssertEqual(q.practiceLevel,.level8)
        let restored=try ContractJSON.decoder().decode(Question.self,from:ContractJSON.encoder().encode(q))
        XCTAssertEqual(restored,q)
        let data=try ContractJSON.encoder().encode(q)
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(object["practice_level"] as? Int,8)
    }
}
