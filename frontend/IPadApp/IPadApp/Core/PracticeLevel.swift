import Foundation

enum PracticeLevel: String, CaseIterable, Identifiable {
    case level1 = "1", level2 = "2", level3 = "3", level4 = "4", level5 = "5"
    case level6 = "6", level7 = "7", level8 = "8", level9 = "9"
    // Legacy saved questions/older servers still use the three original labels.
    static let beginner = Self.level1
    static let intermediate = Self.level5
    static let advanced = Self.level9
    var number: Int { Int(rawValue)! }
    var id: String { rawValue }
    var title: String {
        "Level \(number)"
    }
    var subtitle: String {
        switch number {
        case 1: return "짧고 단순한 선율부터"
        case 2: return "기본 음정과 리듬 익히기"
        case 3: return "조성과 리듬의 변화 듣기"
        case 4: return "조금 더 복잡한 선율 듣기"
        case 5: return "중급 청음에 도전하기"
        case 6: return "불규칙한 진행에 익숙해지기"
        case 7: return "복잡한 리듬과 음정 듣기"
        case 8: return "예측하기 어려운 선율 듣기"
        default: return "고난도 청음에 도전하기"
        }
    }
    var symbol: String {
        number <= 3 ? "music.note" : number <= 6 ? "waveform" : "music.note.list"
    }
    static func classify(id: UUID, difficulty: String?, numeric: Int? = nil) -> PracticeLevel {
        if let numeric, let level = Self(rawValue:String(numeric)) { return level }
        if let difficulty, let level = Self(rawValue:difficulty) { return level }
        if difficulty == "beginner" { return .beginner }
        if difficulty == "intermediate" { return .intermediate }
        if difficulty == "advanced" { return .advanced }
        // Original immutable questions and saved attempts predate difficulty.
        let originals = ["128f51a9-5498-50fd-a2a7-1a271883e72b", "cfe540d9-445e-59c5-9338-586fc9ba2842", "e8b704b7-efe5-583c-944a-270915628ca2"]
        return originals.contains(id.uuidString.lowercased()) ? .intermediate : .advanced
    }
}

extension QuestionSummary {
    var practiceLevel: PracticeLevel { .classify(id:id,difficulty:difficulty,numeric:practiceLevelNumber) }
}
extension Question {
    var practiceLevel: PracticeLevel { .classify(id:id,difficulty:difficulty,numeric:practiceLevelNumber) }
}

@MainActor struct PracticeQuestionList {
    var questions: [QuestionSummary]
    var lastPage: Int
    static func load(using fetch: (Int) async throws -> QuestionPage) async throws -> Self {
        var page = try await fetch(1), number = 1, questions = [QuestionSummary]()
        questions = page.results
        while page.next != nil {
            number += 1
            page = try await fetch(number)
            let fresh = page.results.filter { q in !questions.contains(where: { $0.id == q.id }) }
            guard !fresh.isEmpty else { throw SolfegeError.transport("문제 목록의 페이지를 확인해 주세요.") }
            questions.append(contentsOf:fresh)
        }
        return Self(questions:questions,lastPage:number)
    }
}
