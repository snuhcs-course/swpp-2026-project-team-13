import XCTest
import Foundation
@testable import SORICore

final class StubProtocol:URLProtocol {
    static var handler:((URLRequest)throws->(Int,String,Data))?
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        do {
            let (status,mime,data)=try Self.handler!(request)
            let response=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":mime,"X-Request-ID":"test-request"])!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() { }
}
@MainActor final class HTTPContractTests:XCTestCase {
    var root:URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/sori-api") }
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
            else if path.hasSuffix("answers/") { name="answer-upload";status=201;XCTAssertTrue(request.value(forHTTPHeaderField:"Content-Type")!.contains("multipart/form-data; boundary=sori-")) }
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
        XCTAssertTrue(calls.contains("GET questions/?page=1&page_size=20"));XCTAssertTrue(calls.contains("PATCH me/"))
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
            "questions/?page=1&page_size=20",
            "questions/?page=1&page_size=20&collection=classical",
            "questions/?page=2&page_size=20&collection=classical",
            "questions/?page=2&page_size=20"
        ])
    }
    func test401IsSurfacedWithoutAutomaticRepeat() async throws {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[StubProtocol.self]
        let api=try HTTPExamAPI(base:URL(string:"https://api.example/api/v1/")!,token:"bad",session:URLSession(configuration:config))
        var calls=0;StubProtocol.handler={_ in calls+=1;return (401,"application/json",Data("{\"error\":{\"code\":\"AUTHENTICATION_REQUIRED\",\"message\":\"auth\",\"fields\":[],\"retry_after_ms\":null},\"request_id\":\"r1\"}".utf8))}
        defer {StubProtocol.handler=nil}
        do {_=try await api.profile();XCTFail("Expected 401")}catch {XCTAssertTrue(error.localizedDescription.contains("인증"))}
        XCTAssertEqual(calls,1)
    }
}
