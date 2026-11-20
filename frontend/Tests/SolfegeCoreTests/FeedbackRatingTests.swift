import XCTest
@testable import SolfegeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor final class FeedbackRatingTests: XCTestCase {
    func testRatingWritesTheExactGradingFeedbackIdentity() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let api = try HTTPExamAPI(base:URL(string:"https://api.sori.example/api/v1/")!,token:"test-token",session:URLSession(configuration:config))
        let attempt = UUID(), job = UUID()
        let saved = FeedbackRatingState(enabled:true,feedbackId:"digest",rating:FeedbackRatingEntry(stars:4,reason:"구체적이에요",updatedAt:Date(timeIntervalSince1970:0)))
        let bytes = try ContractJSON.encoder().encode(saved)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod,"PUT")
            XCTAssertEqual(request.url?.absoluteString,"https://api.sori.example/api/v1/attempts/\(attempt.uuidString.lowercased())/feedback-rating/")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer test-token")
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating:0,count:1024)
                while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count); if n <= 0 { break }; data.append(contentsOf:buffer.prefix(n)) }
            }
            let body = try JSONSerialization.jsonObject(with:data) as! [String:Any]
            XCTAssertEqual(body["job_id"] as? String,job.uuidString.uppercased())
            XCTAssertEqual(body["feedback_id"] as? String,"digest")
            XCTAssertEqual(body["stars"] as? Int,4)
            XCTAssertEqual(body["reason"] as? String,"구체적이에요")
            return (200,"application/json",bytes)
        }
        defer { StubProtocol.handler = nil }
        let result = try await api.saveFeedbackRating(attempt,request:FeedbackRatingWrite(jobId:job,feedbackId:"digest",stars:4,reason:"구체적이에요"))
        XCTAssertEqual(result,saved)
    }

    func testOlderResultsRemainReadableWithoutTheSurvey() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf:root.appendingPathComponent("docs/solfege-api/examples/grading-completed.json"))
        let grading = try ContractJSON.decoder().decode(Grading.self,from:data)
        XCTAssertNil(grading.feedbackRating)
    }

    func testReferenceGlyphValidationRejectsUnsupportedOrNonfinitePaths() throws {
        let box = BBox(x:0.1,y:0.2,width:0.01,height:0.01)
        let glyph = ReferenceGlyph(bbox:box,commands:[ReferenceGlyphCommand(op:"M",values:[0.1,0.2]),ReferenceGlyphCommand(op:"Z",values:[])])
        XCTAssertTrue(ReferenceAnnotation(id:"ai-1",measure:1,style:"glyph",message:"오류",bbox:box,glyphs:[glyph]).isValid)
        XCTAssertFalse(ReferenceGlyphCommand(op:"A",values:[]).isValid)
        XCTAssertFalse(ReferenceGlyphCommand(op:"L",values:[Double.nan,0.2]).isValid)
        XCTAssertFalse(ReferenceAnnotation(id:"ai-1",measure:9,style:"measure",message:"오류",bbox:box,glyphs:[]).isValid)
        XCTAssertFalse(ReferenceAnnotation(id:"ai-1",measure:1,style:"glyph",message:"오류",bbox:box,glyphs:[]).isValid)
    }
}
