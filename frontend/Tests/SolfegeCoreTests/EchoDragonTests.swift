import XCTest
@testable import SolfegeCore

final class EchoDragonTests: XCTestCase {
    func testCurriculumExpandsOneSemitoneAtATimeAndMirrorDoesNotAddAnInterval() {
        let expected = [(1,1),(2,2),(7,3),(13,4),(19,5),(31,6),(37,7),(43,8),(49,9),(55,10),(61,11),(67,12)]
        for (number,semitones) in expected {
            let level = EchoDragonLevel(number:number)
            XCTAssertEqual(level.introducedInterval?.semitones,semitones)
            XCTAssertEqual(level.maximum,semitones)
            XCTAssertEqual(level.rule,.follow,"New intervals first use the familiar rule")
            if number > 1 { XCTAssertEqual(EchoDragonLevel(number:number-1).maximum,semitones-1) }
        }
        XCTAssertNil(EchoDragonLevel(number:25).introducedInterval)
        XCTAssertEqual(EchoDragonLevel(number:25).maximum,5)
        XCTAssertEqual(EchoDragonLevel(number:25).rule,.mirror)
    }
    func testEveryLevelHasDistinctPlayableCandidatesContainingTheExactSignedAnswer() {
        var directions: Set<Int> = []
        for number in 1...EchoDragonLevel.count {
            for variation in 0..<100 {
                let challenge = EchoDragonChallenge.make(number:number,variation:UInt64(variation))
                XCTAssertTrue((1...challenge.level.maximum).contains(challenge.interval))
                XCTAssertTrue(challenge.choices.contains(challenge.answer))
                XCTAssertEqual(Set(challenge.choices).count,challenge.choices.count)
                XCTAssertTrue((2...4).contains(challenge.choices.count))
                XCTAssertTrue(challenge.choices.allSatisfy { challenge.keyboardRange.contains($0) && (36...96).contains($0) })
                XCTAssertTrue(challenge.keyboardRange.contains(challenge.replyRoot))
                XCTAssertTrue((36...96).contains(challenge.callEnd))
                XCTAssertEqual(challenge.isCorrect(challenge.answer),true)
                XCTAssertFalse(challenge.isCorrect(challenge.answer+12),"Wrong octave must not pass")
                XCTAssertFalse(challenge.isCorrect(challenge.answer-12))
                for wrong in challenge.choices where wrong != challenge.answer { XCTAssertFalse(challenge.isCorrect(wrong)) }
                if number >= 5 { XCTAssertNotEqual(challenge.callRoot,challenge.replyRoot) }
                if number < 25 { XCTAssertEqual(challenge.callDirection,1) }
                if (25...27).contains(number) { XCTAssertLessThanOrEqual(challenge.interval,2) }
                directions.insert(challenge.replyDirection)
            }
        }
        XCTAssertEqual(directions,[-1,1])
    }
    func testMirrorReversesDirectionWhilePreservingTheDistanceAndGivenRoot() {
        for number in 25...30 {
            let challenge = EchoDragonChallenge.make(number:number)
            let call = challenge.callEnd-challenge.callRoot
            let reply = challenge.answer-challenge.replyRoot
            XCTAssertEqual(abs(reply),abs(call))
            XCTAssertEqual(reply,challenge.level.rule == .mirror ? -call : call)
        }
        XCTAssertEqual(EchoDragonChallenge.make(number:25).callDirection,1)
        XCTAssertEqual(EchoDragonChallenge.make(number:26).callDirection,-1)
    }
    func testProgressUnlocksOnlyTheNextPuzzleAndKeepsBestStarsAcrossReload() throws {
        var progress = EchoDragonProgress()
        progress.record(level:25,stars:3)
        XCTAssertEqual(progress.unlocked,1)
        for level in 1...EchoDragonLevel.count {
            XCTAssertEqual(progress.unlocked,level)
            progress.record(level:level,stars:2)
        }
        progress.record(level:1,stars:1)
        XCTAssertEqual(progress.stars[1],2)
        progress.record(level:1,stars:3)
        XCTAssertEqual(progress.stars[1],3)
        XCTAssertEqual(progress.completed,72)
        XCTAssertEqual(try EchoDragonProgress.load(JSONEncoder().encode(progress)),progress)
        XCTAssertEqual(EchoDragonProgress.earnedStars(attempts:1,hint:false),3)
        XCTAssertEqual(EchoDragonProgress.earnedStars(attempts:2,hint:false),2)
        XCTAssertEqual(EchoDragonProgress.earnedStars(attempts:1,hint:true),1)
    }
    func testInvalidStorageCannotUnlockLevelsAndCorruptJSONIsReported() throws {
        let data = Data(#"{"stars":{"0":3,"1":9,"25":3,"73":3}}"#.utf8)
        let progress = try EchoDragonProgress.load(data)
        XCTAssertEqual(progress.unlocked,1)
        XCTAssertNil(progress.stars[0]); XCTAssertNil(progress.stars[1]); XCTAssertNil(progress.stars[73])
        XCTAssertThrowsError(try EchoDragonProgress.load(Data("broken".utf8)))
    }
}
