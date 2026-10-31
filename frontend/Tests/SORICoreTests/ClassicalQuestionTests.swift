import XCTest
@testable import SORICore

final class ClassicalQuestionTests: XCTestCase {
    var resources: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("IPadApp/IPadApp/Resources") }
    func catalog() throws -> [Question] { try ContractJSON.decoder().decode([Question].self,from:Data(contentsOf:resources.appendingPathComponent("classical-catalog.json"))) }

    func testEveryClassicalQuestionParsesWithItsOwnKeyAndAllExamSegments() throws {
        let questions = try catalog()
        XCTAssertEqual(questions.count,11)
        XCTAssertEqual(Set(questions.compactMap(\.composer)).count,7)
        for q in questions {
            try q.validate()
            let prefix = "classical-\(q.id.uuidString.lowercased())"
            let main = try MusicXMLParser.parseMXL(Data(contentsOf:resources.appendingPathComponent(prefix+"-main.mxl")),asset:q.scoreAssets.main)
            let scale = try MusicXMLParser.parseMXL(Data(contentsOf:resources.appendingPathComponent(prefix+"-scale.mxl")),asset:q.scoreAssets.scale)
            XCTAssertEqual(main.keySignature,q.keySignature); XCTAssertEqual(scale.keySignature,q.keySignature)
            XCTAssertEqual(main.timeSignature,q.timeSignature); XCTAssertEqual(scale.timeSignature,q.timeSignature)
            XCTAssertEqual(main.totalTicks,8*q.timeSignature.ticksPerMeasure)
            XCTAssertEqual(scale.events.compactMap(\.midi).count,15)
            let plan = PlaybackPlan.exam(meter:q.timeSignature,scaleMeasures:scale.measures)
            try plan.validate()
            for step in plan.steps {
                let events = try main.segment(from:step.fromMeasure,through:step.toMeasure)
                let ticks = (step.toMeasure-step.fromMeasure+1)*main.ticksPerMeasure
                XCTAssertTrue(events.allSatisfy { $0.onset >= 0 && $0.duration > 0 && $0.onset+$0.duration <= ticks })
            }
            XCTAssertEqual(try Data(contentsOf:resources.appendingPathComponent(q.sheetLayout.id+".pngdata")).sha256,q.sheetLayout.templateSha256)
            var wrong = q
            wrong.sheetLayout.id = "staff-8bars-4-4-v2"
            XCTAssertThrowsError(try wrong.validate(),"A classical key may never use an unkeyed answer sheet")
        }
    }

    private func silentScore(numerator: Int, denominator: Int, fifths: Int = 2, mode: String = "major") -> Data {
        let duration = numerator*1920/denominator
        let rhythm = duration == 720 ? "<type>quarter</type><dot/>" : "<type>whole</type>"
        let attributes = "<attributes><divisions>480</divisions><key><fifths>\(fifths)</fifths><mode>\(mode)</mode></key><time><beats>\(numerator)</beats><beat-type>\(denominator)</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes><direction><direction-type><metronome><beat-unit>quarter</beat-unit><per-minute>96</per-minute></metronome></direction-type><sound tempo=\"96\"/></direction>"
        let bars = (1...8).map { number in "<measure number=\"\(number)\">\(number == 1 ? attributes : "")<note><rest/><duration>\(duration)</duration>\(rhythm)</note></measure>" }.joined()
        return Data("<score-partwise version=\"4.0\"><part-list><score-part id=\"P1\"><part-name>Piano</part-name></score-part></part-list><part id=\"P1\">\(bars)</part></score-partwise>".utf8)
    }

    func testNewMetersUseCorrectBeatUnitFullBarsAndReferenceScaleLength() throws {
        for (n,d,beat,bpm,scaleBars) in [(2,2,"half",96.0,2),(3,8,"dotted_quarter",82.5,5)] {
            let meter = TimeSignature(numerator:n,denominator:d)
            let score = try MusicXMLParser.parseXML(silentScore(numerator:n,denominator:d),measures:8,tempo:96)
            XCTAssertEqual(score.timeSignature,meter)
            XCTAssertEqual(score.totalTicks,meter.ticksPerMeasure*8)
            let plan = PlaybackPlan.exam(meter:meter)
            try plan.validate()
            XCTAssertEqual(plan.tempo?.beatUnit,beat); XCTAssertEqual(plan.tempoBpm,bpm)
            XCTAssertEqual(plan.scale.toMeasure,scaleBars)
            XCTAssertEqual(plan.countIn?.totalTicks,meter.ticksPerMeasure)
            XCTAssertTrue(SheetLayout.supports("staff-8bars-\(n)-\(d)-key2-v3"))
        }
    }

    func testKeyModesAndBoundsAreValidatedAndMayNotChangeInsideExcerpt() throws {
        for mode in ["major","minor"] {
            for fifths in -7...7 {
                let data = silentScore(numerator:2,denominator:2,fifths:fifths,mode:mode)
                let score = try MusicXMLParser.parseXML(data,measures:8,tempo:96)
                XCTAssertTrue(score.keySignature.supported)
                XCTAssertEqual(score.keySignature.fifths,fifths); XCTAssertEqual(score.keySignature.mode,mode)
            }
        }
        XCTAssertThrowsError(try MusicXMLParser.parseXML(silentScore(numerator:2,denominator:2,fifths:8),measures:8,tempo:96))
        XCTAssertThrowsError(try MusicXMLParser.parseXML(silentScore(numerator:2,denominator:2,mode:"dorian"),measures:8,tempo:96))
        let xml = String(decoding:silentScore(numerator:2,denominator:2),as:UTF8.self)
        let changed = xml.replacingOccurrences(of:"<measure number=\"2\">",with:"<measure number=\"2\"><attributes><key><fifths>0</fifths><mode>major</mode></key></attributes>")
        XCTAssertThrowsError(try MusicXMLParser.parseXML(Data(changed.utf8),measures:8,tempo:96))
    }
}
