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
    func testMinigameCoachNeverCoversTheGameScoreOrKeyboardArea() {
        for size in [CGSize(width: 1366, height: 1024), CGSize(width: 1133, height: 744), CGSize(width: 1024, height: 768), CGSize(width: 700, height: 744)] {
            for large in [false, true] {
                let layout = MiniTutorialLayout(viewport: size, largeText: large)
                let bounds = CGRect(origin: .zero, size: size)
                XCTAssertTrue(bounds.contains(layout.game)); XCTAssertTrue(bounds.contains(layout.coach))
                XCTAssertFalse(layout.game.intersects(layout.coach))
                XCTAssertGreaterThan(layout.game.height, 200)
            }
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
