import XCTest
@testable import SORICore

final class MemorySessionTests: XCTestCase {
    private var resources: URL {
        URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("IPadApp/IPadApp/Resources")
    }
    private func catalog() throws -> MemoryCatalog {
        try JSONDecoder().decode(MemoryCatalog.self,from:Data(contentsOf:resources.appendingPathComponent("memory-run-v2.json")))
    }
    struct Seeded: RandomNumberGenerator {
        var value: UInt64 = 42
        mutating func next() -> UInt64 { value = value &* 6364136223846793005 &+ 1442695040888963407; return value }
    }
    func testFourRoundPlansAndOverlappingWeights() throws {
        let bank = try catalog(); try bank.validate()
        XCTAssertEqual(bank.sources.count,967)
        XCTAssertEqual(bank.sources.filter { $0.collection == "classical" }.count,33)
        XCTAssertEqual(bank.sources.filter { $0.collection == "intermediate" }.count,11)
        var rng = Seeded()
        for level in MemoryDifficulty.allCases {
            for _ in 0..<20 {
                let set = try bank.makeSet(level:level,using:&rng)
                XCTAssertEqual(set.map(\.bars),level.barPlan)
                XCTAssertEqual(Set(set.map(\.sourceId)).count,4)
                XCTAssertEqual(Set(set.map(\.fingerprint)).count,4)
                if level == .beginner {
                    XCTAssertTrue(set.allSatisfy(\.beginnerEligible))
                    XCTAssertTrue(set.prefix(2).allSatisfy { $0.attacks <= 5 && $0.pitchRange <= 5 && $0.largestInterval <= 2 })
                }
            }
            for score in stride(from:0.0,through:100.0,by:5) { XCTAssertGreaterThan(level.weight(score:score),0) }
        }
        XCTAssertEqual(MemoryDifficulty.beginner.quarterBpm,60)
        XCTAssertEqual(MemoryDifficulty.intermediate.barPlan,[2,2,4,4])
        XCTAssertEqual(MemoryDifficulty.advanced.quarterBpm,96)
        XCTAssertEqual(MemoryDifficulty.intermediate.tempoLabel(for:TimeSignature(numerator:6,denominator:8)),"♩. = 56")
    }
    func testAllFrozenExcerptsParsePreserveSoundAndProtectTheGivenFirstNote() throws {
        let bank = try catalog()
        for q in bank.sources {
            let data = try Data(contentsOf:resources.appendingPathComponent(q.file))
            XCTAssertEqual(data.sha256,q.sha256)
            let source = try MelodyXMLParser.parse(data)
            for excerpt in bank.excerpts.filter({ $0.sourceId == q.id }) {
                let round = try MelodyRound(source:source,start:excerpt.first,bars:excerpt.bars)
                XCTAssertEqual(round.targets.count,excerpt.attacks,excerpt.id)
                var answers = MelodyAnswers(round:round,provideFirst:true)
                let first = try XCTUnwrap(round.targets.first)
                XCTAssertEqual(answers.pitches.first ?? nil,first.midi)
                answers.clear(measure:first.measure)
                XCTAssertEqual(answers.pitches.first ?? nil,first.midi)
                XCTAssertNil(answers.undo())
                for bar in 1...round.score.measures {
                    while let i = answers.next(in:bar) { answers.enter(round.targets[i].midi,measure:bar) }
                }
                XCTAssertEqual(answers.result.accuracy,100,excerpt.id)
                XCTAssertEqual(answers.result.expected.count,excerpt.attacks-1,excerpt.id)
                XCTAssertEqual(round.events(answers:answers.pitches),round.score.events.filter { $0.midi != nil },excerpt.id)
                for bar in 1...round.score.measures {
                    let spacing = MelodyBarSpacing(symbols:round.score.symbols.filter { $0.measure == bar },fifths:source.fifths,clef:source.clef)
                    XCTAssertTrue(spacing.width.isFinite && spacing.height.isFinite)
                    XCTAssertGreaterThan(spacing.height,90)
                }
            }
        }
    }
    func testBeginnerHasShortWhiteKeyPhrasesAndOnlyAHandfulOfAnswers() throws {
        let bank = try catalog()
        let simple = bank.excerpts.filter(\.beginnerEligible)
        XCTAssertGreaterThan(simple.count,50)
        for e in simple {
            XCTAssertEqual(e.bars,2); XCTAssertTrue((3...8).contains(e.attacks)); XCTAssertLessThanOrEqual(e.pitchRange,7)
            let q = try XCTUnwrap(bank.sources.first { $0.id == e.sourceId })
            XCTAssertEqual(q.fifths,0); XCTAssertEqual(q.mode,"major")
            let source = try MelodyXMLParser.parse(Data(contentsOf:resources.appendingPathComponent(q.file)))
            let round = try MelodyRound(source:source,start:e.first,bars:2)
            XCTAssertTrue(round.targets.allSatisfy { (60...72).contains($0.midi) && [0,2,4,5,7,9,11].contains($0.midi % 12) })
            XCTAssertEqual(MelodyAnswers(round:round,provideFirst:true).result.expected.count,e.attacks-1)
        }
    }
}
