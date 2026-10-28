import XCTest
@testable import SORICore

final class MelodyRunTests: XCTestCase {
    private var resources: URL {
        URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("IPadApp/IPadApp/Resources")
    }
    private func source(_ id: String = "Batchellor-Charmbury-1884a_1-1-018") throws -> MelodySource {
        try MelodyXMLParser.parse(Data(contentsOf:resources.appendingPathComponent("melody--"+id+".xml")))
    }
    func testEveryBundledExerciseParsesWithExactMetadataAndFullMeasures() throws {
        let catalog = try JSONDecoder().decode([MelodyQuestion].self,from:Data(contentsOf:resources.appendingPathComponent("melody-catalog.json")))
        XCTAssertFalse(catalog.isEmpty)
        for question in catalog {
            do {
                let source = try MelodyXMLParser.parse(Data(contentsOf:resources.appendingPathComponent(question.file)))
                let score = source.score
                XCTAssertEqual(score.measures,8,question.id)
                XCTAssertEqual(score.timeSignature.numerator,question.beats,question.id)
                XCTAssertEqual(score.timeSignature.denominator,question.beatType,question.id)
                XCTAssertEqual(score.symbols.filter { $0.midi != nil && !$0.tieStop }.count,question.noteCount,question.id)
                XCTAssertEqual(score.symbols.compactMap(\.midi).min(),question.lowestMidi,question.id)
                XCTAssertEqual(score.symbols.compactMap(\.midi).max(),question.highestMidi,question.id)
                for bar in 1...8 { XCTAssertEqual(score.symbols.filter { $0.measure == bar }.reduce(0) { $0+$1.duration },score.ticksPerMeasure,question.id) }
                for length in [2,4,8] {
                    let round = try MelodyRound(source:source,start:9-length,bars:length)
                    var answers = MelodyAnswers(round:round)
                    for bar in 1...length {
                        for i in round.targetIndices(measure:bar) { answers.enter(round.targets[i].midi,measure:bar) }
                    }
                    XCTAssertEqual(answers.result.accuracy,100,question.id)
                    XCTAssertEqual(round.events(answers:answers.pitches),round.score.events.filter { $0.midi != nil },question.id)
                }
            } catch { XCTFail("\(question.id): \(error)") }
        }
    }
    func testMemoryTimelineHasConfigurableGapsAndNoTimedInput() throws {
        let round = try MelodyRound(source:source(),start:1,bars:4)
        var settings = MelodySettings(); settings.gapBeats = 3
        let timeline = MelodyTimeline(round:round,settings:settings)
        XCTAssertEqual(timeline.windows.filter { $0.phase == .listen }.count,4)
        XCTAssertEqual(timeline.windows.filter { $0.phase == .beat }.map { $0.end-$0.start },[1440,1440,1440,1440])
        XCTAssertFalse(timeline.windows.contains { $0.phase == .input })
        XCTAssertEqual(timeline.end,round.score.ticksPerMeasure*5+4*3*480)
        for pair in zip(timeline.windows,timeline.windows.dropFirst()) { XCTAssertEqual(pair.0.end,pair.1.start) }
    }
    func testGrooveEarlyCompletionKeepsClockAndNextBeatWithoutOverlappingWindows() throws {
        let round = try MelodyRound(source:source(),start:1,bars:2)
        var settings = MelodySettings(); settings.mode = .groove; settings.inputBars = 2
        var timeline = MelodyTimeline(round:round,settings:settings)
        let index = try XCTUnwrap(timeline.windows.firstIndex { $0.phase == .input })
        let start = timeline.windows[index].start, originalEnd = timeline.end
        XCTAssertTrue(timeline.shortenInput(at:index,now:start+100,lead:96))
        XCTAssertEqual(timeline.windows[index].end,start+480)
        XCTAssertEqual(timeline.windows[index+1].start,start+480)
        XCTAssertEqual(timeline.windows[index+1].phase,.listen)
        XCTAssertLessThan(timeline.end,originalEnd)
        for pair in zip(timeline.windows,timeline.windows.dropFirst()) { XCTAssertEqual(pair.0.end,pair.1.start) }
        XCTAssertFalse(timeline.shortenInput(at:index,now:timeline.windows[index].end-10,lead:96))
    }
    func testCompoundMeterUsesDottedQuarterPulseAndQuarterBPM() throws {
        let catalog = try JSONDecoder().decode([MelodyQuestion].self,from:Data(contentsOf:resources.appendingPathComponent("melody-catalog.json")))
        let question = try XCTUnwrap(catalog.first { $0.beats == 6 && $0.beatType == 8 })
        let source = try source(question.id)
        let round = try MelodyRound(source:source,start:1,bars:2)
        let timeline = MelodyTimeline(round:round,settings:MelodySettings())
        XCTAssertEqual(timeline.pulseTicks,720)
        XCTAssertEqual(timeline.windows.first?.end,1440)
    }
    func testUndoAcrossMemoryBarsAndNoMutationOfTimedOutGrooveBar() throws {
        let round = try MelodyRound(source:source(),start:1,bars:2)
        var answers = MelodyAnswers(round:round)
        for i in round.targetIndices(measure:1) { answers.enter(round.targets[i].midi,measure:1) }
        let before = answers.pitches
        XCTAssertNil(answers.undo(in:2)); XCTAssertEqual(answers.pitches,before)
        XCTAssertEqual(answers.undo(),1)
        XCTAssertNotNil(answers.next(in:1))
        answers.clear(measure:1); XCTAssertTrue(answers.pitches.allSatisfy { $0 == nil })
    }
    func testMissingNotesAndOctaveMistakesBreakCombo() {
        let result = MelodyResult(expected:[60,62,64,65,67],actual:[60,62,76,nil,67])
        XCTAssertEqual(result.accuracy,60); XCTAssertEqual(result.correct,3)
        XCTAssertEqual(result.bestCombo,2); XCTAssertEqual(result.points,310)
    }
    func testPendingScoreNeverDisclosesOriginalPitchesAndRetainsAllRhythms() throws {
        let round = try MelodyRound(source:source(),start:1,bars:2)
        let answers = MelodyAnswers(round:round)
        let display = round.display(measure:1,answers:answers.pitches)
        XCTAssertTrue(display.0.symbols.filter { $0.midi != nil }.allSatisfy { $0.midi == 71 })
        XCTAssertEqual(display.0.symbols.map(\.duration),round.score.symbols.filter { $0.measure == 1 }.map(\.duration))
    }
    func testBlackKeyHitRegionsAndLowerWhiteKeyRegion() {
        let geometry = PianoGeometry(range:60...84)
        let black = geometry.keys.first { $0.midi == 61 }!
        XCTAssertEqual(geometry.key(x:black.x+black.width/2,y:0.3),61)
        XCTAssertNotEqual(geometry.key(x:black.x+black.width/2,y:0.8),61)
        XCTAssertEqual(geometry.key(x:0.01,y:0.9),60)
        XCTAssertNil(geometry.key(x:-0.01,y:0.5))
        XCTAssertEqual(geometry.keys.filter(\.black).count,10)
    }
    func testUnsafeXMLAndIncompletePhraseAreRejected() throws {
        let valid = try Data(contentsOf:resources.appendingPathComponent("melody--Batchellor-Charmbury-1884a_1-1-018.xml"))
        let text = String(decoding:valid,as:UTF8.self)
        let unsafe = text.replacingOccurrences(of:"<score-partwise",with:"<!DOCTYPE score-partwise [<!ENTITY e SYSTEM 'file:///private'>]><score-partwise")
        XCTAssertThrowsError(try MelodyXMLParser.parse(Data(unsafe.utf8)))
        XCTAssertThrowsError(try MelodyXMLParser.parse(Data(text.replacingOccurrences(of:"<duration>256</duration>",with:"<duration>128</duration>").utf8)))
    }
}
