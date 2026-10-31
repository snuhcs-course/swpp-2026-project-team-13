import XCTest
@testable import SORICore

final class ExamPlaybackStateTests: XCTestCase {
    func testAllTenWritingWaitsAdvanceAfterThreeSecondsWithoutChangingSegmentIndex() throws {
        for index in 1...10 {
            var cursor = PlaybackCursor(index:index,phase:"gap",remainingWaitMs:20000)
            XCTAssertTrue(cursor.canShortenWritingWait)
            XCTAssertTrue(cursor.shortenWritingWait())
            XCTAssertEqual(cursor.index,index); XCTAssertEqual(cursor.phase,"gap")
            XCTAssertEqual(cursor.remainingWaitMs,3000); XCTAssertEqual(cursor.shortenedGap,true)
            XCTAssertFalse(cursor.shortenWritingWait(),"A second tap must not restart the countdown")
            let restored = try ContractJSON.decoder().decode(PlaybackCursor.self,from:ContractJSON.encoder().encode(cursor))
            XCTAssertEqual(restored,cursor)
        }
    }
    func testScaleInitialAudioAndFinalWritingTimeCannotBeSkipped() {
        for (index,phase) in [(0,"initial"),(0,"gap"),(1,"segment"),(11,"gap"),(12,"gap")] {
            var cursor = PlaybackCursor(index:index,phase:phase,remainingWaitMs:20000)
            let before = cursor
            XCTAssertFalse(cursor.shortenWritingWait()); XCTAssertEqual(cursor,before)
        }
    }
    func testShortWaitsAreNeverLengthenedAndRemainingCountdownSurvivesPause() throws {
        for ms in [0,1000,2999,3000] {
            var cursor = PlaybackCursor(index:2,phase:"gap",remainingWaitMs:ms)
            XCTAssertFalse(cursor.shortenWritingWait()); XCTAssertEqual(cursor.remainingWaitMs,ms)
        }
        var cursor = PlaybackCursor(index:4,phase:"gap",remainingWaitMs:18000)
        cursor.shortenWritingWait(); cursor.remainingWaitMs = 1500
        let resumed = try ContractJSON.decoder().decode(PlaybackCursor.self,from:ContractJSON.encoder().encode(cursor))
        XCTAssertEqual(resumed.remainingWaitMs,1500); XCTAssertFalse(resumed.canShortenWritingWait)
    }
    func testLegacyCursorWithoutSkipStateStillDecodes() throws {
        let cursor = try ContractJSON.decoder().decode(PlaybackCursor.self,from:Data(#"{"index":3,"phase":"gap","remaining_wait_ms":12000}"#.utf8))
        XCTAssertNil(cursor.shortenedGap); XCTAssertTrue(cursor.canShortenWritingWait)
    }
}
