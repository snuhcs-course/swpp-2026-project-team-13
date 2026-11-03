import XCTest
@testable import IPadApp

@MainActor final class MainHomeIntegrationTests: XCTestCase {
    func testConnectLandsOnHomeAndKeysKeepTheirModes() async {
        let model = AppModel(); model.demo = true; await model.connect()
        XCTAssertNil(model.error); XCTAssertEqual(model.screen, .main)
        model.navigate(.examLibrary)
        XCTAssertEqual(model.screen, .examLibrary); XCTAssertEqual(model.selectedMode, .exam)
        model.navigate(.main)
        XCTAssertEqual(model.screen, .main); XCTAssertEqual(model.selectedMode, .exam)
        model.navigate(.home)
        XCTAssertEqual(model.screen, .home); XCTAssertEqual(model.selectedMode, .practice)
    }

    func testResumeOffersExamOnlyUntilSubmitted() async throws {
        let model = AppModel(); model.demo = true; model.demoOutcome = "completed"; await model.connect()
        let summary = try XCTUnwrap(model.questions.first)
        await model.choose(summary.id, mode: .exam); await model.begin(); await model.start(); model.player.pause()
        XCTAssertNil(model.error)
        let id = try XCTUnwrap(model.session?.id)
        XCTAssertTrue(model.isUnfinished(try XCTUnwrap(model.history.first { $0.id == id })))
        await model.submit()
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isUnfinished(try XCTUnwrap(model.history.first { $0.id == id })))
    }

    func testResumeKeepsPracticeUntilSelfAssessed() async throws {
        let model = AppModel(); model.demo = true; await model.connect()
        let summary = try XCTUnwrap(model.questions.first)
        await model.choose(summary.id, mode: .practice); await model.begin(); await model.start(); model.player.pause()
        await model.submit()
        XCTAssertNil(model.error); XCTAssertEqual(model.session?.attempt.status, "submitted")
        XCTAssertTrue(model.isUnfinished(try XCTUnwrap(model.history.first { $0.id == model.session?.id })))
    }

    func testLogoutReturnsToHomeForTheNextAccount() async {
        let model = AppModel(); model.demo = true; await model.connect()
        model.navigate(.history)
        model.switchAccount()
        XCTAssertEqual(model.screen, .main)
    }
}
