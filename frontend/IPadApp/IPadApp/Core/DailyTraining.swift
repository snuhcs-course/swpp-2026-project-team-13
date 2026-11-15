import Foundation

// Daily Training: two minigame rounds and two Practice questions, fixed for one local day.
enum DailyItemKind: String, Codable, Equatable {
    case memoryRun, rhythmPuzzle, practice
    var isMinigame: Bool { self != .practice }
    var typeLabel: String { isMinigame ? "미니게임" : "Practice" }
}

struct DailyItem: Codable, Equatable, Identifiable {
    var id: Int
    var kind: DailyItemKind
    var title: String
    var questionId: UUID? = nil
    var completed = false
}

struct DailyPlan: Codable, Equatable {
    var day: String
    var items: [DailyItem]
    var completedCount: Int { items.filter(\.completed).count }
    var isComplete: Bool { !items.isEmpty && items.allSatisfy(\.completed) }
    var hasStarted: Bool { items.contains(where: \.completed) }

    // The first unfinished item the user can open now.
    func firstOpen(available: (DailyItem) -> Bool = { _ in true }) -> Int? {
        items.firstIndex { !$0.completed && available($0) }
    }
    // The next unfinished item after `index`, then any earlier one that is still open.
    func next(after index: Int, available: (DailyItem) -> Bool = { _ in true }) -> Int? {
        let order = Array(items.indices.dropFirst(index + 1)) + Array(items.indices.prefix(index))
        return order.first { !items[$0].completed && available(items[$0]) }
    }
}

enum DailyPlanner {
    static let minigames: [(DailyItemKind, String)] = [(.memoryRun, "Memory run"), (.rhythmPuzzle, "Rhythm puzzle")]
    static let practiceCount = 2

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    // Stable across launches (Hasher is not), so the same user sees the same set all day.
    static func seed(day: String, user: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in "\(day)|\(user)".utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
        return hash
    }
    // Practice comes from the level the user practiced last, widening to nearby levels if that runs out.
    static func practiceCandidates(_ questions: [QuestionSummary], completed: Set<UUID>, level: PracticeLevel) -> [[QuestionSummary]] {
        let open = questions.filter { $0.collection != "classical" && !completed.contains($0.id) && $0.practiceCompleted != true }
        let levels = PracticeLevel.allCases.sorted {
            let a = abs($0.number - level.number), b = abs($1.number - level.number)
            return a == b ? $0.number > $1.number : a < b
        }
        return levels.map { l in open.filter { $0.practiceLevel == l }.sorted { $0.id.uuidString < $1.id.uuidString } }.filter { !$0.isEmpty }
    }
    static func make(day: String, user: String, questions: [QuestionSummary], completed: Set<UUID>, level: PracticeLevel) -> DailyPlan {
        var rng = SeededGenerator(seed: seed(day: day, user: user))
        var items = minigames.shuffled(using: &rng).map { DailyItem(id: 0, kind: $0.0, title: $0.1) }
        var picked: [QuestionSummary] = []
        for group in practiceCandidates(questions, completed: completed, level: level) where picked.count < practiceCount {
            picked += group.shuffled(using: &rng).prefix(practiceCount - picked.count)
        }
        items += picked.map { DailyItem(id: 0, kind: .practice, title: $0.title, questionId: $0.id) }
        for i in items.indices { items[i].id = i }
        return DailyPlan(day: day, items: items)
    }
}

// SplitMix64: small, deterministic and good enough for picking a daily set.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

extension PracticeLevel {
    // Minigames have three difficulties; Practice has nine levels.
    var minigameDifficulty: MemoryDifficulty { number <= 3 ? .beginner : number <= 6 ? .intermediate : .advanced }
}
