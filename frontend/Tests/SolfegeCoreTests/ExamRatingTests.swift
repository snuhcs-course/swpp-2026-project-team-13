import XCTest
@testable import SolfegeCore

final class ExamRatingTests: XCTestCase {
    private var resources: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("IPadApp/IPadApp/Resources") }
    private struct Vectors: Decodable {
        struct Row: Decodable {
            var rating: Double; var completed: Int; var difficulty: Double; var grade: Int
            var after: Double; var delta: Double; var expectedScore: Double
        }
        var vectors: [Row]
    }
    func testServerAndDemoNumericalParityAcrossAllScaleBoundaries() throws {
        let file = resources.appendingPathComponent("exam-rating-vectors.json")
        let data = try ContractJSON.decoder().decode(Vectors.self,from:Data(contentsOf:file))
        for row in data.vectors {
            let value = try ExamRatingModel.update(ExamRatingState(value:row.rating,completed:row.completed),
                difficulty:row.difficulty,grade:row.grade,difficultyVersion:"practice-difficulty-2",poolVersion:"question-pools-1")
            XCTAssertEqual(value.after,row.after,accuracy:0.000000001)
            XCTAssertEqual(value.delta,row.delta,accuracy:0.000000001)
            XCTAssertEqual(value.expectedScore,row.expectedScore,accuracy:0.000000001)
        }
    }
    func testSameDifficultyMeansEightyAndZeroStillLowersRating() throws {
        for score in [7.0,8.5,11,20,40,60,80,120] {
            XCTAssertEqual(ExamRatingModel.expected(score,score),0.8,accuracy:0.00000001)
            let value = try ExamRatingModel.update(ExamRatingState(value:score),difficulty:score,grade:80,
                difficultyVersion:"practice-difficulty-2",poolVersion:"question-pools-1")
            XCTAssertEqual(value.delta,0,accuracy:0.00000001)
        }
        let zero = try ExamRatingModel.update(ExamRatingState(),difficulty:7,grade:0,
            difficultyVersion:"practice-difficulty-2",poolVersion:"question-pools-1")
        XCTAssertLessThan(zero.delta,0)
        XCTAssertThrowsError(try ExamRatingModel.update(ExamRatingState(),difficulty:7,grade:101,
            difficultyVersion:"practice-difficulty-2",poolVersion:"question-pools-1"))
    }
    func testPartitionIsCompleteAndDisjointWithoutChangingQuestionVersions() throws {
        let pool = try ContractJSON.decoder().decode(QuestionPoolManifest.self,from:Data(contentsOf:resources.appendingPathComponent("question-pools.json")))
        let difficulty = try ContractJSON.decoder().decode(PracticeDifficultyManifest.self,from:Data(contentsOf:resources.appendingPathComponent("practice-difficulty.json")))
        XCTAssertEqual(Set(pool.records.keys),Set(difficulty.records.keys))
        XCTAssertEqual(pool.records.values.filter { $0.pool == "exam" }.count,387)
        XCTAssertEqual(pool.records.values.filter { $0.pool == "practice" }.count,1550)
        var families: [String:Set<String>] = [:]
        for entry in pool.records.values { families[entry.family,default:[]].insert(entry.pool) }
        XCTAssertTrue(families.values.allSatisfy { $0.count == 1 })
    }
    func testOfferValidatesDirectionalScoresAndUnavailableSlots() throws {
        let offer = ExamOffer(id:UUID(),poolVersion:"question-pools-1",rating:ExamRatingState(),choices:[
            ExamChoice(category:"challenge",questionId:UUID(),questionVersion:1,difficultyScore:8,ratingDifference:1,reason:nil),
            ExamChoice(category:"matched",questionId:UUID(),questionVersion:1,difficultyScore:7,ratingDifference:0,reason:nil),
            ExamChoice(category:"easy",questionId:nil,questionVersion:nil,difficultyScore:nil,ratingDifference:nil,reason:"no_unseen_question")])
        try offer.validate()
        var bad = offer; bad.choices[0].difficultyScore = 6; bad.choices[0].ratingDifference = -1
        XCTAssertThrowsError(try bad.validate())
        let roundtrip = try ContractJSON.decoder().decode(ExamOffer.self,from:ContractJSON.encoder().encode(offer))
        XCTAssertEqual(roundtrip,offer)
    }
    func testActiveExamResponseCannotContainAnotherChoice() throws {
        let id = UUID()
        var offer = ExamOffer(id:id,poolVersion:"question-pools-1",rating:ExamRatingState(),choices:[],activeAttemptId:id)
        try offer.validate()
        let decoded = try ContractJSON.decoder().decode(ExamOffer.self,from:ContractJSON.encoder().encode(offer))
        XCTAssertEqual(decoded.activeAttemptId,id)
        offer.choices = [ExamChoice(category:"matched",questionId:UUID(),questionVersion:1,difficultyScore:7,ratingDifference:0,reason:nil)]
        XCTAssertThrowsError(try offer.validate())
    }
}
