import XCTest
@testable import SORICore

final class ComparisonTests: XCTestCase {
    private var resources: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("IPadApp/IPadApp/Resources") }
    func testStaffCropsMapHighlightsWithoutChangingOriginalCoordinates() throws {
        let q = try ContractJSON.decoder().decode([Question].self,from:Data(contentsOf:resources.appendingPathComponent("practice-catalog.json")))[0]
        let original = q.sheetLayout
        let crops = AnswerSystemCrop.strips(layout:original)
        XCTAssertEqual(crops.count,2)
        XCTAssertLessThan(crops.reduce(0) { $0+$1.bounds.height },0.6)
        let box = BBox(x:0.4,y:0.58,width:0.2,height:0.06)
        XCTAssertNil(crops[0].project(box))
        let projected = try XCTUnwrap(crops[1].project(box))
        XCTAssertEqual(projected.y*crops[1].bounds.height+crops[1].bounds.y,box.y,accuracy:0.000001)
        XCTAssertEqual(projected.height*crops[1].bounds.height,box.height,accuracy:0.000001)
        XCTAssertEqual(q.sheetLayout,original)
    }
    func testNewAnnotationFieldsAndLegacyRecordsDecode() throws {
        let old = Data(#"{"id":"a","type":"pitch_error","measure":2,"bbox":null,"message":"음정을 확인해요."}"#.utf8)
        let legacy = try ContractJSON.decoder().decode(Annotation.self,from:old)
        XCTAssertNil(legacy.noteIndex)
        let recent = Data(#"{"id":"a","type":"notation_error","measure":2,"note_index":3,"end_note_index":5,"bbox":null,"message":"빔을 3개씩 묶어 봐요."}"#.utf8)
        let current = try ContractJSON.decoder().decode(Annotation.self,from:recent)
        XCTAssertEqual(current.locationLabel,"2마디 · 3–5번째 음표·쉼표")
        XCTAssertEqual(current.categoryLabel,"표기 관습")
        XCTAssertEqual(try ContractJSON.decoder().decode(Annotation.self,from:ContractJSON.encoder().encode(current)),current)
    }
}
