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
            let data = try Data(contentsOf:resources.appendingPathComponent("excerpt-\(index+1)-v2-main.mxl"))
            let score = try MusicXMLParser.parseMXL(data,asset:q.scoreAssets.main,tempo:96)
            XCTAssertEqual(score.timeSignature,q.timeSignature)
            XCTAssertEqual(score.totalTicks,8*q.timeSignature.ticksPerMeasure)
            XCTAssertTrue(score.symbols.contains { $0.type == "16th" })
            XCTAssertTrue(score.symbols.contains { $0.tupletActual == 3 && $0.tupletNormal == 2 })
            for (a,b) in [(1,8),(1,2),(1,4),(3,4),(3,6),(5,6),(5,8),(7,8)] {
                let events = try score.segment(from:a,through:b)
                XCTAssertTrue(events.allSatisfy { $0.onset >= 0 && $0.onset+$0.duration <= (b-a+1)*score.ticksPerMeasure })
            }
            let scaleData = try Data(contentsOf:resources.appendingPathComponent("excerpt-\(index+1)-v2-scale.mxl"))
            let scale = try MusicXMLParser.parseMXL(scaleData,asset:q.scoreAssets.scale,tempo:96)
            XCTAssertEqual(scale.timeSignature,q.timeSignature)
            XCTAssertEqual(scale.events.compactMap(\.midi),[60,62,64,65,67,69,71,72,71,69,67,65,64,62,60])
            let png = try Data(contentsOf:resources.appendingPathComponent(q.sheetLayout.id+".pngdata"))
            XCTAssertEqual(png.sha256,q.sheetLayout.templateSha256)
        }
    }
    func testBadTripletDurationIsRejected() throws {
        for (index,q) in try catalog().enumerated() {
            let data = try Data(contentsOf:resources.appendingPathComponent("excerpt-\(index+1)-v2-main.mxl"))
            let score = try MusicXMLParser.parseMXL(data,asset:q.scoreAssets.main,tempo:96)
            let triplet = try XCTUnwrap(score.symbols.first { $0.tupletActual == 3 && $0.tupletNormal == 2 })
            let xml = String(decoding:try XCTUnwrap(MXLContainer.entries(data)["score.xml"]),as:UTF8.self)
            let duration = "<duration>\(triplet.duration)</duration>"
            let range = try XCTUnwrap(xml.range(of:duration),"문제 \(index+1)에 실제 셋잇단음표 길이가 있어야 합니다.")
            let broken = xml.replacingCharacters(in:range,with:"<duration>\(triplet.duration+1)</duration>")
            XCTAssertThrowsError(try MusicXMLParser.parseXML(Data(broken.utf8),measures:8,tempo:96),"문제 \(index+1)의 잘못된 셋잇단음표 길이를 거부해야 합니다.")
        }
    }
}
