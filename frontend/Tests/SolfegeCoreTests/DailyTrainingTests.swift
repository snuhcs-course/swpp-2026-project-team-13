import XCTest
@testable import SolfegeCore

final class DailyTrainingTests: XCTestCase {
    private func question(level: Int, index: Int, completed: Bool? = nil, collection: String? = nil) -> QuestionSummary {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-%04d-%012d", level, index))!
        return QuestionSummary(id: id, version: 1, title: "L\(level)-\(index)", source: "test",
                               keySignature: KeySignature(tonic: "C", mode: "major", fifths: 0),
                               timeSignature: TimeSignature(numerator: 4, denominator: 4), measureCount: 8, recommendedDurationSeconds: 60,
                               collection: collection, practiceLevelNumber: level, practiceCompleted: completed)
    }
    private var bank: [QuestionSummary] { (1...9).flatMap { level in (0..<6).map { question(level: level, index: $0) } } }

    func testSetIsTwoMinigamesThenTwoPracticeQuestionsAtTheChosenLevel() {
        let plan = DailyPlanner.make(day: "2026-11-16", user: "u1", questions: bank, completed: [], level: .level3)
        XCTAssertEqual(plan.items.map(\.id), [0, 1, 2, 3])
        XCTAssertEqual(Set(plan.items.prefix(2).map(\.kind)), [.memoryRun, .rhythmPuzzle])
        XCTAssertEqual(plan.items.suffix(2).map(\.kind), [.practice, .practice])
        let picked = plan.items.suffix(2).compactMap(\.questionId)
        XCTAssertEqual(Set(picked).count, 2)
        XCTAssertTrue(picked.allSatisfy { id in bank.first { $0.id == id }?.practiceLevel == .level3 })
    }
    func testSameDayAndUserGiveTheSameSetAndOtherDaysVary() {
        let a = DailyPlanner.make(day: "2026-11-16", user: "u1", questions: bank, completed: [], level: .level5)
        XCTAssertEqual(a, DailyPlanner.make(day: "2026-11-16", user: "u1", questions: bank.reversed(), completed: [], level: .level5))
        let others = (1...20).map { DailyPlanner.make(day: String(format: "2026-12-%02d", $0), user: "u1", questions: bank, completed: [], level: .level5) }
        XCTAssertGreaterThan(Set(others.map { $0.items.compactMap(\.questionId) }).count, 1)
        XCTAssertGreaterThan(Set(others.map { $0.items[0].kind }).count, 1)
    }
    func testSolvedQuestionsAndClassicalAreSkippedAndNearbyLevelsFillTheGap() {
        var questions = bank.filter { $0.practiceLevel != .level4 }
        questions.append(question(level: 4, index: 0))
        questions.append(question(level: 4, index: 1, completed: true))
        questions.append(question(level: 4, index: 2, collection: "classical"))
        let solved = question(level: 4, index: 3); questions.append(solved)
        let plan = DailyPlanner.make(day: "2026-11-16", user: "u2", questions: questions, completed: [solved.id], level: .level4)
        let levels = plan.items.compactMap(\.questionId).map { id in questions.first { $0.id == id }!.practiceLevel.number }
        XCTAssertEqual(levels.first, 4)
        XCTAssertTrue([3, 5].contains(levels.last))
        XCTAssertFalse(plan.items.contains { [questions[questions.count - 3].id, questions[questions.count - 2].id, solved.id].contains($0.questionId) })
    }
    func testNoPracticeQuestionsLeavesOnlyTheMinigames() {
        let plan = DailyPlanner.make(day: "2026-11-16", user: "u3", questions: [], completed: [], level: .level1)
        XCTAssertEqual(plan.items.count, 2)
        XCTAssertTrue(plan.items.allSatisfy { $0.kind.isMinigame })
    }
    func testNextSkipsFinishedAndUnavailableItemsAndWrapsAround() {
        var plan = DailyPlanner.make(day: "2026-11-16", user: "u1", questions: bank, completed: [], level: .level1)
        XCTAssertEqual(plan.firstOpen(), 0)
        XCTAssertFalse(plan.hasStarted)
        plan.items[0].completed = true
        XCTAssertEqual(plan.next(after: 0), 1)
        // Started from the third item: after the fourth, the next is the open second one.
        XCTAssertEqual(plan.next(after: 3), 1)
        let offline: (DailyItem) -> Bool = { $0.kind == .memoryRun }
        let memory = plan.items.firstIndex { $0.kind == .memoryRun }!
        plan.items[0].completed = false
        XCTAssertEqual(plan.firstOpen(available: offline), memory)
        for i in plan.items.indices { plan.items[i].completed = true }
        XCTAssertTrue(plan.isComplete)
        XCTAssertNil(plan.next(after: 0))
        XCTAssertNil(plan.firstOpen())
    }
    func testDayKeyUsesTheLocalCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let lateNight = Date(timeIntervalSince1970: 1_794_841_200 - 60) // 2026-11-16 23:59 KST
        XCTAssertEqual(DailyPlanner.dayKey(lateNight, calendar: calendar), "2026-11-16")
        XCTAssertEqual(DailyPlanner.dayKey(lateNight.addingTimeInterval(120), calendar: calendar), "2026-11-17")
    }
    func testLevelsMapToMinigameDifficulty() {
        XCTAssertEqual(PracticeLevel.level3.minigameDifficulty, .beginner)
        XCTAssertEqual(PracticeLevel.level4.minigameDifficulty, .intermediate)
        XCTAssertEqual(PracticeLevel.level9.minigameDifficulty, .advanced)
    }
}
