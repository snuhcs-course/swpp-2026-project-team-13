import XCTest
@testable import SolfegeCore

final class SheetRevisionTests: XCTestCase {
    private var resources: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("IPadApp/IPadApp/Resources") }
    func testAllRevisionsKeepMusicAndIdentityWhileUsingCompactKeyedStaves() throws {
        let revisions = try ContractJSON.decoder().decode([Question].self,from:Data(contentsOf:resources.appendingPathComponent("sheet-revisions.json")))
        var originals = [UUID:Question]()
        for name in ["practice-catalog","classical-catalog","additional-practice-catalog"] {
            for q in try ContractJSON.decoder().decode([Question].self,from:Data(contentsOf:resources.appendingPathComponent(name+".json"))) { originals[q.id] = q }
        }
        XCTAssertEqual(revisions.count,124)
        for q in revisions {
            try q.validate()
            let old = try XCTUnwrap(originals[q.id])
            XCTAssertEqual(q.version,old.version+1)
            XCTAssertEqual(q.scoreAssets.main.sha256,old.scoreAssets.main.sha256)
            XCTAssertEqual(q.scoreAssets.scale.sha256,old.scoreAssets.scale.sha256)
            XCTAssertEqual(q.keySignature,old.keySignature)
            XCTAssertEqual(q.sheetLayout.displayHeight,620)
            XCTAssertEqual(q.sheetLayout.systems[1].staffLineY,[386,398,410,422,434])
            XCTAssertEqual(try Data(contentsOf:resources.appendingPathComponent(q.sheetLayout.id+".pngdata")).sha256,q.sheetLayout.templateSha256)
            var wrong = q; wrong.sheetLayout.displayHeight = 846
            XCTAssertThrowsError(try wrong.validate())
            try old.validate()
        }
    }
    func testV5RevisionsShareBarlinesAcrossBothStavesAndRejectMisalignment() throws {
        let revisions = try ContractJSON.decoder().decode([Question].self,from:Data(contentsOf:resources.appendingPathComponent("sheet-revisions-v5.json")))
        XCTAssertFalse(revisions.isEmpty)
        for q in revisions {
            try q.validate()
            let layout = q.sheetLayout
            XCTAssertTrue(layout.id.hasSuffix("-v5"))
            XCTAssertEqual(layout.displayHeight,574)
            XCTAssertEqual(layout.systems[1].staffLineY,[340,352,364,376,388])
            XCTAssertEqual(layout.systems[0].barlineX,layout.systems[1].barlineX)
            var shifted = q; shifted.sheetLayout.systems[1].barlineX[2] += 20
            XCTAssertThrowsError(try shifted.validate())
        }
        let layouts = Dictionary(revisions.map { ($0.sheetLayout.id,$0.sheetLayout) }) { a,_ in a }
        for layout in layouts.values {
            XCTAssertEqual(try Data(contentsOf:resources.appendingPathComponent(layout.id+".pngdata")).sha256,layout.templateSha256)
        }
    }
}
