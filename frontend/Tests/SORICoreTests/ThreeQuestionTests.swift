import XCTest
@testable import SORICore

final class ThreeQuestionTests: XCTestCase {
    var resources: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("IPadApp/IPadApp/Resources") }
    func catalog() throws -> [Question] { try ContractJSON.decoder().decode([Question].self,from:Data(contentsOf:resources.appendingPathComponent("practice-catalog.json"))) }
    func testAllThreeActualProblemsPrepareWithCorrectMeterAndTriplets() throws {
        let questions = try catalog()
        XCTAssertEqual(questions.count,62)
        for (index,q) in questions.prefix(3).enumerated() {
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
        for (index,q) in try catalog().prefix(3).enumerated() {
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
    func testEntireCatalogParsesAndPreparesEveryExamSegment() throws {
        let questions = try catalog()
        XCTAssertEqual(questions.count,62)
        XCTAssertEqual(Set(questions.map(\.id)).count,62)
        var meters = Set<String>(), sawThirtySecond = false, sawHighNote = false
        for (index,q) in questions.enumerated() {
            try q.validate()
            let main = try MusicXMLParser.parseMXL(Data(contentsOf:resources.appendingPathComponent("excerpt-\(index+1)-v2-main.mxl")),asset:q.scoreAssets.main)
            let scale = try MusicXMLParser.parseMXL(Data(contentsOf:resources.appendingPathComponent("excerpt-\(index+1)-v2-scale.mxl")),asset:q.scoreAssets.scale)
            XCTAssertEqual(main.timeSignature,q.timeSignature)
            XCTAssertEqual(scale.timeSignature,q.timeSignature)
            XCTAssertEqual(main.totalTicks,8*q.timeSignature.ticksPerMeasure)
            XCTAssertEqual(scale.events.compactMap(\.midi),[60,62,64,65,67,69,71,72,71,69,67,65,64,62,60])
            let plan = PlaybackPlan.exam(meter:q.timeSignature,scaleMeasures:scale.measures)
            try plan.validate()
            XCTAssertEqual(plan.countIn?.totalTicks,q.timeSignature.ticksPerMeasure)
            for step in plan.steps {
                let events = try main.segment(from:step.fromMeasure,through:step.toMeasure)
                let ticks = (step.toMeasure-step.fromMeasure+1)*main.ticksPerMeasure
                XCTAssertTrue(events.allSatisfy { $0.onset >= 0 && $0.duration > 0 && $0.onset+$0.duration <= ticks })
                XCTAssertFalse(MIDIFile.withCountIn(events:events,totalTicks:ticks,tempo:plan.tempoBpm,countIn:try XCTUnwrap(plan.countIn)).isEmpty)
            }
            let png = try Data(contentsOf:resources.appendingPathComponent(q.sheetLayout.id+".pngdata"))
            XCTAssertEqual(png.sha256,q.sheetLayout.templateSha256)
            meters.insert("\(q.timeSignature.numerator)/\(q.timeSignature.denominator)")
            sawThirtySecond = sawThirtySecond || main.symbols.contains { $0.type == "32nd" }
            sawHighNote = sawHighNote || main.events.contains { ($0.midi ?? 0) > 84 }
        }
        XCTAssertEqual(meters,["2/4","3/4","4/4","6/8","7/8","9/8","12/8"])
        XCTAssertTrue(sawThirtySecond); XCTAssertTrue(sawHighNote)
    }
}
