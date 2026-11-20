import Foundation

struct DrillStageQuestion: Codable, Identifiable, Equatable {
    let id: String
    var catalogId: String?
    let bpm: Double
    let questionId: String
    let sourceSha256: String
    let collection: String
    let firstMeasure: Int
    var bars: Int?
    var notes: [Int]?
}
struct DrillStageSet: Codable, Identifiable, Equatable {
    let number: Int
    let game: DrillGame
    let questions: [DrillStageQuestion]
    var id: Int { number }
}
struct DrillStageCourse: Codable {
    let version: String
    let stages: [DrillStageSet]
    func validate() throws {
        guard version == "drill-stage-sets-1", Set(stages.map(\.number)).count == stages.count else { throw invalid }
        for set in stages {
            guard let stage = DrillStairs.stage(set.number), stage.game == set.game,
                  set.questions.count == (set.game == .memoryRun ? 4 : set.game == .rhythmPuzzle ? 5 : 6),
                  Set(set.questions.map(\.id)).count == set.questions.count else { throw invalid }
            for q in set.questions {
                guard !q.id.isEmpty, q.sourceSha256.count == 64, (40...180).contains(q.bpm), q.firstMeasure>=1 else { throw invalid }
                if set.game == .echoDragon {
                    guard let notes=q.notes, notes.count==2, notes.allSatisfy({ (21...108).contains($0) }) else { throw invalid }
                } else {
                    guard q.catalogId != nil, q.bars == 2 else { throw invalid }
                }
            }
        }
    }
    private var invalid: SolfegeError { .invalidScore("스테이지 문제 구성을 확인해 주세요.") }
}
struct DrillRoundResult: Codable, Equatable {
    let accuracy: Int
    let revealed: Bool
    let elapsedMs: Int
    var correct: Bool { accuracy == 100 && !revealed }
}
struct DrillSetAttempt: Codable {
    let stage: Int
    let courseVersion: String
    let questionIds: [String]
    var results: [DrillRoundResult?]
    var index = 0
    var complete: Bool { !results.isEmpty && results.allSatisfy { $0 != nil } }
    var mastered: Bool { complete && results.allSatisfy { $0?.correct == true } }
    init(set: DrillStageSet, version: String) {
        stage=set.number; courseVersion=version; questionIds=set.questions.map(\.id)
        results=Array(repeating:nil,count:set.questions.count)
    }
    func matches(set: DrillStageSet, version: String) -> Bool {
        stage==set.number && courseVersion==version && questionIds==set.questions.map(\.id) &&
        results.count==questionIds.count && results.indices.contains(index)
    }
}
