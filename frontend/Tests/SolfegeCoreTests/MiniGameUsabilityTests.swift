import XCTest
@testable import SolfegeCore

final class MiniGameUsabilityTests: XCTestCase {
    var resources: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("IPadApp/IPadApp/Resources") }
    func bank() throws -> RhythmCatalog { try ContractJSON.decoder().decode(RhythmCatalog.self,from:Data(contentsOf:resources.appendingPathComponent("rhythm-puzzle-v3.json"))) }
    func melody() throws -> MelodyRound {
        let bank = try JSONDecoder().decode(MemoryCatalog.self,from:Data(contentsOf:resources.appendingPathComponent("memory-run-v2.json")))
        let excerpt = try XCTUnwrap(bank.excerpts.first { $0.beginnerEligible && $0.bars == 2 })
        let source = try XCTUnwrap(bank.sources.first { $0.id == excerpt.sourceId })
        return try MelodyRound(source:MelodyXMLParser.parse(Data(contentsOf:resources.appendingPathComponent(source.file))),start:excerpt.first,bars:2)
    }
    func testHalfBeatRemainderIsHalfWidthAndHasItsOwnExactDropTarget() throws {
        let bank = try bank(), round = try XCTUnwrap(bank.rounds.first { $0.meter == TimeSignature(numerator:4,denominator:4) })
        let dotted = try XCTUnwrap(bank.tiles.first { $0.duration == RhythmTime(3,2) && $0.symbols.count == 1 && !$0.symbols[0].rest })
        let board = RhythmBoard(placements:[RhythmPlacement(tileId:dotted.id,start:.zero)])
        let layout = RhythmBarLayout(round:round,bar:0,board:board,tiles:bank.tileMap,drawings:[:])
        let half = try XCTUnwrap(layout.slots.first { $0.empty })
        let full = try XCTUnwrap(layout.slots.first { $0.empty && $0.duration == round.pulse })
        XCTAssertEqual(half.start,RhythmTime(3,2)); XCTAssertEqual(half.duration,RhythmTime(1,2))
        XCTAssertEqual(half.width*2,full.width,accuracy:0.001); XCTAssertEqual(half.label(pulse:round.pulse),"½박")
        XCTAssertEqual(layout.nearestTime(to:half.x+half.width/2,tiles:bank.tileMap),half.start)
        XCTAssertNotNil(board.placementIssue(dotted.id,at:RhythmTime(7,2),round:round,tiles:bank.tileMap))
    }
    func testPulseBoxesCoverAllMetersAndConnectionStrokeIsIdempotent() throws {
        let bank = try bank()
        for meter in [TimeSignature(numerator:4,denominator:4),TimeSignature(numerator:3,denominator:4),TimeSignature(numerator:6,denominator:8)] {
            let round = try XCTUnwrap(bank.rounds.first { $0.meter == meter })
            let layout = RhythmBarLayout(round:round,bar:0,board:RhythmBoard(),tiles:bank.tileMap,drawings:[:])
            XCTAssertEqual(layout.slots.count,meter.numerator == 6 ? 2 : meter.numerator)
            XCTAssertEqual(layout.slots.reduce(.zero) { $0+$1.duration },round.measureDuration)
        }
        let round = try XCTUnwrap(bank.rounds.first { !$0.solutionTies.isEmpty })
        var board = RhythmBoard(placements:round.solution,ties:[])
        let t = try XCTUnwrap(round.solutionTies.first)
        let a = try XCTUnwrap(board.placements.first { board.end($0,tiles:bank.tileMap) == t })
        let b = try XCTUnwrap(board.placements.first { $0.start == t })
        XCTAssertTrue(board.connect(a,b,tiles:bank.tileMap)); let before = board
        XCTAssertTrue(board.connect(b,a,tiles:bank.tileMap)); XCTAssertEqual(board,before)
        board.remove(a,tiles:bank.tileMap); XCTAssertFalse(board.ties.contains(t))
        XCTAssertTrue(MiniGameGesture.isTap(maximumDistance:14,pencil:true))
        XCTAssertFalse(MiniGameGesture.isTap(maximumDistance:20,pencil:true))
        XCTAssertFalse(MiniGameGesture.isTap(maximumDistance:14,pencil:false))
    }
    func testManualGuidedFirstReplacementAndUndoRestoreWholeBar() throws {
        let round = try melody()
        var answer = MelodyAnswers(round:round,guideFirst:true)
        let first = try XCTUnwrap(round.targets.first?.midi)
        XCTAssertNil(answer.pitches.first ?? nil)
        XCTAssertFalse(answer.enter(first+1,measure:round.targets[0].measure))
        XCTAssertTrue(answer.enter(first,measure:round.targets[0].measure))
        let bar = round.targets[0].measure
        while let i = answer.next(in:bar) { XCTAssertTrue(answer.enter(round.targets[i].midi,measure:bar)) }
        let before = answer.pitches
        XCTAssertTrue(answer.replace(measure:bar,with:first))
        XCTAssertEqual(round.targetIndices(measure:bar).filter { answer.pitches[$0] != nil }.count,1)
        XCTAssertEqual(answer.undo(),bar); XCTAssertEqual(answer.pitches,before)
        answer.clear(measure:bar); XCTAssertNil(answer.pitches.first ?? nil)
        answer.undo(); XCTAssertEqual(answer.pitches,before)
        XCTAssertEqual(answer.result.expected.count,round.targets.count-1)
    }
    func testDirectReplayHasNoClickTrackAndPreservesMelodyDuration() throws {
        let round = try melody(), settings = MelodySettings()
        let counted = MelodyTimeline(round:round,settings:settings)
        let direct = MelodyTimeline(round:round,settings:settings,includeCountIn:false)
        XCTAssertEqual(direct.windows.first?.phase,.listen); XCTAssertTrue(direct.clickEvents().isEmpty)
        XCTAssertEqual(counted.end-direct.end,round.score.ticksPerMeasure)
        XCTAssertEqual(direct.end,round.score.totalTicks)
    }
    func testSkipDoesNotCreateAWrongSubmissionAndLegacyPayloadRemainsDecodable() throws {
        let bank = try bank(), round = try XCTUnwrap(bank.rounds.first), now = Date()
        var draft = RhythmDraft(setIds:[round.id],index:0,record:RhythmPlayRecord(catalogSha256:"test",roundId:round.id,choiceOrder:round.choices,startedAt:now,finishedAt:now))
        draft.revealAndSkip(); XCTAssertEqual(draft.record.outcome,"skipped"); XCTAssertTrue(draft.record.submissions.isEmpty)
        let raw = try ContractJSON.encoder().encode(draft.record)
        XCTAssertTrue(try ContractJSON.decoder().decode(RhythmPlayRecord.self,from:raw).skipped == true)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with:raw) as? [String:Any]); legacy.removeValue(forKey:"skipped")
        XCTAssertNil(try ContractJSON.decoder().decode(RhythmPlayRecord.self,from:JSONSerialization.data(withJSONObject:legacy)).skipped)
    }
    func testComparisonUsesIdenticalRhythmPositionsAndMuseScoreGlyphsAreComplete() throws {
        let round = try melody(), blank = Array<Int?>(repeating:nil,count:round.targets.count)
        let actual = round.phraseDisplay(answers:blank), reference = round.phraseDisplay(answers:blank,reveal:true)
        XCTAssertEqual(actual.0.symbols.count,reference.0.symbols.count)
        XCTAssertEqual(actual.0.symbols.map(\.measure),round.score.symbols.map(\.measure))
        let a = MemoryPhraseLayout(source:round.score,displayed:actual.0,bars:[1,2],fifths:round.source.fifths,clef:round.source.clef)
        let b = MemoryPhraseLayout(source:round.score,displayed:reference.0,bars:[1,2],fifths:round.source.fifths,clef:round.source.clef)
        XCTAssertEqual(a.positions,b.positions); XCTAssertEqual(a.width,b.width)
        XCTAssertEqual(a.bars[0].x+a.bars[0].width,a.bars[1].x)
        let raw = try Data(contentsOf:resources.appendingPathComponent("memory-glyphs-v1.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:raw) as? [String:Any])
        let glyphs = try XCTUnwrap(json["glyphs"] as? [String:Any]); XCTAssertEqual(glyphs.count,29)
        for key in ["note-half","note-whole","rest-quarter","clef-G","clef-F","accidental-0","flag-eighth-up","flag-eighth-down"] { XCTAssertNotNil(glyphs[key]) }
    }
}
