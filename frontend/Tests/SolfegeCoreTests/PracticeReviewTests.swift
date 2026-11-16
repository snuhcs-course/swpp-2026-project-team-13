import XCTest
@testable import SolfegeCore

final class PracticeReviewTests: XCTestCase {
    private var resources: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("IPadApp/IPadApp/Resources") }
    private func sheet() throws -> SheetLayout {
        try ContractJSON.decoder().decode([Question].self,from:Data(contentsOf:resources.appendingPathComponent("sheet-revisions-v6.json")))[0].sheetLayout
    }
    func testCanonicalReferenceAndAnswerShareCropsWithoutMovingHandwriting() throws {
        let original = try sheet()
        var reference = PracticeReviewGeometry(sheet:original); reference.logicalHeight = 574
        let answer = PracticeReviewGeometry(sheet:original)
        XCTAssertTrue(answer.isValid); XCTAssertTrue(reference.isValid)
        for (a,b) in zip(answer.strips,reference.strips) {
            XCTAssertEqual(a.bounds.y*846,b.bounds.y*574,accuracy:0.00001)
            XCTAssertEqual(a.bounds.height*846,b.bounds.height*574,accuracy:0.00001)
            for (left,right) in zip(a.measureRegions(logicalWidth:1330,systems:answer.systems),b.measureRegions(logicalWidth:1330,systems:reference.systems)) {
                XCTAssertEqual(left.id,right.id)
                XCTAssertEqual(left.bounds.x,right.bounds.x,accuracy:0.00001)
                XCTAssertEqual(left.bounds.y,right.bounds.y,accuracy:0.00001)
                XCTAssertEqual(left.bounds.width,right.bounds.width,accuracy:0.00001)
                XCTAssertEqual(left.bounds.height,right.bounds.height,accuracy:0.00001)
            }
        }
        XCTAssertLessThanOrEqual(answer.strips[0].bounds.y+answer.strips[0].bounds.height,answer.strips[1].bounds.y+0.00001)
        XCTAssertEqual(try sheet(),original)
    }
    func testNaturalWidthsUseActualImageMeasureBoundaries() throws {
        var geometry = PracticeReviewGeometry(sheet:try sheet())
        geometry.systems[0].barlineX = [54,290,720,1020,1276]
        let crop = try XCTUnwrap(geometry.strips.first)
        let regions = crop.measureRegions(logicalWidth:geometry.logicalWidth,systems:geometry.systems)
        XCTAssertEqual(regions[1].bounds.x,290.0/1330,accuracy:0.00001)
        XCTAssertEqual(regions[1].bounds.width,430.0/1330,accuracy:0.00001)
        geometry.systems[0].barlineX[1] = .nan
        XCTAssertFalse(geometry.isValid); XCTAssertTrue(geometry.strips.isEmpty)
    }
    func testErrorPickerStaysBesideTheMeasureAndInsideSmallAndLargeIPads() {
        for size in [(1024.0,680.0),(1180.0,760.0),(1366.0,940.0)] {
            for x in [24.0,size.0/2,size.0-230] {
                for y in [10.0,size.1-100] {
                    let anchor = BBox(x:x,y:y,width:200,height:92)
                    let result = PracticeReviewPopover.frame(anchor:anchor,width:228,height:204,containerWidth:size.0,containerHeight:size.1)
                    XCTAssertGreaterThanOrEqual(result.x,12); XCTAssertGreaterThanOrEqual(result.y,12)
                    XCTAssertLessThanOrEqual(result.x+result.width,size.0-12)
                    XCTAssertLessThanOrEqual(result.y+result.height,size.1-12)
                    if x+200+10+228 <= size.0-12 { XCTAssertGreaterThanOrEqual(result.x,x+200) }
                    else if x-10-228 >= 12 { XCTAssertLessThanOrEqual(result.x+result.width,x) }
                }
            }
        }
    }
    func testReviewClipRetainsSilenceAndClipsACrossBarTie() throws {
        let score = MusicScore(tempo:96,measures:8,events:[MusicEvent(midi:60,onset:1800,duration:360),MusicEvent(midi:62,onset:2400,duration:480)],symbols:[])
        let bar = try PracticeReviewClip.make(score:score,measure:2,bpm:80)
        XCTAssertEqual(bar.events,[MusicEvent(midi:60,onset:0,duration:240),MusicEvent(midi:62,onset:480,duration:480)])
        XCTAssertEqual(bar.ticks,1920); XCTAssertEqual(bar.bpm,80)
        let full = try PracticeReviewClip.make(score:score,measure:nil,bpm:80)
        XCTAssertEqual(full.events,score.events); XCTAssertEqual(full.ticks,8*1920)
        XCTAssertThrowsError(try PracticeReviewClip.make(score:score,measure:9,bpm:80))
        XCTAssertThrowsError(try PracticeReviewClip.make(score:score,measure:1,bpm:.nan))
    }
    func testAllV6TemplatesAndReferenceGeometryDecodeAndValidate() throws {
        let questions = try ContractJSON.decoder().decode([Question].self,from:Data(contentsOf:resources.appendingPathComponent("sheet-revisions-v6.json")))
        struct Manifest: Decodable { struct Entry: Decodable { var geometry: PracticeReviewGeometry; var layoutMode: String }; var scores: [String:Entry] }
        let manifest = try ContractJSON.decoder().decode(Manifest.self,from:Data(contentsOf:resources.appendingPathComponent("practice-layout-v2.json")))
        XCTAssertGreaterThan(questions.count,1900)
        for q in questions {
            try q.validate(); XCTAssertTrue(q.sheetLayout.id.hasSuffix("-v6"))
            let image = try XCTUnwrap(manifest.scores[q.scoreAssets.main.sha256])
            XCTAssertTrue(image.geometry.isValid)
            if image.layoutMode == "equal" {
                for system in image.geometry.systems {
                    for (x,y) in zip(system.barlineX,q.sheetLayout.systems[0].barlineX) { XCTAssertEqual(x,y,accuracy:2) }
                }
            }
        }
    }
}
