import XCTest
@testable import SolfegeCore

final class RhythmPuzzleTests: XCTestCase {
    var resources: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("IPadApp/IPadApp/Resources") }
    func bank() throws -> RhythmCatalog { try ContractJSON.decoder().decode(RhythmCatalog.self,from:Data(contentsOf:resources.appendingPathComponent("rhythm-puzzle-v1.json"))) }
    func note(_ duration: RhythmTime, type: String, rest: Bool = false) -> RhythmSymbol {
        RhythmSymbol(duration:duration,rest:rest,type:type,dots:0,actual:1,normal:1,group:0,tieNext:false,groupEnd:false)
    }
    func testEveryActualRoundMatchesItsSourceAudioAndCanBeFilledFromItsTwelveChoices() throws {
        let catalog = try bank(); try catalog.validate()
        XCTAssertEqual(catalog.rounds.count,259)
        for round in catalog.rounds {
            var board = RhythmBoard()
            for p in round.solution { XCTAssertTrue(board.place(p.tileId,at:p.start,round:round,tiles:catalog.tileMap),round.id) }
            for time in round.solutionTies { XCTAssertTrue(board.toggleTie(time,tiles:catalog.tileMap)) }
            XCTAssertTrue(board.complete(round:round,tiles:catalog.tileMap))
            XCTAssertEqual(try board.sounds(round:round,tiles:catalog.tileMap),round.rhythm)
        }
    }
    func testFractionsAreExactAndUnrepresentableMidiIsNotRounded() throws {
        XCTAssertEqual(RhythmTime(1,3)+RhythmTime(2,3),RhythmTime(1))
        XCTAssertEqual(RhythmTime(2,3).ticks,320)
        XCTAssertNil(RhythmTime(1,7).ticks)
        XCTAssertThrowsError(try ContractJSON.decoder().decode(RhythmTime.self,from:Data("\"1/0\"".utf8)))
        XCTAssertThrowsError(try ContractJSON.decoder().decode(RhythmTime.self,from:Data("\"2/4\"".utf8)))
    }
    func testDottedQuarterFillsOneAndAHalfBeatsAndShortPieceCanStartTheAnswer() throws {
        let catalog = try bank(); var round = try XCTUnwrap(catalog.rounds.first { $0.meter == TimeSignature(numerator:4,denominator:4) })
        let dotted = RhythmTile(id:"dotted",duration:RhythmTime(3,2),symbols:[note(RhythmTime(3,2),type:"quarter")])
        let eighth = RhythmTile(id:"eighth",duration:RhythmTime(1,2),symbols:[note(RhythmTime(1,2),type:"eighth")])
        round.choices = [dotted.id,eighth.id]
        let tiles = [dotted.id:dotted,eighth.id:eighth]
        var board = RhythmBoard()
        XCTAssertTrue(board.place(dotted.id,round:round,tiles:tiles))
        XCTAssertEqual(board.firstGap(tiles:tiles),RhythmTime(3,2))
        XCTAssertTrue(board.place(eighth.id,round:round,tiles:tiles))
        XCTAssertEqual(board.firstGap(tiles:tiles),RhythmTime(2))
        board = RhythmBoard()
        XCTAssertTrue(board.place(eighth.id,round:round,tiles:tiles))
        XCTAssertEqual(board.firstGap(tiles:tiles),RhythmTime(1,2))
    }
    func testSoundGradingAcceptsAlternativeSpellingAndRemovingPieceRemovesAdjacentTies() throws {
        let catalog = try bank(); var round = try XCTUnwrap(catalog.rounds.first { $0.meter == TimeSignature(numerator:4,denominator:4) })
        round.totalDuration = RhythmTime(2); round.measureDuration = RhythmTime(2)
        let quarter = RhythmTile(id:"quarter",duration:RhythmTime(1),symbols:[note(RhythmTime(1),type:"quarter")])
        let half = RhythmTile(id:"half",duration:RhythmTime(2),symbols:[note(RhythmTime(2),type:"half")])
        let tiles = [quarter.id:quarter,half.id:half]; round.choices = [quarter.id,half.id]
        var tied = RhythmBoard(placements:[RhythmPlacement(tileId:quarter.id,start:.zero),RhythmPlacement(tileId:quarter.id,start:RhythmTime(1))])
        XCTAssertTrue(tied.toggleTie(RhythmTime(1),tiles:tiles))
        let whole = RhythmBoard(placements:[RhythmPlacement(tileId:half.id,start:.zero)])
        XCTAssertEqual(try tied.sounds(round:round,tiles:tiles),try whole.sounds(round:round,tiles:tiles))
        tied.remove(tied.placements[0],tiles:tiles)
        XCTAssertTrue(tied.ties.isEmpty)
        XCTAssertEqual(tied.placements.first?.start,RhythmTime(1))
    }
    func testThreeWrongSubmissionsHaveNoHintThenHintThenReveal() throws {
        let catalog = try bank(); let round = try XCTUnwrap(catalog.rounds.first { !$0.solutionTies.isEmpty })
        let now = Date(timeIntervalSince1970:1000)
        var record = RhythmPlayRecord(catalogSha256:"test",roundId:round.id,choiceOrder:round.choices,startedAt:now,finishedAt:now)
        record.activeMs = 40000
        record.listens = [RhythmListen(reason:"initial",startedMs:0,endedMs:30000,completed:true)]
        var draft = RhythmDraft(setIds:[round.id],index:0,record:record)
        draft.board = RhythmBoard(placements:round.solution,ties:[])
        XCTAssertFalse(try draft.submit(round:round,tiles:catalog.tileMap)); XCTAssertEqual(draft.hintLevel,1); XCTAssertFalse(draft.finished)
        XCTAssertFalse(try draft.submit(round:round,tiles:catalog.tileMap)); XCTAssertEqual(draft.hintLevel,2); XCTAssertFalse(draft.finished)
        XCTAssertFalse(try draft.submit(round:round,tiles:catalog.tileMap)); XCTAssertEqual(draft.hintLevel,3); XCTAssertTrue(draft.finished)
        XCTAssertEqual(draft.record.outcome,"revealed")
        XCTAssertThrowsError(try draft.submit(round:round,tiles:catalog.tileMap))
    }
    func testCompletedListeningIsRequiredAndCorrectAnswerEndsTheRound() throws {
        let catalog = try bank(), round = try XCTUnwrap(catalog.rounds.first)
        let now = Date()
        let record = RhythmPlayRecord(catalogSha256:"test",roundId:round.id,choiceOrder:round.choices,startedAt:now,finishedAt:now)
        var draft = RhythmDraft(setIds:[round.id],index:0,record:record)
        draft.board = RhythmBoard(placements:round.solution,ties:round.solutionTies)
        XCTAssertThrowsError(try draft.submit(round:round,tiles:catalog.tileMap))
        draft.record.listens = [RhythmListen(reason:"replay",startedMs:0,endedMs:1000,completed:true)]
        XCTAssertTrue(try draft.submit(round:round,tiles:catalog.tileMap))
        XCTAssertEqual(draft.record.outcome,"correct"); XCTAssertEqual(draft.hintLevel,0)
    }
    @MainActor func testBalancedSetNeverRepeatsAQuestionAndRecordTransportKeepsIdentity() async throws {
        let catalog = try bank(), set = catalog.set()
        XCTAssertEqual(set.count,5); XCTAssertEqual(Set(set.map(\.questionId)).count,5)
        let round = try XCTUnwrap(set.first)
        let record = RhythmPlayRecord(catalogSha256:String(repeating:"0",count:64),roundId:round.id,choiceOrder:round.choices,startedAt:Date(),finishedAt:Date())
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let api = try HTTPExamAPI(base:URL(string:"https://api.sori.example/api/v1/")!,token:"test-token",session:URLSession(configuration:config))
        defer { StubProtocol.handler = nil }
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod,"POST")
            XCTAssertEqual(request.url?.absoluteString,"https://api.sori.example/api/v1/drills/rhythm/plays/")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Idempotency-Key"),record.id.uuidString.lowercased())
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer test-token")
            let receipt = RhythmReceipt(id:UUID(),clientPlayId:record.id,roundId:record.roundId,catalogSha256:record.catalogSha256)
            return (201,"application/json",try ContractJSON.encoder().encode(receipt))
        }
        let receipt = try await api.saveRhythmPlay(record)
        XCTAssertEqual(receipt.clientPlayId,record.id)
    }
    func testNewSetAvoidsRecentMelodiesAndStillFillsASmallPool() throws {
        var catalog = try bank()
        let first = catalog.set(), sources = first.map(\.questionId), patterns = Set(first.map(\.rhythmKey))
        for _ in 0..<30 {
            let next = catalog.set(recentSourceIds:sources,recentRhythmKeys:patterns)
            XCTAssertEqual(next.count,5)
            XCTAssertTrue(Set(next.map(\.questionId)).isDisjoint(with:Set(sources)))
            XCTAssertTrue(Set(next.map(\.rhythmKey)).isDisjoint(with:patterns))
        }
        catalog.rounds = first
        let fallback = catalog.set(recentSourceIds:sources,recentRhythmKeys:patterns)
        XCTAssertEqual(fallback.count,5); XCTAssertEqual(Set(fallback.map(\.questionId)).count,5)
    }
}
