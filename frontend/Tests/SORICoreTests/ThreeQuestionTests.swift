import XCTest
@testable import SORICore

final class ThreeQuestionTests: XCTestCase {
    var resources: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("IPadApp/IPadApp/Resources") }
    func catalog() throws -> [Question] { try ContractJSON.decoder().decode([Question].self,from:Data(contentsOf:resources.appendingPathComponent("practice-catalog.json"))) }
    func testAllThreeActualProblemsPrepareWithCorrectMeterAndTriplets() throws {
        let questions = try catalog()
        XCTAssertEqual(questions.count,3)
        for (index,q) in questions.enumerated() {
            try q.validate()
            let data = try Data(contentsOf:resources.appendingPathComponent("excerpt-\(index+1)-main.mxl"))
            let score = try MusicXMLParser.parseMXL(data,asset:q.scoreAssets.main,tempo:96)
            XCTAssertEqual(score.timeSignature,q.timeSignature)
            XCTAssertEqual(score.totalTicks,8*q.timeSignature.ticksPerMeasure)
            XCTAssertTrue(score.symbols.contains { $0.type == "16th" })
            XCTAssertTrue(score.symbols.contains { $0.tupletActual == 3 && $0.tupletNormal == 2 })
            for (a,b) in [(1,8),(1,2),(1,4),(3,4),(3,6),(5,6),(5,8),(7,8)] {
                let events = try score.segment(from:a,through:b)
                XCTAssertTrue(events.allSatisfy { $0.onset >= 0 && $0.onset+$0.duration <= (b-a+1)*score.ticksPerMeasure })
            }
            let scaleData = try Data(contentsOf:resources.appendingPathComponent("excerpt-\(index+1)-scale.mxl"))
            let scale = try MusicXMLParser.parseMXL(scaleData,asset:q.scoreAssets.scale,tempo:96)
            XCTAssertEqual(scale.timeSignature,q.timeSignature)
            XCTAssertEqual(scale.events.compactMap(\.midi),[60,62,64,65,67,69,71,72])
            let png = try Data(contentsOf:resources.appendingPathComponent(q.sheetLayout.id+".pngdata"))
            XCTAssertEqual(png.sha256,q.sheetLayout.templateSha256)
        }
    }
    func testBadTripletDurationIsRejected() throws {
        let q = try catalog()[0]
        let data = try Data(contentsOf:resources.appendingPathComponent("excerpt-1-main.mxl"))
        let xml = String(decoding:try MXLContainer.entries(data)["score.xml"]!,as:UTF8.self)
        let broken = xml.replacingOccurrences(of:"<duration>160</duration>",with:"<duration>161</duration>")
        XCTAssertNotEqual(broken,xml)
        XCTAssertThrowsError(try MusicXMLParser.parseXML(Data(broken.utf8),measures:8,tempo:96))
    }
}
