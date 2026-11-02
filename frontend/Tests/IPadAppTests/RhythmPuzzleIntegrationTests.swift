import XCTest
import SwiftUI
@testable import IPadApp

@MainActor final class RhythmPuzzleIntegrationTests: XCTestCase {
    func connection() throws -> RhythmConnection {
        RhythmConnection(api:try DemoExamAPI(outcome:"completed"),profileId:UUID(),demo:true,generation:UUID())
    }
    func testFirstWrongSubmissionDoesNotExposePositionsAndUndoSurvivesRestore() throws {
        let connection = try connection()
        // Construct a paused, fully listened draft so this test never depends on sound output.
        let catalog: RhythmCatalog = try Bundled.decode("rhythm-puzzle-v1")
        let round = try XCTUnwrap(catalog.rounds.first { !$0.solutionTies.isEmpty })
        let data = try Bundled.data("rhythm-puzzle-v1",ext:"json")
        let now = Date()
        var record = RhythmPlayRecord(catalogSha256:data.sha256,roundId:round.id,choiceOrder:round.choices,startedAt:now,finishedAt:now)
        record.activeMs = 40000; record.listens = [RhythmListen(reason:"initial",startedMs:0,endedMs:30000,completed:true)]
        var draft = RhythmDraft(setIds:[round.id],index:0,record:record)
        draft.board = RhythmBoard(placements:round.solution,ties:[])
        let store = try RhythmPuzzleStore(root:LocalStore(scope:connection.scope).root)
        try store.save(RhythmJournal(draft:draft))
        let restored = RhythmPuzzleModel(connection:connection)
        restored.resume()
        let original = restored.board
        restored.remove(try XCTUnwrap(original.placements.first)); XCTAssertNotEqual(restored.board,original)
        restored.undo(); XCTAssertEqual(restored.board,original)
        XCTAssertEqual(try store.load().draft?.board,original)
        restored.submit()
        XCTAssertEqual(restored.draft?.hintLevel,1)
        XCTAssertEqual(restored.feedback,"리듬이 일치하지 않아요. 다시 들어보세요.")
        XCTAssertTrue(restored.hintPositions.isEmpty)
        restored.submit(); XCTAssertEqual(restored.draft?.hintLevel,2); XCTAssertFalse(restored.hintPositions.isEmpty)
        restored.submit(); XCTAssertEqual(restored.draft?.record.outcome,"revealed")
        XCTAssertEqual(restored.journal.records.count,1)
        restored.close()
        let again = RhythmPuzzleModel(connection:connection)
        XCTAssertEqual(again.journal.records.first?.id,record.id)
        XCTAssertEqual(again.journal.records.first?.submissions.count,3)
        again.makeExport(); XCTAssertNotNil(again.exportURL)
    }
    func testPerAccountJournalIsolationAndAccountStoreRemovalIncludesDrills() throws {
        let first = try connection(), second = try connection()
        let a = try LocalStore(scope:first.scope), b = try LocalStore(scope:second.scope)
        XCTAssertNotEqual(a.root,b.root)
        let store = try RhythmPuzzleStore(root:a.root)
        let catalog: RhythmCatalog = try Bundled.decode("rhythm-puzzle-v1")
        let round = try XCTUnwrap(catalog.rounds.first)
        let record = RhythmPlayRecord(catalogSha256:"test",roundId:round.id,choiceOrder:round.choices,startedAt:Date(),finishedAt:Date())
        try store.save(RhythmJournal(records:[record]))
        XCTAssertEqual(try store.load().records.count,1)
        XCTAssertTrue(try RhythmPuzzleStore(root:b.root).load().records.isEmpty)
        try a.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.file.path))
    }
    func testLandscapeAndPortraitRhythmBoardsAndTwelveChoiceValuesRender() throws {
        let connection = try connection()
        let catalog: RhythmCatalog = try Bundled.decode("rhythm-puzzle-v1")
        let round = try XCTUnwrap(catalog.rounds.first { $0.meter == TimeSignature(numerator:4,denominator:4) && !$0.solutionTies.isEmpty })
        let now = Date(), data = try Bundled.data("rhythm-puzzle-v1",ext:"json")
        let record = RhythmPlayRecord(catalogSha256:data.sha256,roundId:round.id,choiceOrder:round.choices,startedAt:now,finishedAt:now)
        var draft = RhythmDraft(setIds:[round.id],index:0,record:record)
        draft.board = RhythmBoard(placements:round.solution,ties:round.solutionTies)
        let store = try RhythmPuzzleStore(root:LocalStore(scope:connection.scope).root)
        try store.save(RhythmJournal(draft:draft))
        let game = RhythmPuzzleModel(connection:connection)
        for compact in [false,true] {
            let content = VStack {
                Text("리듬 퍼즐 · \(round.meter.numerator)/\(round.meter.denominator)").font(.title.bold())
                RhythmPuzzleBoardView(game:game,round:round,compact:compact)
                LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:4)) {
                    ForEach(round.choices,id:\.self) { id in if let tile = game.tiles[id] { RhythmTileFace(tile:tile,pulse:round.pulse) } }
                }
                RhythmReferenceView(round:round,tiles:game.tiles)
            }.padding(24).frame(width:compact ? 834 : 1194).background(.white)
            let renderer = ImageRenderer(content:content), image = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image:image); attachment.name = compact ? "rhythm-puzzle-portrait" : "rhythm-puzzle-landscape"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testCountInAndListeningCanRestartAfterAnInterruption() async throws {
        let connection = try connection()
        let bank: RhythmCatalog = try Bundled.decode("rhythm-puzzle-v1")
        let round = try XCTUnwrap(bank.rounds.first { $0.meter == TimeSignature(numerator:2,denominator:4) })
        let now = Date(), data = try Bundled.data("rhythm-puzzle-v1",ext:"json")
        let record = RhythmPlayRecord(catalogSha256:data.sha256,roundId:round.id,choiceOrder:round.choices,startedAt:now,finishedAt:now)
        let store = try RhythmPuzzleStore(root:LocalStore(scope:connection.scope).root)
        try store.save(RhythmJournal(draft:RhythmDraft(setIds:[round.id],index:0,record:record)))
        let game = RhythmPuzzleModel(connection:connection)
        defer { game.close() }
        game.resume(); XCTAssertNil(game.error); XCTAssertTrue(game.playing)
        try await Task.sleep(for:.milliseconds(100))
        game.pause(); XCTAssertFalse(game.playing); XCTAssertEqual(game.draft?.hasListened,false)
        XCTAssertEqual(game.draft?.record.listens.count,1); XCTAssertEqual(game.draft?.record.listens.first?.completed,false)
        game.resume(); XCTAssertNil(game.error)
        let deadline = MonotonicTime.now+12
        while game.playing && MonotonicTime.now < deadline { try await Task.sleep(for:.milliseconds(25)) }
        XCTAssertFalse(game.playing); XCTAssertNil(game.error)
        XCTAssertEqual(game.draft?.hasListened,true)
        XCTAssertEqual(game.draft?.record.listens.count,2)
        XCTAssertEqual(game.draft?.record.listens.last?.completed,true)
    }
}
