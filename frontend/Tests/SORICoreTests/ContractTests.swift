import XCTest
@testable import SORICore

final class ContractTests: XCTestCase {
    var root: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/sori-api") }
    func fixture<T:Decodable>(_ name:String) throws -> T { try ContractJSON.decoder().decode(T.self,from:Data(contentsOf:root.appendingPathComponent("examples/\(name).json"))) }
    func score(_ kind:String) throws -> MusicScore {
        let q:Question = try fixture("question")
        return try MusicXMLParser.parseMXL(Data(contentsOf:root.appendingPathComponent("assets/practice-01-\(kind).mxl")),asset:kind == "main" ? q.scoreAssets.main : q.scoreAssets.scale,tempo:96)
    }
    func xml() throws -> String { String(data:try MXLContainer.entries(Data(contentsOf:root.appendingPathComponent("assets/practice-01-main.mxl")))["score.xml"]!,encoding:.utf8)! }
    func testAllResponseFixturesDecode() throws {
        let _:UserProfile = try fixture("me"); let _:QuestionPage = try fixture("questions")
        let q:Question = try fixture("question"); try q.validate()
        for name in ["attempt-ready","attempt-started","attempt-resumed","attempt-submitted"] { let a:Attempt = try fixture(name); try a.playbackPlan.validate() }
        let _:Answer = try fixture("answer-upload")
        for name in ["grading-queued","grading-processing","grading-completed","grading-needs-review","grading-failed","grading-retry"] { let _:Grading = try fixture(name) }
        let _:ErrorEnvelope = try fixture("error-image-dimensions")
    }
    func testUnknownServerEnumRemainsReadable() throws {
        let data=try Data(contentsOf:root.appendingPathComponent("examples/attempt-ready.json"))
        let text=String(decoding:data,as:UTF8.self).replacingOccurrences(of:"\"ready\"",with:"\"future_state\"")
        XCTAssertEqual(try ContractJSON.decoder().decode(Attempt.self,from:Data(text.utf8)).status,"future_state")
    }
    func testFractionalAndWholeSecondDates() throws {
        struct Value:Decodable {var date:Date}
        for value in ["2026-10-23T06:00:00Z","2026-10-23T06:00:00.123456Z","2026-10-23T15:00:00+09:00"] {
            let v=try ContractJSON.decoder().decode(Value.self,from:Data("{\"date\":\"\(value)\"}".utf8)); XCTAssertGreaterThan(v.date.timeIntervalSince1970,0)
        }
    }
    func testDecodeIgnoresExtraFields() throws { let _:UserProfile=try ContractJSON.decoder().decode(UserProfile.self,from:Data("{\"id\":\"11111111-1111-4111-8111-111111111111\",\"display_name\":\"x\",\"learning_goal\":\"other\",\"future\":true}".utf8)) }
    func testNonCompletedScoresAreNilAndZeroIsARealScore() throws {
        for name in ["grading-queued","grading-processing","grading-needs-review","grading-failed"] { let g:Grading=try fixture(name); XCTAssertNil(g.score); XCTAssertNil(g.pitchAccuracy); XCTAssertNil(g.rhythmAccuracy) }
        var g:Grading=try fixture("grading-completed");g.score=0
        let decoded=try ContractJSON.decoder().decode(Grading.self,from:ContractJSON.encoder().encode(g)); XCTAssertEqual(decoded.score,0)
    }
    func testMainAndScaleMatchEveryExpectedEvent() throws {
        struct Fraction:Decodable {var numerator:Int;var denominator:Int;var ticks:Int{numerator*480/denominator}}
        struct Expected:Decodable {var midi:Int?;var onset:Fraction;var duration:Fraction}
        struct File:Decodable {var main:[Expected];var scale:[Expected];var boundaryCases:[String:[Expected]]}
        let file=try ContractJSON.decoder().decode(File.self,from:Data(contentsOf:root.appendingPathComponent("assets/practice-01.expected-events.json")))
        for (kind,expected) in [("main",file.main),("scale",file.scale)] {
            let actual=try score(kind).events
            XCTAssertEqual(actual,expected.map{MusicEvent(midi:$0.midi,onset:$0.onset.ticks,duration:$0.duration.ticks)})
        }
        for (key,range) in [("measures_1_4",(1,4)),("measures_5_6",(5,6))] {
            let expected=try XCTUnwrap(file.boundaryCases[key])
            XCTAssertEqual(try score("main").segment(from:range.0,through:range.1),expected.map{MusicEvent(midi:$0.midi,onset:$0.onset.ticks,duration:$0.duration.ticks)})
        }
    }
    func testTieClipsAtBothBoundaries() throws {
        let score=try score("main")
        XCTAssertTrue(score.events.contains(MusicEvent(midi:67,onset:15*480,duration:2*480)))
        XCTAssertEqual(try score.segment(from:1,through:4).last,MusicEvent(midi:67,onset:15*480,duration:480))
        XCTAssertEqual(try score.segment(from:5,through:6).first,MusicEvent(midi:67,onset:0,duration:480))
    }
    func testLeadingSilenceSurvivesSegment() throws {
        let events=try score("main").segment(from:7,through:8)
        XCTAssertEqual(events.first,MusicEvent(midi:nil,onset:0,duration:960))
        XCTAssertEqual(events.first(where:{$0.midi != nil})?.onset,960)
    }
    func testRejectsTamperedAssetBeforeParsing() throws {
        let q:Question=try fixture("question"); var data=try Data(contentsOf:root.appendingPathComponent("assets/practice-01-main.mxl"));data[100]^=1
        XCTAssertThrowsError(try MusicXMLParser.parseMXL(data,asset:q.scoreAssets.main,tempo:96))
    }
    func testRejectsCorruptZipCRC() throws { var data=try Data(contentsOf:root.appendingPathComponent("assets/practice-01-main.mxl"));data[50]^=1;XCTAssertThrowsError(try MXLContainer.entries(data)) }
    func testRejectsOversizedAndTruncatedZip() { XCTAssertThrowsError(try MXLContainer.entries(Data(repeating:0,count:1_048_577)));XCTAssertThrowsError(try MXLContainer.entries(Data([0x50,0x4b]))) }
    func testRejectsDTDEntities() { XCTAssertThrowsError(try MusicXMLParser.parseXML(Data("<!DOCTYPE score [<!ENTITY a SYSTEM 'file:///etc/passwd'>]><score-partwise/>".utf8),measures:8,tempo:96)) }
    func testRejectsTempoMismatch() throws { XCTAssertThrowsError(try MusicXMLParser.parseXML(Data(xml().utf8),measures:8,tempo:97)) }
    func testRejectsChordAndPolyphony() throws { let value=try xml().replacingOccurrences(of:"<pitch>",with:"<chord/><pitch>");XCTAssertThrowsError(try MusicXMLParser.parseXML(Data(value.utf8),measures:8,tempo:96)) }
    func testRejectsNonFourBeatMeasure() throws { let value=try xml().replacingOccurrences(of:"<duration>480</duration>",with:"<duration>240</duration>");XCTAssertThrowsError(try MusicXMLParser.parseXML(Data(value.utf8),measures:8,tempo:96)) }
    func testRejectsUnfinishedTie() throws { let value=try xml().replacingOccurrences(of:"<tie type=\"stop\"",with:"<tie type=\"start\"");XCTAssertThrowsError(try MusicXMLParser.parseXML(Data(value.utf8),measures:8,tempo:96)) }
    func testRejectsWrongMeasureCountAndOutsideRange() throws {
        XCTAssertThrowsError(try MusicXMLParser.parseXML(Data(xml().utf8),measures:2,tempo:96))
        XCTAssertThrowsError(try score("main").segment(from:0,through:2))
    }
    func testMIDIHasTempoAnd480PPQ() {
        let midi=[UInt8](MIDIFile.make(events:[MusicEvent(midi:60,onset:0,duration:480)],totalTicks:1920,tempo:96))
        XCTAssertEqual(Array(midi.prefix(14)),[0x4d,0x54,0x68,0x64,0,0,0,6,0,0,0,1,1,0xe0])
        XCTAssertEqual(Array(midi[22..<29]),[0,0xff,0x51,3,0x09,0x89,0x68])
        XCTAssertEqual(Array(midi.suffix(5)),[0x8b,0x20,0xff,0x2f,0]) // 1440 ticks of trailing silence
    }
    func testMIDIVariableLengthEncoding() { XCTAssertEqual(MIDIFile.variable(0),[0]);XCTAssertEqual(MIDIFile.variable(480),[0x83,0x60]);XCTAssertEqual(MIDIFile.variable(16384),[0x81,0x80,0]) }
    func testMonotonicAdvisoryClockNeverResetsOrGoesNegative() throws {
        let a:Attempt=try fixture("attempt-started");var clock=AdvisoryClock();clock.sync(a,uptime:100)
        XCTAssertEqual(clock.remaining(uptime:110),290);XCTAssertEqual(clock.remaining(uptime:500),0)
        XCTAssertEqual(clock.remaining(uptime:99),300)
    }
    func testNormalizedAnnotationBounds() { XCTAssertTrue(BBox(x:0.47,y:0.18,width:0.05,height:0.06).isValid);XCTAssertFalse(BBox(x:0.99,y:0,width:0.02,height:0.1).isValid);XCTAssertFalse(BBox(x:0,y:0,width:0,height:0.1).isValid) }
    @MainActor func testMultipartUsesExactPNGAndRequiredMetadata() throws {
        let id=UUID();let bytes=Data([137,80,78,71,0,255]);let body=try HTTPExamAPI.multipart(png:bytes,clientId:id,layout:"staff-8bars-v1",boundary:"boundary")
        XCTAssertNotNil(body.range(of:bytes));let text=String(decoding:body,as:UTF8.self)
        for field in ["image","client_answer_id","answer_format_version","sheet_layout_id"]{XCTAssertTrue(text.contains("name=\"\(field)\""))}
        XCTAssertTrue(text.contains(id.uuidString.lowercased()));XCTAssertTrue(text.hasSuffix("\r\n--boundary--\r\n"))
    }
    @MainActor func testCrossOriginBearerAndCredentialsAreRejected() throws {
        let api=try HTTPExamAPI(base:URL(string:"https://api.example/api/v1/")!,token:"secret")
        XCTAssertThrowsError(try api.request(URL(string:"https://evil.example/api/v1/")!))
        XCTAssertThrowsError(try api.request(URL(string:"https://api.example:444/api/v1/")!))
        let publicRequest=try api.request(URL(string:"https://assets.example/sheet.png")!,authenticated:false,accept:"image/png")
        XCTAssertNil(publicRequest.value(forHTTPHeaderField:"Authorization"))
        XCTAssertNil(Origin(URL(string:"https://user:pass@api.example/api/v1/")!))
        XCTAssertEqual(Origin(URL(string:"https://api.example/")!),Origin(URL(string:"https://api.example:443/")!))
    }
    @MainActor func testStartAndRetrySendNoBodyAndPathKeepsSlash() throws {
        let api=try HTTPExamAPI(base:URL(string:"https://api.example/api/v1/")!,token:"token")
        let r=try api.request(api.endpoint("attempts/x/start/"),method:"POST")
        XCTAssertEqual(r.url?.path,"/api/v1/attempts/x/start");XCTAssertTrue(r.url!.absoluteString.hasSuffix("/"));XCTAssertNil(r.httpBody)
    }
    @MainActor func testRetryPolicyStopsOn401AndRespectsRetryAfter() {
        XCTAssertNil(HTTPExamAPI.retryPolicy(SORIError.server(401,nil,retryAfter:nil),trial:0))
        XCTAssertNil(HTTPExamAPI.retryPolicy(SORIError.server(422,nil,retryAfter:nil),trial:0))
        XCTAssertGreaterThanOrEqual(HTTPExamAPI.retryPolicy(SORIError.server(429,nil,retryAfter:12),trial:0) ?? 0,12)
        XCTAssertEqual(HTTPExamAPI.retryDelay("10",now:Date()),10)
    }
    func testPlaybackPlanRejectsUnsupportedProfileAndManualReplay() throws { var a:Attempt=try fixture("attempt-ready");a.playbackPlan.allowManualReplay=true;XCTAssertThrowsError(try a.playbackPlan.validate()) }
}
