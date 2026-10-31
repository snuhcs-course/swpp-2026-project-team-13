import XCTest
@testable import SORICore

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
}
