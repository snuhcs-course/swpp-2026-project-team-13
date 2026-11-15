import XCTest
@testable import IPadApp

@MainActor final class DailyTrainingIntegrationTests: XCTestCase {
    private func freshModel(scope: String) async throws -> AppModel {
        let model = AppModel(demoScope: scope); model.demo = true
        await model.connect(); XCTAssertNil(model.error)
        return model
    }
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "Timed out", file: file, line: line)
    }
    private func finishPractice(_ model: AppModel) async {
        await model.begin(); await model.start(); model.player.pause(); XCTAssertNil(model.error)
        await model.submit(); XCTAssertNil(model.error)
        XCTAssertEqual(model.screen, .result)
        await model.savePracticeAssessment(completed: true); XCTAssertNil(model.error)
    }

    func testEachItemMovesOnOnlyWhenAskedAndTheSetEndsOnTheList() async throws {
        let scope = "daily-" + UUID().uuidString
        let model = try await freshModel(scope: scope)
        if let key = model.dailyStorageKey { UserDefaults.standard.removeObject(forKey: key) }
        model.openDaily()
        XCTAssertEqual(model.screen, .dailyTraining)
        let plan = try XCTUnwrap(model.daily.plan)
        XCTAssertEqual(plan.items.map(\.kind.isMinigame), [true, true, false, false])

        // Minigames open over S24, and finishing one waits for "다음 항목".
        model.startDailyItem(0)
        XCTAssertEqual(model.daily.presentedGame?.id, 0)
        model.completeDailyItem(0)
        XCTAssertEqual(model.daily.presentedGame?.id, 0)
        XCTAssertEqual(model.dailyNextTitle(after: 0), plan.items[1].title)
        model.advanceDaily()
        XCTAssertEqual(model.daily.presentedGame?.id, 1)
        model.completeDailyItem(1)

        // The next Practice item opens its own question screens; back leads to S24.
        model.advanceDaily()
        try await waitUntil { model.screen == .question }
        XCTAssertNil(model.daily.presentedGame)
        XCTAssertEqual(model.dailyPracticeItem?.id, 2)
        XCTAssertEqual(model.questionLibraryScreen, .dailyTraining)
        await finishPractice(model)
        XCTAssertEqual(model.resultLibraryScreen, .dailyTraining)
        XCTAssertEqual(model.screen, .result, "Grading never moves on by itself")
        XCTAssertEqual(model.dailyNextTitle(after: 2), plan.items[3].title)

        model.advanceDaily()
        try await waitUntil { model.screen == .question && model.selectedQuestion?.id == plan.items[3].questionId }
        await finishPractice(model)
        XCTAssertNil(model.dailyNextTitle(after: 3), "The last item's button reads 완료")
        model.advanceDaily()
        XCTAssertEqual(model.screen, .dailyTraining)
        XCTAssertNil(model.daily.activeIndex)
        XCTAssertEqual(model.daily.plan?.isComplete, true)

        // The same day keeps the same, finished set.
        let again = try await freshModel(scope: scope)
        again.openDaily()
        XCTAssertEqual(again.daily.plan, model.daily.plan)
        if let key = model.dailyStorageKey { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testLosingTheNetworkClosesOnlyServerItemsAndTheEndButtonSkipsThem() async throws {
        let model = try await freshModel(scope: "daily-offline-" + UUID().uuidString)
        if let key = model.dailyStorageKey { UserDefaults.standard.removeObject(forKey: key) }
        model.openDaily()
        let plan = try XCTUnwrap(model.daily.plan)
        let memory = try XCTUnwrap(plan.items.firstIndex { $0.kind == .memoryRun })
        let key = model.dailyStorageKey
        // A signed-in account stays "connected" when airplane mode is turned on later.
        model.demo = false; NetworkStatus.shared.online = false
        defer { model.demo = true; NetworkStatus.shared.online = true }
        XCTAssertTrue(model.dailyAvailable(plan.items[memory]))
        XCTAssertFalse(plan.items.filter { $0.kind != .memoryRun }.contains(where: model.dailyAvailable))
        XCTAssertEqual(plan.firstOpen(available: model.dailyAvailable), memory)
        XCTAssertNil(model.dailyNextTitle(after: memory), "Nothing else can open offline, so the button reads 완료")
        model.startDailyItem(try XCTUnwrap(plan.items.firstIndex { $0.kind == .practice }))
        XCTAssertNil(model.daily.activeIndex, "A closed row does not start")

        NetworkStatus.shared.online = true
        XCTAssertNotNil(model.dailyNextTitle(after: memory))
        if let key { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testLeavingAnItemKeepsItOpenAndPracticeOutsideTheSetIsUnaffected() async throws {
        let model = try await freshModel(scope: "daily-leave-" + UUID().uuidString)
        if let key = model.dailyStorageKey { UserDefaults.standard.removeObject(forKey: key) }
        model.openDaily()
        let plan = try XCTUnwrap(model.daily.plan)
        model.startDailyItem(2)
        try await waitUntil { model.screen == .question }
        XCTAssertEqual(model.dailyPracticeItem?.id, 2)
        model.navigate(model.questionLibraryScreen)
        XCTAssertEqual(model.screen, .dailyTraining)
        XCTAssertNil(model.daily.activeIndex)
        XCTAssertEqual(model.daily.plan?.completedCount, 0)

        model.startDailyItem(0); model.exitDailyItem()
        XCTAssertNil(model.daily.presentedGame)
        XCTAssertFalse(model.daily.plan?.items[0].completed ?? true, "Closing a minigame early leaves it open")

        // The same question chosen from the Practice library is not a Daily Training item.
        model.navigate(.home)
        await model.choose(try XCTUnwrap(plan.items[2].questionId), mode: .practice)
        XCTAssertNil(model.dailyPracticeItem)
        XCTAssertNotEqual(model.questionLibraryScreen, .dailyTraining)
        if let key = model.dailyStorageKey { UserDefaults.standard.removeObject(forKey: key) }
    }
}
