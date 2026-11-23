import XCTest
import CoreGraphics
@testable import SolfegeCore

final class TutorialProgressTests: XCTestCase {
    func testCompletionIsIsolatedByAccountAndGameAndSurvivesReopening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let alice = TutorialProgressStore(root: root.appendingPathComponent("server-a-alice"))
        let bob = TutorialProgressStore(root: root.appendingPathComponent("server-a-bob"))
        let otherServer = TutorialProgressStore(root: root.appendingPathComponent("server-b-alice"))
        XCTAssertFalse(alice.hasSeen(.memoryRun))
        try alice.markSeen(.memoryRun)
        XCTAssertTrue(TutorialProgressStore(root: alice.root).hasSeen(.memoryRun))
        XCTAssertFalse(alice.hasSeen(.rhythmPuzzle))
        XCTAssertFalse(bob.hasSeen(.memoryRun))
        XCTAssertFalse(otherServer.hasSeen(.memoryRun))
        try alice.markSeen(.exam)
        XCTAssertTrue(alice.hasSeen(.memoryRun))
        XCTAssertTrue(alice.hasSeen(.exam))
        try FileManager.default.removeItem(at: alice.root)
        XCTAssertFalse(alice.hasSeen(.exam), "Deleting the local account also deletes its tutorial history")
    }
    func testDamagedHistoryIsNotSilentlyOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("tutorial-overlays-v2.json")
        try Data("not-json".utf8).write(to: file)
        let store = TutorialProgressStore(root: root)
        XCTAssertFalse(store.hasSeen(.exam))
        XCTAssertThrowsError(try store.markSeen(.exam))
        XCTAssertEqual(try Data(contentsOf: file), Data("not-json".utf8))
    }
    func testButtonGuidesStayDirectlyAboveTheirButtonsAcrossIPads() {
        for size in [CGSize(width: 1366, height: 1024), CGSize(width: 1133, height: 744), CGSize(width: 1024, height: 600), CGSize(width: 690, height: 744)] {
            let start = CGRect(x: size.width-180, y: size.height-100, width: 150, height: 54)
            let replay = CGRect(x: 28, y: size.height-100, width: 114, height: 54)
            for (page, target) in [(1, start), (2, replay)] {
                let layout = TutorialPopupLayout(kind: .memoryRun, page: page, viewport: size, anchors: [.start: start, .replay: replay])
                XCTAssertTrue(layout.isResolved)
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(layout.frame))
                XCTAssertEqual(layout.frame.maxY, target.minY-14, accuracy: 0.5)
                XCTAssertFalse(layout.frame.intersects(target))
            }
        }
    }
    func testMemoryInputAndEditingShareTheGapBetweenScoreAndKeys() {
        for size in [CGSize(width: 1366, height: 1024), CGSize(width: 1133, height: 744), CGSize(width: 1024, height: 600), CGSize(width: 700, height: 744)] {
            let score = CGRect(x: 24, y: size.height*0.18, width: size.width-48, height: size.height*0.16)
            let keys = CGRect(x: 24, y: size.height-245, width: size.width-48, height: 180)
            for large in [false, true] {
                let a = TutorialPopupLayout(kind: .memoryRun, page: 3, viewport: size, anchors: [.notation: score, .keyboard: keys], largeText: large)
                let b = TutorialPopupLayout(kind: .memoryRun, page: 4, viewport: size, anchors: [.notation: score, .keyboard: keys], largeText: large)
                XCTAssertEqual(a.frame, b.frame)
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(a.frame))
                XCTAssertGreaterThanOrEqual(a.frame.minY, score.maxY)
                XCTAssertLessThanOrEqual(a.frame.maxY, keys.minY)
            }
        }
    }
    func testRhythmInputIsAboveTheStaffAndTieGuideStaysAtTheTieButton() {
        let size = CGSize(width: 1133, height: 744)
        let board = CGRect(x: 40, y: 180, width: 1053, height: 140)
        let choices = CGRect(x: 40, y: 355, width: 1053, height: 208)
        let tie = CGRect(x: 850, y: 590, width: 54, height: 54)
        let anchors: [TutorialTarget: CGRect] = [.notation: board, .choices: choices, .tie: tie]
        let input = TutorialPopupLayout(kind: .rhythmPuzzle, page: 3, viewport: size, anchors: anchors)
        XCTAssertLessThan(input.frame.maxY, board.minY)
        XCTAssertFalse(input.frame.intersects(choices))
        let connection = TutorialPopupLayout(kind: .rhythmPuzzle, page: 5, viewport: size, anchors: anchors)
        XCTAssertEqual(connection.frame.maxY, tie.minY-14, accuracy: 0.5)
        XCTAssertGreaterThan(connection.frame.minY, board.maxY)
    }
    func testMissingNextButtonIsNeverSubstitutedWithTheProgressBar() {
        let size = CGSize(width: 1133, height: 744)
        let progress = CGRect(x: 350, y: 40, width: 500, height: 36)
        XCTAssertFalse(TutorialPopupLayout(kind: .exam, page: 6, viewport: size, anchors: [.progress: progress]).isResolved)
        let next = CGRect(x: 730, y: 650, width: 150, height: 54)
        let layout = TutorialPopupLayout(kind: .exam, page: 6, viewport: size, anchors: [.progress: progress, .next: next])
        XCTAssertTrue(layout.isResolved)
        XCTAssertEqual(layout.frame.maxY, next.minY-14, accuracy: 0.5)
    }
    func testTutorialCountInUsesTheOriginalClickPitchAndActualMeter() {
        for meter in [TimeSignature(numerator: 4, denominator: 4), .init(numerator: 3, denominator: 4), .init(numerator: 6, denominator: 8)] {
            let lead = TutorialCountIn(meter: meter, enabled: true)
            XCTAssertEqual(lead.ticks, meter.ticksPerMeasure)
            XCTAssertEqual(lead.clicks.count, meter.numerator)
            XCTAssertTrue(lead.clicks.allSatisfy { $0.midi == 60 && $0.duration == 40 })
            XCTAssertEqual(lead.clicks.map(\.onset), (0..<meter.numerator).map { $0*1920/meter.denominator })
            XCTAssertEqual(TutorialCountIn(meter: meter, enabled: false).ticks, 0)
            XCTAssertTrue(TutorialCountIn(meter: meter, enabled: false).clicks.isEmpty)
        }
    }
    func testTutorialPauseFreezesTheClockAndRepeatedOpenDoesNotAddTime() {
        var clock = AdvisoryClock()
        clock.secondsAtSync = 120; clock.uptimeAtSync = 100
        XCTAssertEqual(clock.remaining(uptime: 110), 110)
        clock.pause(uptime: 110); clock.pause(uptime: 140)
        XCTAssertEqual(clock.remaining(uptime: 210), 110)
        clock.resume(uptime: 210); clock.resume(uptime: 211)
        XCTAssertEqual(clock.remaining(uptime: 215), 105)
        clock.pause(uptime: 220)
        XCTAssertEqual(clock.remaining(uptime: 500), 100)
    }
}
