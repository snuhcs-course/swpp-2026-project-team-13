import Foundation

enum MemoryDifficulty: String, Codable, CaseIterable, Identifiable {
    case beginner, intermediate, advanced
    var id: String { rawValue }
    var title: String {
        switch self { case .beginner: return "초급"; case .intermediate: return "중급"; case .advanced: return "고급" }
    }
    var barPlan: [Int] {
        switch self { case .beginner: return [2,2,2,2]; case .intermediate: return [2,2,4,4]; case .advanced: return [4,4,4,4] }
    }
    var quarterBpm: Double {
        switch self { case .beginner: return 60; case .intermediate: return 84; case .advanced: return 96 }
    }
    var selectionCentre: Double {
        switch self { case .beginner: return 35; case .intermediate: return 50; case .advanced: return 65 }
    }
    func bpm(for meter: TimeSignature) -> Double {
        // Compound meters use dotted-quarter 40/56/64.
        quarterBpm
    }
    func tempoLabel(for meter: TimeSignature) -> String {
        if meter.denominator == 8 && [6,9,12].contains(meter.numerator) { return "♩. = \(Int(quarterBpm/1.5))" }
        if meter.denominator == 2 { return "𝅗𝅥 = \(Int(quarterBpm/2))" }
        return "♩ = \(Int(quarterBpm))"
    }
    func weight(score: Double) -> Double {
        // Broad, nonzero overlap. This is an experimental selection policy,
        // not a validated learner ability scale or three disjoint music bins.
        0.20 + exp(-pow((score-selectionCentre)/30,2)/2)
    }
}

struct MemoryExcerpt: Codable, Identifiable, Equatable {
    let id: String
    let sourceId: String
    let first: Int
    let bars: Int
    let score: Double
    let attacks: Int
    let pitchRange: Int
    let durationQuarters: Double
    let fingerprint: String
    let beginnerEligible: Bool
    let largestInterval: Int
}

struct MemoryCatalog: Codable {
    let version: String
    let difficultyVersion: String
    let sources: [MelodyQuestion]
    let excerpts: [MemoryExcerpt]
    func makeSet<R: RandomNumberGenerator>(level: MemoryDifficulty, using rng: inout R) throws -> [MemoryExcerpt] {
        var chosen: [MemoryExcerpt] = []
        let sourceMap = Dictionary(uniqueKeysWithValues:sources.map { ($0.id,$0) })
        for (index,bars) in level.barPlan.enumerated() {
            let used = Set(chosen.map(\.sourceId)), patterns = Set(chosen.map(\.fingerprint))
            let candidates = excerpts.filter {
                $0.bars == bars && !used.contains($0.sourceId) && !patterns.contains($0.fingerprint)
                    && (level != .beginner || $0.beginnerEligible)
                    && (level != .beginner || index >= 2 || ($0.attacks <= 5 && $0.pitchRange <= 5 && $0.largestInterval <= 2))
            }
            guard !candidates.isEmpty else { throw SolfegeError.invalidScore("이 난이도의 선율을 준비하지 못했어요.") }
            let groups: [(String,Double)] = [("library",0.6),("intermediate",0.2),("classical",0.2)]
                .filter { group in candidates.contains { sourceMap[$0.sourceId]?.collection == group.0 } }
            let totalGroupWeight = groups.reduce(0) { $0+$1.1 }
            var draw = Double.random(in:0..<totalGroupWeight,using:&rng)
            var collection = groups.last?.0 ?? "library"
            for group in groups { draw -= group.1; if draw < 0 { collection = group.0; break } }
            let pool = candidates.filter { sourceMap[$0.sourceId]?.collection == collection }
            let counts = Dictionary(grouping:pool,by:\.sourceId).mapValues(\.count)
            let weights = pool.map { level.weight(score:$0.score)/Double(counts[$0.sourceId] ?? 1) }
            var value = Double.random(in:0..<weights.reduce(0,+),using:&rng)
            var picked = pool[pool.count-1]
            for (index,weight) in weights.enumerated() { value -= weight; if value < 0 { picked = pool[index]; break } }
            chosen.append(picked)
        }
        return chosen
    }
    func validate() throws {
        let ids = Set(sources.map(\.id))
        guard version == "memory-run-v2", difficultyVersion == "memory-burden-v1",
              ids.count == sources.count, Set(excerpts.map(\.id)).count == excerpts.count,
              sources.allSatisfy({ ["library","intermediate","classical"].contains($0.collection ?? "") && $0.sha256?.count == 64 }),
              excerpts.allSatisfy({ ids.contains($0.sourceId) && [2,4].contains($0.bars) && $0.first >= 1 && $0.first+$0.bars <= 9 && $0.attacks >= 2 && (0...100).contains($0.score) }) else {
            throw SolfegeError.invalidScore("Memory run 문제 파일을 확인해 주세요.")
        }
    }
}

struct MemoryPlayRecord: Codable, Identifiable {
    var id = UUID()
    let setId: UUID
    let setIndex: Int
    let excerptId: String
    let sourceId: String
    let sourceSha256: String
    let catalogSha256: String
    let analysisKey: String
    let difficultyVersion: String
    let level: MemoryDifficulty
    let mode: String
    let bars: Int
    let first: Int
    let bpm: Double
    let score: Double
    let fingerprint: String
    let priorExposures: Int
    let priorPatternExposures: Int
    let expected: [Int]
    let givenIndices: [Int]
    var actual: [Int?]
    var startedAt = Date()
    var outcome = "in_progress"
    var accuracy: Int? = nil
    var listenStarts = 0
    var listenCompleted = 0
    var inputMs = 0
    var interruptions = 0
    // Optional to preserve existing on-device records. Guided starts are not scored.
    var inputPolicy: String? = nil
    var replayWithCountIn: Int? = nil
    var replayDirect: Int? = nil
    var retryOf: UUID? = nil
}

// Intrinsic width at a fixed staff size, independent of the screen's width.
// NativeScoreRenderer keeps its existing exam layout; only Memory run opts in.
struct MelodyBarSpacing {
    let positions: [Double]
    let width: Double
    let height: Double
    let top: Double
    init(symbols: [ScoreSymbol], fifths: Int, clef: String = "G", displayedSymbols: [ScoreSymbol] = []) {
        var x = 190.0 + Double(abs(fifths))*15
        var positions: [Double] = []
        for symbol in symbols {
            positions.append(x)
            let duration = max(0.125,Double(symbol.duration)/480)
            let rhythmic = max(24,min(58,32*sqrt(duration)))
            let accidental = symbol.alter == 0 ? 0.0 : 10.0
            x += rhythmic + max(10,accidental) + Double(symbol.dots)*4
        }
        self.positions = positions
        width = max(260,x+22)
        let steps = ["C":0,"D":1,"E":2,"F":3,"G":4,"A":5,"B":6]
        let ys = (symbols+displayedSymbols).filter { $0.midi != nil }.map { n in
            212.0-Double(n.octave*7+(steps[n.step ?? "B"] ?? 6)-(clef == "F" ? 18 : 30))*6
        }
        top = min(110,(ys.min() ?? 164)-52)
        height = max(240,(ys.max() ?? 212)+48)-top
    }
}
