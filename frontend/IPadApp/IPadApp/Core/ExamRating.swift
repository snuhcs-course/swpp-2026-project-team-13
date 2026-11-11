import Foundation

struct ExamRatingSnapshot: Codable, Equatable {
    var modelVersion: String; var poolVersion: String
    var difficultyVersion: String; var difficultyScore: Double
}

struct ExamRatingState: Codable, Equatable {
    var value: Double = 7
    var completed: Int = 0
    var modelVersion: String = ExamRatingModel.version
}
struct ExamChoice: Codable, Identifiable, Equatable {
    var category: String
    var questionId: UUID?
    var questionVersion: Int?
    var difficultyScore: Double?
    var ratingDifference: Double?
    var reason: String?
    var id: String { category }
    var title: String { ["challenge":"도전 문제", "matched":"적정 문제", "easy":"쉬운 문제"][category] ?? category }
}
struct ExamOffer: Codable, Equatable {
    var id: UUID
    var poolVersion: String
    var rating: ExamRatingState
    var choices: [ExamChoice]
    func validate() throws {
        guard rating.value.isFinite, rating.value >= 0, rating.completed >= 0,
              choices.map(\.category) == ["challenge","matched","easy"],
              Set(choices.compactMap(\.questionId)).count == choices.compactMap(\.questionId).count else {
            throw SolfegeError.transport("시험 추천 정보를 확인하지 못했습니다.")
        }
        for choice in choices where choice.questionId != nil {
            guard let score = choice.difficultyScore, score.isFinite, score >= 0,
                  let delta = choice.ratingDifference, delta.isFinite,
                  abs(score-rating.value-delta) < 0.00001, (choice.questionVersion ?? 0) > 0,
                  choice.category != "challenge" || score > rating.value,
                  choice.category != "easy" || score < rating.value else {
                throw SolfegeError.transport("시험 문제의 난이도 정보가 일치하지 않습니다.")
            }
        }
    }
}
struct ExamRatingChange: Codable, Equatable {
    var before: Double; var after: Double; var delta: Double
    var difficulty: Double; var grade: Double; var expectedScore: Double
    var completedBefore: Int
    var modelVersion: String; var difficultyVersion: String; var poolVersion: String
}
struct QuestionPoolManifest: Codable {
    struct Entry: Codable { var pool: String; var family: String }
    var version: String
    var records: [String:Entry]
    func contains(_ id: UUID, in pool: String) -> Bool { records[id.uuidString.lowercased()]?.pool == pool }
}

// Same reviewed model as backend/solfege/rating.py; used only by the local demo.
// Real account ratings are calculated exclusively by the server.
enum ExamRatingModel {
    static let version = "exam-rating-1"
    static let knots: [Double] = [0,7.5,9.5,13,30,55,62,68,74]
    static func skill(_ score: Double) -> Double {
        let index = knots.lastIndex(where: { score >= $0 }) ?? 0
        let width = index == knots.count-1 ? 6 : knots[index+1]-knots[index]
        return Double(index)+(score-knots[index])/width
    }
    static func score(_ skill: Double) -> Double {
        let index = min(Int(skill),knots.count-1)
        return knots[index]+(skill-Double(index))*(index == knots.count-1 ? 6 : knots[index+1]-knots[index])
    }
    static func expected(_ rating: Double, _ difficulty: Double) -> Double {
        let x = log(4)+(skill(rating)-skill(difficulty)) / 0.5
        if x >= 0 { return 1/(1+exp(-x)) }
        let z = exp(x); return z/(1+z)
    }
    static func update(_ state: ExamRatingState, difficulty: Double, grade: Int, difficultyVersion: String, poolVersion: String) throws -> ExamRatingChange {
        guard state.value.isFinite, state.value >= 0, state.completed >= 0,
              difficulty.isFinite, difficulty >= 0, (0...100).contains(grade) else {
            throw SolfegeError.configuration("레이팅 계산 값을 확인해 주세요.")
        }
        let prediction = expected(state.value,difficulty)
        let k = 0.25+0.5*exp(-Double(state.completed)/5)
        let step = min(0.5,max(-0.5,k*(Double(grade)/100-prediction)))
        let after = score(max(0,skill(state.value)+step))
        return ExamRatingChange(before:state.value,after:after,delta:after-state.value,difficulty:difficulty,
            grade:Double(grade),expectedScore:prediction*100,completedBefore:state.completed,
            modelVersion:version,difficultyVersion:difficultyVersion,poolVersion:poolVersion)
    }
    static func choices(rating: Double, questions: [Question]) -> [ExamChoice] {
        var selected: [String:Question] = [:]
        for (category,target,lo,hi) in [("matched",0.8,0.75,0.85),("challenge",0.625,0.55,0.70),("easy",0.915,0.88,0.95)] {
            let eligible = questions.filter { q in
                guard let d = q.difficultyScore, d.isFinite, d >= 0, !selected.values.contains(where: { $0.id == q.id }) else { return false }
                if category == "challenge" { return d > max(rating,selected["matched"]?.difficultyScore ?? rating) }
                if category == "easy" { return d < min(rating,selected["matched"]?.difficultyScore ?? rating) }
                return abs(skill(d)-skill(rating)) <= 0.5
            }
            let preferred = eligible.filter { (lo...hi).contains(expected(rating,$0.difficultyScore!)) }
            let nearest = Array(eligible.sorted {
                let a = abs(expected(rating,$0.difficultyScore!)-target), b = abs(expected(rating,$1.difficultyScore!)-target)
                return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
            }.prefix(5))
            selected[category] = (preferred.isEmpty || category == "matched" ? nearest : preferred).randomElement()
        }
        return ["challenge","matched","easy"].map { category in
            let q = selected[category], d = q?.difficultyScore
            return ExamChoice(category:category,questionId:q?.id,questionVersion:q?.version,difficultyScore:d,
                ratingDifference:d.map { $0-rating },reason:q == nil ? "no_unseen_question" : nil)
        }
    }
}
