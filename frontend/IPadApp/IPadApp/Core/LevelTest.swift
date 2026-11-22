import Foundation

/// Server-owned progress of the first-Exam level test (`GET exam/level-test/`).
struct LevelTestState: Codable, Equatable {
    struct Stage: Codable, Equatable {
        var stage: Int; var tier: String; var attemptId: UUID
        var grade: Int?; var passed: Bool?
    }
    var version: String
    var status: String
    var passGrade: Int
    var skipRating: Double
    var stages: [Stage]
    var nextStage: Int?
    var canFinish: Bool
    var rating: Double?

    static let statuses: Set<String> = ["required", "in_progress", "completed", "skipped", "not_applicable"]
    /// Connections without level test support keep the regular Exam flow.
    static let notApplicable = LevelTestState(version:"", status:"not_applicable", passGrade:80, skipRating:0,
                                              stages:[], nextStage:nil, canFinish:false, rating:nil)

    var needsLevelTest: Bool { status == "required" || status == "in_progress" }
    /// The attempt of a stage that is still being solved or graded.
    var unresolvedAttemptId: UUID? { status == "in_progress" && stages.last?.grade == nil ? stages.last?.attemptId : nil }

    func validate() throws {
        let valid = Self.statuses.contains(status) && (0...100).contains(passGrade) && skipRating.isFinite && skipRating >= 0
            && stages.count <= LevelTestTier.all.count
            && stages.enumerated().allSatisfy { index, item in
                item.stage == index+1 && item.tier == LevelTestTier.all[index].id
                    && (item.grade.map { (0...100).contains($0) } ?? true)
                    && item.passed == item.grade.map { $0 >= passGrade }
            }
            && (rating.map { $0.isFinite && $0 >= 0 } ?? true)
            && (nextStage.map { (1...LevelTestTier.all.count).contains($0) && $0 == stages.count+1 } ?? true)
            && (status != "in_progress" || !stages.isEmpty)
            && (status != "required" || stages.isEmpty)
        guard valid else { throw SolfegeError.transport("레벨 테스트 정보를 확인하지 못했습니다.") }
    }

    /// Which level test screen the app shows for this state.
    var phase: LevelTestPhase {
        switch status {
        case "required": return .intro
        case "completed", "skipped": return rating.map { .rating($0) } ?? .none
        case "in_progress":
            guard let last = stages.last else { return .intro }
            guard let grade = last.grade else { return .grading(stage:last.stage) }
            if nextStage != nil { return .offer(stage:last.stage, grade:grade) }
            return .ended(stage:last.stage, grade:grade, passed:grade >= passGrade)
        default: return .none
        }
    }
}

enum LevelTestPhase: Equatable {
    case intro
    /// The stage's answer is being solved or AI-graded.
    case grading(stage: Int)
    /// The stage passed and a harder one is offered.
    case offer(stage: Int, grade: Int)
    /// No further stage: missed the pass grade or the hardest stage is done.
    case ended(stage: Int, grade: Int, passed: Bool)
    case rating(Double)
    case none
}

/// The question the server fixed for the next stage (`POST exam/level-test/next/`).
struct LevelTestQuestion: Codable, Equatable {
    var stage: Int; var tier: String
    var questionId: UUID; var questionVersion: Int; var difficultyScore: Double
    func validate() throws {
        guard (1...LevelTestTier.all.count).contains(stage), LevelTestTier.all[stage-1].id == tier,
              questionVersion > 0, difficultyScore.isFinite, difficultyScore >= 0 else {
            throw SolfegeError.transport("레벨 테스트 문제 정보를 확인하지 못했습니다.")
        }
    }
}

/// Frozen on a level-test attempt's rating snapshot.
struct LevelTestSnapshot: Codable, Equatable {
    var version: String; var stage: Int; var tier: String
}

struct LevelTestTier: Equatable {
    var id: String; var name: String
    static let all = [LevelTestTier(id:"easy", name:"쉬운"), LevelTestTier(id:"medium", name:"중간"), LevelTestTier(id:"hard", name:"고급")]
    static func forStage(_ stage: Int) -> LevelTestTier? { all.indices.contains(stage-1) ? all[stage-1] : nil }
    /// "1단계 · 쉬운 문제"
    static func stageTitle(_ stage: Int) -> String { "\(stage)단계 · \(forStage(stage)?.name ?? "") 문제" }
}
