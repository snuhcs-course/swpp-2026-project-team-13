import Foundation

enum PracticeLevel: String, CaseIterable, Identifiable {
    case beginner, intermediate, advanced
    var id: String { rawValue }
    var title: String {
        switch self { case .beginner: return "초급"; case .intermediate: return "중급"; case .advanced: return "고급" }
    }
    var subtitle: String {
        switch self {
        case .beginner: return "다양한 조성과 기본 리듬으로 귀를 열어요."
        case .intermediate: return "익숙한 청음 연습과 Pages 선율을 풀어보세요."
        case .advanced: return "임시표·셋잇단음표·당김음에 도전해요."
        }
    }
    var symbol: String {
        switch self { case .beginner: return "music.note"; case .intermediate: return "waveform"; case .advanced: return "music.note.list" }
    }
    static func classify(id: UUID, difficulty: String?) -> PracticeLevel {
        if let difficulty, let level = Self(rawValue:difficulty) { return level }
        // Original immutable questions and saved attempts predate difficulty.
        let originals = ["128f51a9-5498-50fd-a2a7-1a271883e72b", "cfe540d9-445e-59c5-9338-586fc9ba2842", "e8b704b7-efe5-583c-944a-270915628ca2"]
        return originals.contains(id.uuidString.lowercased()) ? .intermediate : .advanced
    }
}

extension QuestionSummary {
    var practiceLevel: PracticeLevel { .classify(id:id,difficulty:difficulty) }
}
extension Question {
    var practiceLevel: PracticeLevel { .classify(id:id,difficulty:difficulty) }
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
            guard !fresh.isEmpty else { throw SORIError.transport("문제 목록의 페이지를 확인해 주세요.") }
            questions.append(contentsOf:fresh)
        }
        return Self(questions:questions,lastPage:number)
    }
}
