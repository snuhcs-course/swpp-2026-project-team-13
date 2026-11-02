import XCTest
@testable import SORICore

final class ExamPlaybackStateTests: XCTestCase {
    func testAllTenWritingWaitsQueueNextSegmentWithOneAndHalfSecondLead() throws {
        for index in 1...10 {
            var cursor = PlaybackCursor(index:index,phase:"gap",remainingWaitMs:20000)
            XCTAssertTrue(cursor.canSkipForward)
            XCTAssertTrue(cursor.skipForward())
            XCTAssertEqual(cursor.index,index); XCTAssertEqual(cursor.phase,"gap")
            XCTAssertEqual(cursor.remainingWaitMs,1500); XCTAssertEqual(cursor.shortenedGap,true)
            XCTAssertEqual(cursor.nextSegmentIndex,index+1)
            let restored = try ContractJSON.decoder().decode(PlaybackCursor.self,from:ContractJSON.encoder().encode(cursor))
            XCTAssertEqual(restored,cursor)
        }
    }
    func testScaleAndLastSegmentNeverAdvancePastTheExam() {
        for (index,phase) in [(0,"initial"),(0,"segment"),(0,"gap"),(11,"segment"),(11,"gap"),(12,"gap")] {
            var cursor = PlaybackCursor(index:index,phase:phase,remainingWaitMs:20000)
            let before = cursor
            XCTAssertFalse(cursor.skipForward()); XCTAssertEqual(cursor,before)
        }
    }
    func testShortWaitsAreNeverLengthenedAndRemainingCountdownSurvivesPause() throws {
        for ms in [0,1000,1499,1500] {
            var cursor = PlaybackCursor(index:2,phase:"gap",remainingWaitMs:ms)
            XCTAssertTrue(cursor.skipForward()); XCTAssertEqual(cursor.remainingWaitMs,ms)
        }
        var cursor = PlaybackCursor(index:4,phase:"gap",remainingWaitMs:18000)
        cursor.skipForward(); cursor.remainingWaitMs = 750
        let resumed = try ContractJSON.decoder().decode(PlaybackCursor.self,from:ContractJSON.encoder().encode(cursor))
        XCTAssertEqual(resumed.remainingWaitMs,750); XCTAssertEqual(resumed.nextSegmentIndex,5)
    }
    func testLegacyCursorWithoutSkipStateStillDecodes() throws {
        let cursor = try ContractJSON.decoder().decode(PlaybackCursor.self,from:Data(#"{"index":3,"phase":"gap","remaining_wait_ms":12000}"#.utf8))
        XCTAssertNil(cursor.shortenedGap); XCTAssertTrue(cursor.canSkipForward)
    }
    func testConsecutiveTapsDuringAudioAndLeadSkipMultipleSegmentsWithoutOverflow() throws {
        var cursor = PlaybackCursor(index:1,phase:"segment")
        for target in 2...11 {
            XCTAssertTrue(cursor.skipForward())
            XCTAssertEqual(cursor.nextSegmentIndex,target)
            XCTAssertEqual(cursor.remainingWaitMs,1500)
            cursor = try ContractJSON.decoder().decode(PlaybackCursor.self,from:ContractJSON.encoder().encode(cursor))
        }
        let final = cursor
        XCTAssertFalse(cursor.skipForward()); XCTAssertEqual(cursor,final)
    }
}
