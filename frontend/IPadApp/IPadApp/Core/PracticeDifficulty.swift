import Foundation

struct PracticeDifficultyManifest: Codable {
    struct Entry: Codable {
        var mainSha256: String
        var contentScore: Double
        var keyCorrection: Double
        var scoreFloor: Double
        var referenceQuarterBpm: Double
        var score: Double
        var level: Int
    }
    var version: String
    var cutoffs: [Double]
    var records: [String:Entry]

    func validate() throws {
        guard version == "practice-difficulty-2", cutoffs.count == 8,
              cutoffs.allSatisfy({ $0.isFinite && $0 >= 0 }),
              zip(cutoffs,cutoffs.dropFirst()).allSatisfy({ $0.0 < $0.1 }),
              records.values.allSatisfy({ $0.referenceQuarterBpm.isFinite && $0.referenceQuarterBpm > 0
                  && $0.contentScore.isFinite && $0.contentScore >= 0
                  && $0.keyCorrection.isFinite && $0.keyCorrection >= 0
                  && $0.scoreFloor.isFinite && $0.scoreFloor >= 0
                  && $0.score.isFinite && $0.score >= 0 && (1...9).contains($0.level) })
        else { throw SolfegeError.configuration("문제 난이도 기준을 확인해 주세요.") }
    }
    func annotating(_ source: Question) -> Question {
        guard source.collection != "classical",
              let entry = records[source.id.uuidString.lowercased()],
              entry.mainSha256 == source.scoreAssets.main.sha256 else { return source }
        var q = source
        let tempo = q.tempo ?? TempoDefaults.setting(for:q.timeSignature)
        let score = max((entry.contentScore + entry.keyCorrection) * tempo.quarterBpm / entry.referenceQuarterBpm,entry.scoreFloor)
        q.practiceLevelNumber = 1 + cutoffs.filter { score >= $0 }.count
        q.difficultyScore = score; q.difficultyVersion = version
        return q
    }
}
