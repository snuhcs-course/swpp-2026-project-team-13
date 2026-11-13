import Foundation

struct QuestionFilter: Equatable {
    enum KeySelection: Equatable {
        case all
        case maximumAccidentals(Int)
        case individual(Set<KeySignature>)

        var label: String {
            switch self {
            case .all: return "전체"
            case .maximumAccidentals(0): return "다장조·가단조만"
            case .maximumAccidentals(let count): return "조표 \(count)개까지"
            case .individual(let keys): return keys.count == 1 ? keys.first!.label : "\(keys.count)개 조성"
            }
        }
        func includes(_ key: KeySignature) -> Bool {
            switch self {
            case .all: return true
            case .maximumAccidentals(let count):
                // An unspecified key is not the same thing as C major / A minor.
                return ["major", "minor"].contains(key.mode) && abs(key.fifths) <= count
            case .individual(let keys): return keys.contains(key)
            }
        }
    }
    enum SortOrder: String, CaseIterable, Identifiable {
        case ascending, descending
        var id: String { rawValue }
        var label: String { self == .ascending ? "낮은순" : "높은순" }
    }
    struct KeyGroup: Identifiable {
        let fifths: Int
        let keys: [KeySignature]
        var id: Int { fifths }
        var label: String { fifths == 0 ? "조표 없음" : "\(fifths > 0 ? "♯" : "♭") \(abs(fifths))개" }
    }

    var keySelection: KeySelection = .all
    var meter: TimeSignature?
    var showCompleted = false
    var sortOrder: SortOrder = .ascending
    // Compatibility for the previous single-key picker and its callers.
    var key: KeySignature? {
        get { if case .individual(let keys) = keySelection, keys.count == 1 { return keys.first }; return nil }
        set { keySelection = newValue.map { .individual([$0]) } ?? .all }
    }
    init(key: KeySignature? = nil, meter: TimeSignature? = nil) {
        keySelection = key.map { .individual([$0]) } ?? .all
        self.meter = meter
    }
    var isActive: Bool { keySelection != .all || meter != nil }

    func apply(to questions: [QuestionSummary], completedQuestionIDs: Set<UUID> = []) -> [QuestionSummary] {
        questions.enumerated().filter { _, q in
            keySelection.includes(q.keySignature) && (meter == nil || q.timeSignature == meter) &&
                (showCompleted || (q.practiceCompleted != true && !completedQuestionIDs.contains(q.id)))
        }.sorted { lhs, rhs in
            let a = lhs.element.difficultyScore.flatMap { $0.isFinite ? $0 : nil }
            let b = rhs.element.difficultyScore.flatMap { $0.isFinite ? $0 : nil }
            // Unknown scores stay last in both directions; ties keep catalog order.
            if let a, let b, a != b { return sortOrder == .ascending ? a < b : a > b }
            if a == nil, b != nil { return false }
            if a != nil, b == nil { return true }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
    // Options come from the questions on hand, so a choice never promises a key or meter the level lacks.
    static func keyOptions(in questions: [QuestionSummary]) -> [KeySignature] {
        let modes = ["major","minor","unspecified"]
        return Set(questions.map(\.keySignature)).sorted {
            let a = modes.firstIndex(of:$0.mode) ?? modes.count, b = modes.firstIndex(of:$1.mode) ?? modes.count
            return a == b ? $0.fifths < $1.fifths : a < b
        }
    }
    static func meterOptions(in questions: [QuestionSummary]) -> [TimeSignature] {
        Set(questions.map(\.timeSignature)).sorted { $0.denominator == $1.denominator ? $0.numerator < $1.numerator : $0.denominator < $1.denominator }
    }
    static func keyGroups(in questions: [QuestionSummary]) -> [KeyGroup] {
        let keys: [KeySignature] = keyOptions(in: questions)
        let distinct: Set<Int> = Set(keys.map { $0.fifths })
        let ordered: [Int] = distinct.sorted { (lhs: Int, rhs: Int) -> Bool in
            if abs(lhs) == abs(rhs) { return lhs > rhs }
            return abs(lhs) < abs(rhs)
        }
        var groups: [KeyGroup] = []
        for fifths in ordered {
            let matching: [KeySignature] = keys.filter { $0.fifths == fifths }
            groups.append(KeyGroup(fifths: fifths, keys: matching))
        }
        return groups
    }
}
