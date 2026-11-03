import Foundation

struct QuestionFilter: Equatable {
    var key: KeySignature?
    var meter: TimeSignature?
    var isActive: Bool { key != nil || meter != nil }

    func apply(to questions: [QuestionSummary]) -> [QuestionSummary] {
        questions.filter { (key == nil || $0.keySignature == key) && (meter == nil || $0.timeSignature == meter) }
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
}
