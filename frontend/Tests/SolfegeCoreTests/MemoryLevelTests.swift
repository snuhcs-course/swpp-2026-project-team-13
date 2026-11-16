import XCTest
@testable import SolfegeCore

final class MemoryLevelTests: XCTestCase {
    private func intervals(_ level: MemoryLevel) -> [Int] { zip(level.degrees,level.degrees.dropFirst()).map { abs($1-$0) } }

    func testMilestonesMatchTheUATLevels() throws {
        let one = MemoryLevel.level(1)
        XCTAssertEqual(one.bars,1); XCTAssertEqual(one.noteCount,3); XCTAssertEqual(one.fifths,0)
        XCTAssertEqual(Set(intervals(one)),[1])
        XCTAssertEqual(MemoryLevel.level(6).noteCount,3); XCTAssertEqual(MemoryLevel.level(7).noteCount,4)
        XCTAssertEqual(MemoryLevel.level(12).bars,1); XCTAssertEqual(MemoryLevel.level(13).bars,2)
        for n in 1...18 { XCTAssertEqual(Set(intervals(.level(n))),[1],"level \(n) must be stepwise") }
        XCTAssertTrue(intervals(.level(19)).contains(3))
        for n in 1...24 { XCTAssertFalse(MemoryLevel.level(n).durations.joined().contains(240)) }
        XCTAssertTrue(MemoryLevel.level(25).durations.joined().contains(240))
        for n in 1...30 { XCTAssertEqual(MemoryLevel.level(n).fifths,0) }
        XCTAssertEqual(MemoryLevel.level(31).fifths,1); XCTAssertEqual(MemoryLevel.level(32).fifths,-1)
        XCTAssertEqual(MemoryLevel.level(36).bars,2); XCTAssertEqual(MemoryLevel.level(37).bars,4)
        XCTAssertEqual(Set(MemoryLevel.all.map(\.signature)).count,MemoryLevel.count)
    }

    func testEveryLevelBuildsAFullPlayableRound() throws {
        for level in MemoryLevel.all {
            let round = try MelodyRound(source:level.source,start:1,bars:level.bars)
            XCTAssertEqual(round.targets.map(\.midi),level.midis)
            for bar in 1...level.bars {
                XCTAssertEqual(round.score.symbols.filter { $0.measure == bar }.reduce(0) { $0+$1.duration },1920)
            }
            // The guided first note is not graded; at least two graded notes allow a fail and a pass.
            XCTAssertGreaterThanOrEqual(level.noteCount-1,2)
        }
    }

    func testOnlyAPassUnlocksExactlyTheNextLevelAndNothingRelocks() {
        var progress = MemoryLevelProgress()
        XCTAssertFalse(progress.record(level:1,accuracy:79)); XCTAssertEqual(progress.unlocked,1)
        XCTAssertTrue(progress.record(level:1,accuracy:80)); XCTAssertEqual(progress.unlocked,2)
        XCTAssertTrue(progress.record(level:2,accuracy:100)); XCTAssertEqual(progress.unlocked,3)
        progress.record(level:1,accuracy:0)
        XCTAssertEqual(progress.unlocked,3); XCTAssertEqual(progress.best[1],80); XCTAssertEqual(progress.cleared,[1,2])
    }
}
