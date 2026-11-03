import XCTest
@testable import SORICore

final class RhythmEngravingTests: XCTestCase {
    private var resources: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("IPadApp/IPadApp/Resources") }
    func testBeginnerAndLegacyPoolsValidateAndEngravingCoversAllChoices() throws {
        let raw = try Data(contentsOf:resources.appendingPathComponent("rhythm-puzzle-v2.json"))
        let catalog = try ContractJSON.decoder().decode(RhythmCatalog.self,from:raw)
        try catalog.validate()
        XCTAssertEqual(catalog.rounds.count,415)
        XCTAssertEqual(catalog.rounds.filter { $0.level == "beginner" }.count,156)
        let ink = try ContractJSON.decoder().decode(RhythmEngraving.self,from:Data(contentsOf:resources.appendingPathComponent("rhythm-engraving-v2.json")))
        XCTAssertEqual(ink.catalogSha256,raw.sha256)
        for tile in catalog.tiles {
            let drawing = try XCTUnwrap(ink.tiles[tile.id])
            XCTAssertEqual(drawing.symbolXs.count,tile.symbols.count)
            XCTAssertTrue((20...180).contains(drawing.width)); XCTAssertFalse(drawing.paths.isEmpty)
        }
    }
    func testPlacedNoteheadAnchorsAndDropCoordinatesFollowEngravedSpacing() throws {
        let catalog = try ContractJSON.decoder().decode(RhythmCatalog.self,from:Data(contentsOf:resources.appendingPathComponent("rhythm-puzzle-v2.json")))
        let ink = try ContractJSON.decoder().decode(RhythmEngraving.self,from:Data(contentsOf:resources.appendingPathComponent("rhythm-engraving-v2.json")))
        for round in catalog.rounds {
            let board = RhythmBoard(placements:round.solution,ties:round.solutionTies)
            for bar in 0..<2 {
                let layout = RhythmBarLayout(round:round,bar:bar,board:board,tiles:catalog.tileMap,drawings:ink.tiles)
                for segment in layout.segments {
                    guard let p = segment.placement else { continue }
                    let drawing = try XCTUnwrap(ink.tiles[p.tileId])
                    XCTAssertEqual(layout.firstHead(p),segment.x+drawing.symbolXs[0])
                    XCTAssertEqual(layout.lastHead(p),segment.x+drawing.symbolXs[drawing.symbolXs.count-1])
                    XCTAssertEqual(layout.nearestTime(to:segment.x+segment.width/2,tiles:catalog.tileMap),p.start)
                }
            }
        }
    }
}
