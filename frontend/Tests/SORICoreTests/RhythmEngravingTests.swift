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
    func testDropAnywhereInsideAnEmptyBeatSnapsToItsStartIncludingHalfBeatRemainders() throws {
        let catalog = try ContractJSON.decoder().decode(RhythmCatalog.self,from:Data(contentsOf:resources.appendingPathComponent("rhythm-puzzle-v3.json")))
        let ink = try ContractJSON.decoder().decode(RhythmEngraving.self,from:Data(contentsOf:resources.appendingPathComponent("rhythm-engraving-v3.json")))
        let round = try XCTUnwrap(catalog.rounds.first { $0.meter == TimeSignature(numerator:4,denominator:4) })
        for bar in 0..<2 {
            let layout = RhythmBarLayout(round:round,bar:bar,board:RhythmBoard(),tiles:catalog.tileMap,drawings:ink.tiles)
            for part in layout.segments {
                for fraction in [0.1,0.5,0.9] {
                    XCTAssertEqual(layout.nearestTime(to:part.x+part.width*fraction,tiles:catalog.tileMap),part.start)
                }
            }
        }
        let dotted = try XCTUnwrap(catalog.tiles.first { $0.duration == RhythmTime(3,2) && $0.symbols.count == 1 && !$0.symbols[0].rest })
        let board = RhythmBoard(placements:[RhythmPlacement(tileId:dotted.id,start:.zero)])
        let layout = RhythmBarLayout(round:round,bar:0,board:board,tiles:catalog.tileMap,drawings:ink.tiles)
        let remainder = try XCTUnwrap(layout.segments.first { $0.placement == nil })
        XCTAssertEqual(remainder.start,RhythmTime(3,2))
        XCTAssertEqual(layout.nearestTime(to:remainder.x+remainder.width/2,tiles:catalog.tileMap),RhythmTime(3,2))
    }
    func testClassicalPoolIncludesCreditsAndAllOlderPiecesRemainDrawable() throws {
        let raw = try Data(contentsOf:resources.appendingPathComponent("rhythm-puzzle-v3.json"))
        let catalog = try ContractJSON.decoder().decode(RhythmCatalog.self,from:raw)
        try catalog.validate()
        let classic = catalog.rounds.filter { $0.collection == "classical" }
        XCTAssertEqual(classic.count,116)
        XCTAssertEqual(Set(classic.map(\.level)),Set(["beginner","intermediate","advanced"]))
        XCTAssertTrue(classic.allSatisfy { $0.sourceLabel?.hasSuffix(" 中") == true })
        let ink = try ContractJSON.decoder().decode(RhythmEngraving.self,from:Data(contentsOf:resources.appendingPathComponent("rhythm-engraving-v3.json")))
        XCTAssertEqual(ink.catalogSha256,raw.sha256)
        for version in ["v1","v2","v3"] {
            let old = try ContractJSON.decoder().decode(RhythmCatalog.self,from:Data(contentsOf:resources.appendingPathComponent("rhythm-puzzle-\(version).json")))
            XCTAssertTrue(old.tiles.allSatisfy { ink.tiles[$0.id]?.symbolXs.count == $0.symbols.count })
        }
    }
}
