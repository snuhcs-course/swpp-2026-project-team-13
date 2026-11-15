import SwiftUI

struct DailyTrainingState: Equatable {
    var plan: DailyPlan?
    // The item being played from S24. nil when the user is only looking at the list.
    var activeIndex: Int?
    // The minigame shown full screen over S24.
    var presentedGame: DailyItem?
    // A minigame to show as soon as S24 is back on screen (after a Practice item).
    var pendingGame: DailyItem?
}

// Each item uses its own screens. Daily Training only picks the set, remembers what is done,
// and opens the next item when the user taps "다음 항목".
extension AppModel {
    var dailyStorageKey: String? {
        guard let profile else { return nil }
        // Demo storage scopes (used by tests) keep separate sets.
        let origin = demo ? "demo" + (demoScope.map { ":" + $0 } ?? "") : server
        return "sori.daily.v1.\(origin).\(profile.id.uuidString.lowercased())"
    }
    // Practice keeps the level the user chose last; a new user starts at Level 1.
    var dailyPracticeLevel: PracticeLevel {
        history.first { $0.attempt.studyMode == .practice && $0.attempt.question.collection != "classical" }?.attempt.question.practiceLevel
            ?? selectedPracticeLevel ?? .level1
    }
    var dailyPracticeItem: DailyItem? {
        guard let index = daily.activeIndex, let item = daily.plan?.items[safe: index], item.kind == .practice,
              let id = selectedQuestion?.id ?? session?.attempt.question.id, item.questionId == id else { return nil }
        return item
    }
    // Memory run is bundled. Rhythm puzzle and Practice need the server, except in the local demo.
    func dailyAvailable(_ item: DailyItem) -> Bool {
        let reachable = demo || NetworkStatus.shared.online
        switch item.kind {
        case .memoryRun: return true
        case .rhythmPuzzle: return rhythmConnection != nil && reachable
        case .practice: return connected && reachable && item.questionId != nil
        }
    }
    func openDaily() {
        refreshDailyPlan()
        daily.activeIndex = nil; daily.presentedGame = nil; daily.pendingGame = nil
        navigate(.dailyTraining)
    }
    func refreshDailyPlan(now: Date = Date()) {
        guard let key = dailyStorageKey, let profile else { return }
        let day = DailyPlanner.dayKey(now)
        var plan = daily.plan?.day == day ? daily.plan
            : UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(DailyPlan.self, from: $0) }
        let practiceShort = (plan?.items.filter { $0.kind == .practice }.count ?? 0) < DailyPlanner.practiceCount
        // A set made before the question list arrived is rebuilt, but never once the user has begun it.
        if plan?.day != day || (practiceShort && plan?.hasStarted == false && !questions.isEmpty) {
            plan = DailyPlanner.make(day: day, user: profile.id.uuidString.lowercased(), questions: questions,
                                     completed: completedPracticeQuestionIDs, level: dailyPracticeLevel)
        }
        guard var current = plan else { return }
        // Practice counts as done once its self-grading is completed, wherever that happened.
        let done = completedPracticeQuestionIDs
        for i in current.items.indices where current.items[i].kind == .practice {
            if let id = current.items[i].questionId, done.contains(id) { current.items[i].completed = true }
        }
        saveDaily(current)
    }
    private func saveDaily(_ plan: DailyPlan) {
        if daily.plan != plan { daily.plan = plan }
        if let key = dailyStorageKey, let data = try? JSONEncoder().encode(plan) { UserDefaults.standard.set(data, forKey: key) }
    }
    func startDailyItem(_ index: Int) {
        guard !busy, let item = daily.plan?.items[safe: index], !item.completed, dailyAvailable(item) else { return }
        daily.activeIndex = index
        if item.kind.isMinigame {
            if screen == .dailyTraining { daily.presentedGame = item }
            else { daily.pendingGame = item; showDailyScreen() }
        } else if let id = item.questionId {
            daily.presentedGame = nil; daily.pendingGame = nil
            Task {
                await choose(id, mode: .practice)
                // A failed lookup leaves the user on S24 with nothing running.
                if screen == .dailyTraining { daily.activeIndex = nil }
            }
        }
    }
    func completeDailyItem(_ index: Int) {
        guard var plan = daily.plan, plan.items.indices.contains(index), !plan.items[index].completed else { return }
        plan.items[index].completed = true
        saveDaily(plan)
    }
    func dailyNextIndex(after index: Int) -> Int? { daily.plan?.next(after: index, available: dailyAvailable) }
    // nil means this is the last item the user can do now, so its button reads "완료".
    func dailyNextTitle(after index: Int) -> String? { dailyNextIndex(after: index).flatMap { daily.plan?.items[$0].title } }
    func advanceDaily() {
        guard let index = daily.activeIndex else { exitDailyItem(); return }
        completeDailyItem(index)
        if let next = dailyNextIndex(after: index) { startDailyItem(next) } else { exitDailyItem() }
    }
    func exitDailyItem() {
        daily.activeIndex = nil; daily.presentedGame = nil; daily.pendingGame = nil
        showDailyScreen()
    }
    private func showDailyScreen() {
        player.pause()
        if screen != .dailyTraining { screen = .dailyTraining; refreshDailyPlan() }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
