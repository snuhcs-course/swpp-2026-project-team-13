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
    func testCSVExportKeepsFirstAttemptReplayCountsAndSourceMetadata() throws {
        let connection = try connection()
        let accountStore = try LocalStore(scope:connection.scope)
        defer { try? accountStore.removeAll() }
        let store = try RhythmPuzzleStore(root:accountStore.root)
        let catalog: RhythmCatalog = try Bundled.decode("rhythm-puzzle-v1")
        let round = try XCTUnwrap(catalog.rounds.first { !$0.solutionTies.isEmpty })
        let now = Date()
        var record = RhythmPlayRecord(catalogSha256:"catalog-test",roundId:round.id,choiceOrder:round.choices,startedAt:now,finishedAt:now)
        // A corrected retry must not replace the unaided first-attempt result.
        record.submissions = [
            RhythmSubmission(activeMs:1000,placements:round.solution,ties:[]),
            RhythmSubmission(activeMs:2000,placements:round.solution,ties:round.solutionTies)
        ]
        record.outcome = "correct"; record.activeMs = 3000
        record.interruptions = 1; record.priorExposures = 2; record.priorPatternExposures = 3
        record.listens = [
            RhythmListen(reason:"initial",startedMs:0,endedMs:200,completed:true),
            RhythmListen(reason:"replay",startedMs:200,endedMs:300,completed:false),
            RhythmListen(reason:"replay",startedMs:300,endedMs:500,completed:true),
            RhythmListen(reason:"reference",startedMs:2000,endedMs:2500,completed:true)
        ]
        let journal = RhythmJournal(records:[record],synced:[record.id])
        let url = try store.csv(journal,catalog:catalog)
        let data = try Data(contentsOf:url)
        XCTAssertEqual(Array(data.prefix(3)),[0xEF,0xBB,0xBF])
        let text = String(decoding:data.dropFirst(3),as:UTF8.self)
        let lines = text.components(separatedBy:"\r\n")
        XCTAssertEqual(lines.count,3); XCTAssertEqual(lines.last,"")
        func cells(_ line: String) -> [String] {
            String(line.dropFirst().dropLast()).components(separatedBy:"\",\"")
        }
        let header = cells(lines[0]), values = cells(lines[1])
        XCTAssertEqual(header.count,20); XCTAssertEqual(values.count,header.count)
        let row = Dictionary(uniqueKeysWithValues:zip(header,values))
        XCTAssertEqual(row["play_id"],record.id.uuidString)
        XCTAssertEqual(row["question_id"],round.questionId.uuidString)
        XCTAssertEqual(row["source_bars"],"\(round.firstMeasure)-\(round.firstMeasure+1)")
        XCTAssertEqual(row["meter"],"\(round.meter.numerator)/\(round.meter.denominator)")
        XCTAssertEqual(row["tempo_quarter_bpm"],String(round.tempoBpm))
        XCTAssertEqual(row["difficulty"],String(round.difficulty.score))
        XCTAssertEqual(row["difficulty_version"],round.difficulty.version)
        XCTAssertEqual(row["catalog_sha256"],"catalog-test")
        XCTAssertEqual(row["outcome"],"correct"); XCTAssertEqual(row["first_correct"],"false")
        XCTAssertEqual(row["submissions"],"2")
        XCTAssertEqual(row["replays_started"],"2"); XCTAssertEqual(row["replays_completed"],"1")
        XCTAssertEqual(row["active_ms"],"3000"); XCTAssertEqual(row["interruptions"],"1")
        XCTAssertEqual(row["prior_exposures"],"2"); XCTAssertEqual(row["prior_pattern_exposures"],"3")
        XCTAssertEqual(row["choice_order"],round.choices.joined(separator:";"))
        XCTAssertEqual(row["server_synced"],"true")
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
        game.resume(); XCTAssertNil(game.error); XCTAssertTrue(game.waitingToPlay); XCTAssertFalse(game.playing)
        try await Task.sleep(for:.milliseconds(1100))
        XCTAssertTrue(game.playing)
        game.pause(); XCTAssertFalse(game.playing); XCTAssertEqual(game.draft?.hasListened,false)
        XCTAssertEqual(game.draft?.record.listens.count,1); XCTAssertEqual(game.draft?.record.listens.first?.completed,false)
        game.resume(); XCTAssertNil(game.error)
        XCTAssertTrue(game.waitingToPlay); XCTAssertFalse(game.playing)
        let deadline = MonotonicTime.now+14
        while (game.playing || game.waitingToPlay) && MonotonicTime.now < deadline { try await Task.sleep(for:.milliseconds(25)) }
        XCTAssertFalse(game.playing); XCTAssertNil(game.error)
        XCTAssertEqual(game.draft?.hasListened,true)
        XCTAssertEqual(game.draft?.record.listens.count,2)
        XCTAssertEqual(game.draft?.record.listens.last?.completed,true)
    }
    func testOneSecondStartAndReplayWaitAreCancelledOnPauseAndClose() async throws {
        let game = RhythmPuzzleModel(connection:try connection())
        game.newSet(); XCTAssertNil(game.error)
        XCTAssertEqual(game.round?.level,"beginner"); XCTAssertEqual(game.draft?.record.gameVersion,"rhythm-puzzle-v2")
        XCTAssertTrue(game.waitingToPlay); XCTAssertFalse(game.playing)
        try await Task.sleep(for:.milliseconds(150))
        game.pause(); XCTAssertFalse(game.waitingToPlay)
        try await Task.sleep(for:.milliseconds(1050))
        XCTAssertFalse(game.playing); XCTAssertTrue(game.draft?.record.listens.isEmpty == true)
        game.listen(); XCTAssertTrue(game.waitingToPlay)
        game.listen(); game.close()
        try await Task.sleep(for:.milliseconds(1050))
        XCTAssertFalse(game.playing); XCTAssertFalse(game.waitingToPlay)
        XCTAssertTrue(game.draft?.record.listens.isEmpty == true)
    }
    func testTieModeConnectsActualAdjacentNotesAcrossTheBarlineAndCanRemoveIt() throws {
        let context = try connection()
        let bank: RhythmCatalog = try Bundled.decode("rhythm-puzzle-v2")
        let round = try XCTUnwrap(bank.rounds.first { $0.solutionTies.contains($0.measureDuration) })
        let raw = try Bundled.data("rhythm-puzzle-v2",ext:"json")
        let now = Date()
        var record = RhythmPlayRecord(catalogSha256:raw.sha256,roundId:round.id,choiceOrder:round.choices,startedAt:now,finishedAt:now)
        record.gameVersion = bank.version
        var draft = RhythmDraft(setIds:[round.id],index:0,record:record)
        draft.board = RhythmBoard(placements:round.solution,ties:[])
        let store = try RhythmPuzzleStore(root:LocalStore(scope:context.scope).root)
        try store.save(RhythmJournal(draft:draft))
        let game = RhythmPuzzleModel(connection:context)
        defer { game.close() }
        let first = try XCTUnwrap(game.board.placements.first { game.board.end($0,tiles:game.tiles) == round.measureDuration })
        let second = try XCTUnwrap(game.board.placements.first { $0.start == round.measureDuration })
        game.toggleTieMode(); game.tapPiece(first); game.tapPiece(second)
        XCTAssertTrue(game.board.ties.contains(round.measureDuration)); XCTAssertFalse(game.tieMode)
        game.toggleTieMode(); game.tapPiece(second); game.tapPiece(first)
        XCTAssertFalse(game.board.ties.contains(round.measureDuration)); XCTAssertFalse(game.tieMode)
    }
}
