import XCTest
import Foundation
@testable import SolfegeCore

final class StubProtocol:URLProtocol {
    static var handler:((URLRequest)throws->(Int,String?,Data))?
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        do {
            let (status,mime,data)=try Self.handler!(request)
            var headers = ["X-Request-ID":"test-request"]
            if let mime { headers["Content-Type"] = mime }
            let response=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers)!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() { }
}
@MainActor final class HTTPContractTests:XCTestCase {
    func testExamOfferUsesAuthenticatedReadAndDecodesContinuousScores() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let api = try HTTPExamAPI(base:URL(string:"https://api.sori.example/api/v1/")!,token:"test-token",session:URLSession(configuration:config))
        let offer = ExamOffer(id:UUID(),poolVersion:"question-pools-1",rating:ExamRatingState(),choices:[
            ExamChoice(category:"challenge",questionId:UUID(),questionVersion:1,difficultyScore:8,ratingDifference:1,reason:nil),
            ExamChoice(category:"matched",questionId:UUID(),questionVersion:1,difficultyScore:7,ratingDifference:0,reason:nil),
            ExamChoice(category:"easy",questionId:UUID(),questionVersion:1,difficultyScore:6,ratingDifference:-1,reason:nil)])
        let payload = try ContractJSON.encoder().encode(offer)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path,"/api/v1/exam/recommendations/")
            XCTAssertEqual(request.httpMethod,"GET"); XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer test-token")
            return (200,"application/json",payload)
        }
        defer { StubProtocol.handler = nil }
        let result = try await api.examRecommendations(); try result.validate()
        XCTAssertEqual(result,offer)
    }
    var root:URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/solfege-api") }
    func testAllThirteenOperationsUseCorrectMethodsPathsHeadersAndPayloads() async throws {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[StubProtocol.self]
        let api=try HTTPExamAPI(base:URL(string:"https://api.sori.example/api/v1/")!,token:"test-token",session:URLSession(configuration:config))
        let fixtureRoot=root
        let question:Question=try ContractJSON.decoder().decode(Question.self,from:Data(contentsOf:root.appendingPathComponent("examples/question.json")))
        let attempt=UUID(uuidString:"33333333-3333-4333-8333-333333333333")!,answer=UUID(uuidString:"44444444-4444-4444-8444-444444444444")!,key=UUID()
        var calls:[String]=[]
        StubProtocol.handler={ request in
            let path=request.url!.absoluteString.replacingOccurrences(of:"https://api.sori.example/api/v1/",with:"")
            let method=request.httpMethod!
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer test-token")
            XCTAssertEqual(request.cachePolicy,.reloadIgnoringLocalCacheData)
            if method == "POST" && !path.hasSuffix("start/") { XCTAssertNotNil(request.value(forHTTPHeaderField:"Idempotency-Key")) }
            if !path.contains("?") { XCTAssertTrue(path.hasSuffix("/")) }
            calls.append(method+" "+path)
            if path.contains("/scores/") {
                XCTAssertEqual(request.value(forHTTPHeaderField:"Accept"),"application/vnd.recordare.musicxml")
                return (200,"application/vnd.recordare.musicxml",try Data(contentsOf:fixtureRoot.appendingPathComponent("assets/practice-01-main.mxl")))
            }
            if path.hasSuffix("/image/") { return (200,"image/png",try Data(contentsOf:fixtureRoot.appendingPathComponent("assets/staff-8bars-v1.png"))) }
            let name:String,status:Int
            if path == "me/" { name="me";status=200 }
            else if path.hasPrefix("questions/?") { name="questions";status=200 }
            else if path.hasPrefix("questions/") { name="question";status=200 }
            else if path == "attempts/" { name="attempt-ready";status=201 }
            else if path.hasSuffix("start/") { name="attempt-started";status=200;XCTAssertNil(request.httpBody) }
            else if path.hasSuffix("answers/") { name="answer-upload";status=201;XCTAssertTrue(request.value(forHTTPHeaderField:"Content-Type")!.contains("multipart/form-data; boundary=solfege-")) }
            else if path.hasSuffix("submit/") || path.hasSuffix("grading-retries/") { name="grading-queued";status=202 }
            else if path.hasSuffix("result/") { name="grading-completed";status=200 }
            else { name="attempt-started";status=200 }
            XCTAssertEqual(request.value(forHTTPHeaderField:"Accept"),"application/json")
            return (status,"application/json",try Data(contentsOf:fixtureRoot.appendingPathComponent("examples/\(name).json")))
        }
        defer {StubProtocol.handler=nil}
        _=try await api.profile();_=try await api.updateGoal("college_entrance");_=try await api.questions(page:1)
        _=try await api.question(question.id);_=try await api.createAttempt(question:question,key:key)
        _=try await api.attempt(attempt);_=try await api.start(attempt)
        let png=try Data(contentsOf:root.appendingPathComponent("assets/staff-8bars-v1.png"))
        let uploaded=try await api.upload(attempt,png:png,clientId:UUID(),layout:question.sheetLayout.id,key:key)
        _=try await api.answerImage(uploaded);_=try await api.submit(attempt,answerId:answer,key:key)
        _=try await api.result(attempt);_=try await api.retryGrading(attempt,key:key)
        let mxl=try await api.asset(question.scoreAssets.main.url,authenticated:true,limit:1_048_576)
        XCTAssertEqual(mxl.sha256,question.scoreAssets.main.sha256);XCTAssertEqual(calls.count,13)
        XCTAssertTrue(calls.contains("GET questions/?page=1&page_size=50"));XCTAssertTrue(calls.contains("PATCH me/"))
    }
    func testClassicalFilterDoesNotChangePracticePagination() async throws {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[StubProtocol.self]
        let base=URL(string:"https://api.sori.example/api/v1/")!
        let api=try HTTPExamAPI(base:base,token:"test-token",session:URLSession(configuration:config))
        let response=try Data(contentsOf:root.appendingPathComponent("examples/questions.json"))
        var paths:[String]=[]
        StubProtocol.handler={ request in
            XCTAssertEqual(request.httpMethod,"GET")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Accept"),"application/json")
            paths.append(request.url!.absoluteString.replacingOccurrences(of:base.absoluteString,with:""))
            return (200,"application/json",response)
        }
        defer {StubProtocol.handler=nil}
        _=try await api.questions(page:1)
        _=try await api.classicalQuestions(page:1)
        _=try await api.classicalQuestions(page:2)
        _=try await api.questions(page:2)
        XCTAssertEqual(paths,[
            "questions/?page=1&page_size=50",
            "questions/?page=1&page_size=50&collection=classical",
            "questions/?page=2&page_size=50&collection=classical",
            "questions/?page=2&page_size=50"
        ])
    }
    func testRecommendedQuestionUsesItsOwnRouteAndDecodesAsQuestionDetail() async throws {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[StubProtocol.self]
        let base=URL(string:"https://api.sori.example/api/v1/")!
        let api=try HTTPExamAPI(base:base,token:"test-token",session:URLSession(configuration:config))
        let response=try Data(contentsOf:root.appendingPathComponent("examples/question.json"))
        var paths:[String]=[]
        StubProtocol.handler={ request in
            XCTAssertEqual(request.httpMethod,"GET")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer test-token")
            XCTAssertEqual(request.cachePolicy,.reloadIgnoringLocalCacheData)
            paths.append(request.url!.absoluteString.replacingOccurrences(of:base.absoluteString,with:""))
            return (200,"application/json",response)
        }
        defer {StubProtocol.handler=nil}
        let question=try await api.recommendedQuestion()
        XCTAssertEqual(paths,["questions/recommended/"])
        XCTAssertEqual(question,try ContractJSON.decoder().decode(Question.self,from:response))
    }
    func test401IsSurfacedWithoutAutomaticRepeat() async throws {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[StubProtocol.self]
        let api=try HTTPExamAPI(base:URL(string:"https://api.example/api/v1/")!,token:"bad",session:URLSession(configuration:config))
        var calls=0;StubProtocol.handler={_ in calls+=1;return (401,"application/json",Data("{\"error\":{\"code\":\"AUTHENTICATION_REQUIRED\",\"message\":\"auth\",\"fields\":[],\"retry_after_ms\":null},\"request_id\":\"r1\"}".utf8))}
        defer {StubProtocol.handler=nil}
        do {_=try await api.profile();XCTFail("Expected 401")}catch {XCTAssertTrue(error.localizedDescription.contains("인증"))}
        XCTAssertEqual(calls,1)
    }
    func testPracticeUsesExplicitModeAndSelfAssessmentWithoutGradingRetries() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let api = try HTTPExamAPI(base:URL(string:"https://api.sori.example/api/v1/")!,token:"test-token",session:URLSession(configuration:config))
        let question = try ContractJSON.decoder().decode(Question.self,from:Data(contentsOf:root.appendingPathComponent("examples/question.json")))
        var attemptObject = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("examples/attempt-ready.json"))) as? [String:Any])
        attemptObject["mode"] = "practice"; attemptObject["grading_mode"] = "self"
        let attemptData = try JSONSerialization.data(withJSONObject:attemptObject)
        let pending = try Data(contentsOf:root.appendingPathComponent("examples/practice-assessment-pending.json"))
        let completed = try Data(contentsOf:root.appendingPathComponent("examples/practice-assessment-completed.json"))
        let attemptId = UUID(uuidString:"33333333-3333-4333-8333-333333333333")!
        let answerId = UUID(uuidString:"44444444-4444-4444-8444-444444444444")!
        var calls: [String] = []
        func body(_ request: URLRequest) throws -> [String:Any] {
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating:0,count:4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer,maxLength:4096)
                    if count <= 0 { break }
                    bytes.append(contentsOf:buffer.prefix(count))
                }
            }
            return try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        }
        StubProtocol.handler = { request in
            // URL.path may omit the trailing slash on Apple platforms. Keep the
            // serialized request path so the mock checks the actual API contract.
            let url = try XCTUnwrap(request.url)
            let path = try XCTUnwrap(URLComponents(url:url,resolvingAgainstBaseURL:false)).percentEncodedPath
            let method = try XCTUnwrap(request.httpMethod)
            calls.append(method + " " + path)
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer test-token")
            if method != "GET" { XCTAssertNotNil(request.value(forHTTPHeaderField:"Idempotency-Key")) }
            if path == "/api/v1/attempts/" {
                XCTAssertEqual(try body(request)["mode"] as? String,"practice")
                return (201,"application/json",attemptData)
            }
            if path.hasSuffix("/self-assessment/") {
                XCTAssertEqual(method,"PUT")
                let payload = try body(request)
                XCTAssertEqual(payload["expected_revision"] as? Int,0)
                XCTAssertEqual(payload["completed"] as? Bool,true)
                XCTAssertEqual(Set(payload.keys),Set(["expected_revision","errors","completed"]))
                return (200,"application/json",completed)
            }
            if path.hasSuffix("/submit/") {
                XCTAssertEqual(try body(request)["answer_id"] as? String,answerId.uuidString.lowercased())
                return (200,"application/json",pending)
            }
            if path.hasSuffix("/result/") {
                XCTAssertEqual(method,"GET")
                return (200,"application/json",pending)
            }
            XCTFail("Unexpected Practice request: \(method) \(url.absoluteString)")
            throw URLError(.unsupportedURL)
        }
        defer { StubProtocol.handler = nil }
        let attempt = try await api.createAttempt(question:question,mode:.practice,key:UUID())
        XCTAssertEqual(attempt.studyMode,.practice)
        let review = try await api.submitPractice(attemptId,answerId:answerId,key:UUID())
        XCTAssertEqual(review.status,"pending")
        _ = try await api.practiceAssessment(attemptId)
        let saved = try await api.saveSelfAssessment(attemptId,request:SelfAssessmentWrite(expectedRevision:0,errors:[MeasureError(measure:3,types:["pitch","rhythm"])],completed:true),key:UUID())
        XCTAssertEqual(saved.revision,1)
        XCTAssertEqual(saved.errors,[MeasureError(measure:3,types:["pitch","rhythm"])])
        let prefix = "/api/v1/attempts/\(attemptId.uuidString.lowercased())/"
        XCTAssertEqual(calls,["POST /api/v1/attempts/", "POST " + prefix + "submit/",
                              "GET " + prefix + "result/", "PUT " + prefix + "self-assessment/"])
    }
}
