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
    func testBubblesStayInsideLandscapeAndSplitWindowBounds() {
        for size in [CGSize(width: 1366, height: 1024), CGSize(width: 1133, height: 744), CGSize(width: 1024, height: 600), CGSize(width: 690, height: 744)] {
            let targets: [CGRect?] = [nil,
                CGRect(x: 8, y: 8, width: size.width-16, height: 60),
                CGRect(x: size.width-180, y: size.height-70, width: 160, height: 50),
                CGRect(x: 24, y: size.height-230, width: size.width-48, height: 180)]
            for height in [CGFloat(300), CGFloat(420)] {
                for target in targets {
                    let frame = TutorialBubbleLayout(viewport: size, target: target, preferredHeight: height).frame
                    XCTAssertTrue(CGRect(origin: .zero, size: size).contains(frame))
                    XCTAssertGreaterThan(frame.width, 200)
                    XCTAssertGreaterThan(frame.height, 150)
                }
            }
        }
        let target = CGRect(x: 800, y: 680, width: 180, height: 50)
        let bubble = TutorialBubbleLayout(viewport: CGSize(width: 1024, height: 768), target: target, preferredHeight: 300).frame
        XCTAssertFalse(bubble.intersects(target), "The bubble must not cover the highlighted Start button")
    }
    func testFloatingCoachAvoidsScoreAndKeyboardWithoutAllocatingAGameColumn() {
        for size in [CGSize(width: 1366, height: 1024), CGSize(width: 1133, height: 744), CGSize(width: 1024, height: 768), CGSize(width: 700, height: 744)] {
            for large in [false, true] {
                let score = CGRect(x: 24, y: size.height*0.36, width: size.width-48, height: 140)
                let keys = CGRect(x: 24, y: size.height-245, width: size.width-48, height: 180)
                let layout = TutorialFloatingLayout(viewport: size, avoiding: [score, keys], interactive: true, largeText: large)
                let bounds = CGRect(origin: .zero, size: size)
                XCTAssertTrue(bounds.contains(layout.frame))
                XCTAssertFalse(layout.frame.intersects(score)); XCTAssertFalse(layout.frame.intersects(keys))
                XCTAssertGreaterThan(layout.frame.height, 100)
            }
        }
    }
    func testFloatingRhythmCoachLeavesTheBoardAndAllTwelveChoicesAvailable() {
        let size = CGSize(width: 1133, height: 744)
        let board = CGRect(x: 40, y: 180, width: 1053, height: 140)
        let choices = CGRect(x: 40, y: 365, width: 1053, height: 220)
        let layout = TutorialFloatingLayout(viewport: size, avoiding: [board, choices], interactive: true)
        XCTAssertFalse(layout.frame.intersects(board)); XCTAssertFalse(layout.frame.intersects(choices))
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
