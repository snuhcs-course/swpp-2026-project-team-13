import Foundation

// Quarter-note fractions stay exact. MIDI conversion is checked, never rounded.
struct RhythmTime: Codable, Hashable, Comparable, CustomStringConvertible {
    let numerator: Int
    let denominator: Int
    static let zero = RhythmTime(0)
    init(_ numerator: Int, _ denominator: Int = 1) {
        precondition(denominator > 0)
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? max(1,abs(a)) : gcd(b,a % b) }
        let factor = gcd(numerator,denominator)
        self.numerator = numerator / factor; self.denominator = denominator / factor
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer(), text = try box.decode(String.self)
        let parts = text.split(separator:"/",omittingEmptySubsequences:false)
        guard (1...2).contains(parts.count), let n = Int(parts[0]), let d = parts.count == 2 ? Int(parts[1]) : 1,
              d > 0, d <= 10000, n >= -128*d, n <= 128*d else { throw SORIError.invalidScore("리듬의 길이를 확인해 주세요.") }
        self.init(n,d)
        guard description == text else { throw SORIError.invalidScore("리듬의 분수 표기를 확인해 주세요.") }
    }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(description) }
    var description: String { denominator == 1 ? String(numerator) : "\(numerator)/\(denominator)" }
    var value: Double { Double(numerator)/Double(denominator) }
    var floor: Int { numerator >= 0 ? numerator/denominator : (numerator-denominator+1)/denominator }
    var ticks: Int? { (numerator*480) % denominator == 0 ? numerator*480/denominator : nil }
    static func < (a: Self, b: Self) -> Bool { a.numerator*b.denominator < b.numerator*a.denominator }
    static func + (a: Self, b: Self) -> Self { Self(a.numerator*b.denominator+b.numerator*a.denominator,a.denominator*b.denominator) }
    static func - (a: Self, b: Self) -> Self { Self(a.numerator*b.denominator-b.numerator*a.denominator,a.denominator*b.denominator) }
    static func * (a: Self, b: Int) -> Self { Self(a.numerator*b,a.denominator) }
    static func / (a: Self, b: Self) -> Self { Self(a.numerator*b.denominator,a.denominator*b.numerator) }
}

struct RhythmSymbol: Codable, Equatable {
    var duration: RhythmTime; var rest: Bool; var type: String; var dots: Int
    var actual: Int; var normal: Int; var group: Int; var tieNext: Bool; var groupEnd: Bool
}
struct RhythmTile: Codable, Identifiable, Equatable {
    var id: String; var duration: RhythmTime; var symbols: [RhythmSymbol]
    func label(pulse: RhythmTime) -> String {
        let beats = duration/pulse
        let value = [2,4,8].contains(beats.denominator) ? String(format:"%g",beats.value) : beats.description
        return value+"박"
    }
}
struct RhythmPlacement: Codable, Equatable, Identifiable {
    var tileId: String; var start: RhythmTime
    var id: String { start.description+":"+tileId }
}
struct RhythmSound: Codable, Hashable { var onset: RhythmTime; var duration: RhythmTime }
struct RhythmNote: Codable { var onset: RhythmTime; var duration: RhythmTime; var midi: Int }
struct RhythmDifficulty: Codable { var score: Int; var raw: Double; var version: String; var cohortSize: Int }
struct RhythmRound: Codable, Identifiable {
    var id: String; var questionId: UUID; var questionVersion: Int; var analysisKey: String; var sourceXmlSha256: String; var rhythmKey: String
    var title: String; var level: String; var firstMeasure: Int; var meter: TimeSignature
    var pulse: RhythmTime; var measureDuration: RhythmTime; var totalDuration: RhythmTime
    var tempoBpm: Double; var displayBpm: Int; var beatUnit: String
    var solution: [RhythmPlacement]; var solutionTies: [RhythmTime]; var rhythm: [RhythmSound]
    var audio: [RhythmNote]; var difficulty: RhythmDifficulty; var choices: [String]
    var pulsesPerMeasure: Int { (measureDuration/pulse).floor }
    var tempoLabel: String { "\(beatUnit == "dotted_quarter" ? "♩." : beatUnit == "half" ? "𝅗𝅥" : "♩") = \(displayBpm)" }
}
struct RhythmCatalog: Decodable {
    var version: String; var difficultyVersion: String; var tiles: [RhythmTile]; var rounds: [RhythmRound]
    var tileMap: [String:RhythmTile] { Dictionary(uniqueKeysWithValues:tiles.map { ($0.id,$0) }) }
    func validate() throws {
        guard version == "rhythm-puzzle-v1", !rounds.isEmpty, Set(tiles.map(\.id)).count == tiles.count else { throw SORIError.invalidScore("리듬 문제 버전을 확인해 주세요.") }
        let map = tileMap
        for t in tiles {
            guard !t.symbols.isEmpty, t.duration > .zero, t.symbols.reduce(.zero, { $0+$1.duration }) == t.duration,
                  t.symbols.allSatisfy({ $0.duration > .zero && $0.duration.ticks != nil }) else { throw SORIError.invalidScore("리듬 조각의 길이가 맞지 않아요.") }
        }
        for r in rounds {
            guard r.choices.count == 12, Set(r.choices).count == 12, r.choices.allSatisfy({ map[$0] != nil }),
                  r.totalDuration == r.measureDuration*2, r.measureDuration > .zero, r.pulse > .zero,
                  (r.measureDuration/r.pulse).denominator == 1, r.meter.supported,
                  (0...100).contains(r.difficulty.score), (40...200).contains(r.tempoBpm),
                  r.audio.allSatisfy({ $0.onset.ticks != nil && $0.duration.ticks != nil && (0...127).contains($0.midi) }) else { throw SORIError.invalidScore("리듬 문제 구성을 확인해 주세요.") }
            let answer = RhythmBoard(placements:r.solution,ties:r.solutionTies)
            guard try answer.sounds(round:r,tiles:map) == r.rhythm,
                  r.rhythm == r.audio.map({ RhythmSound(onset:$0.onset,duration:$0.duration) }) else { throw SORIError.invalidScore("리듬 정답과 음원이 다릅니다.") }
        }
    }
    // Interleave same-meter difficulty thirds; never overlap excerpts from the same source in a set.
    func set(count: Int = 5) -> [RhythmRound] {
        var ordered = rounds.shuffled(), buckets = [[RhythmRound](),[RhythmRound](),[RhythmRound]()]
        for r in ordered { buckets[min(2,r.difficulty.score/34)].append(r) }
        ordered = []; var sources = Set<UUID>()
        while ordered.count < count {
            var added = false
            for i in buckets.indices {
                if let j = buckets[i].firstIndex(where: { !sources.contains($0.questionId) }) {
                    let r = buckets[i].remove(at:j); sources.insert(r.questionId); ordered.append(r); added = true
                    if ordered.count == count { break }
                }
            }
            if !added { break }
        }
        return ordered
    }
}

struct RhythmBoard: Codable, Equatable {
    var placements: [RhythmPlacement] = []
    var ties: [RhythmTime] = []
    func end(_ p: RhythmPlacement, tiles: [String:RhythmTile]) -> RhythmTime { p.start+(tiles[p.tileId]?.duration ?? .zero) }
    func firstGap(tiles: [String:RhythmTile]) -> RhythmTime {
        var cursor = RhythmTime.zero
        for p in placements.sorted(by:{ $0.start < $1.start }) { if p.start != cursor { break }; cursor = end(p,tiles:tiles) }
        return cursor
    }
    func complete(round: RhythmRound, tiles: [String:RhythmTile]) -> Bool { firstGap(tiles:tiles) == round.totalDuration }
    func validBoundaries(tiles: [String:RhythmTile]) -> [RhythmTime] {
        let sorted = placements.sorted { $0.start < $1.start }
        return zip(sorted,sorted.dropFirst()).compactMap { a,b in
            guard end(a,tiles:tiles) == b.start, tiles[a.tileId]?.symbols.last?.rest == false,
                  tiles[b.tileId]?.symbols.first?.rest == false else { return nil }
            return b.start
        }
    }
    @discardableResult mutating func place(_ id: String, at requested: RhythmTime? = nil, round: RhythmRound, tiles: [String:RhythmTile]) -> Bool {
        guard round.choices.contains(id), let tile = tiles[id] else { return false }
        var start = requested ?? firstGap(tiles:tiles)
        let old = placements.first { $0.start <= start && start < end($0,tiles:tiles) }
        if let old { start = old.start }
        let finish = start+tile.duration
        guard start >= .zero, finish <= round.totalDuration,
              (start/round.measureDuration).floor == ((finish-RhythmTime(1,1000000))/round.measureDuration).floor,
              placements.filter({ $0.id != old?.id }).allSatisfy({ finish <= $0.start || end($0,tiles:tiles) <= start }) else { return false }
        if let old { remove(old,tiles:tiles) }
        placements.append(RhythmPlacement(tileId:id,start:start)); placements.sort { $0.start < $1.start }
        return true
    }
    mutating func remove(_ p: RhythmPlacement, tiles: [String:RhythmTile]) {
        let finish = end(p,tiles:tiles)
        placements.removeAll { $0.id == p.id }; ties.removeAll { $0 == p.start || $0 == finish }
    }
    @discardableResult mutating func toggleTie(_ time: RhythmTime, tiles: [String:RhythmTile]) -> Bool {
        guard validBoundaries(tiles:tiles).contains(time) else { return false }
        if ties.contains(time) { ties.removeAll { $0 == time } } else { ties.append(time); ties.sort() }
        return true
    }
    func sounds(round: RhythmRound, tiles: [String:RhythmTile]) throws -> [RhythmSound] {
        guard complete(round:round,tiles:tiles), Set(ties).count == ties.count,
              ties.allSatisfy({ validBoundaries(tiles:tiles).contains($0) }) else { throw SORIError.invalidScore("빈칸과 타이 연결을 확인해 주세요.") }
        var cursor = RhythmTime.zero, result: [RhythmSound] = [], continuing = false
        for p in placements.sorted(by:{ $0.start < $1.start }) {
            guard p.start == cursor, let tile = tiles[p.tileId] else { throw SORIError.invalidScore("조각이 겹치거나 빈칸이 있어요.") }
            for (i,n) in tile.symbols.enumerated() {
                if continuing {
                    guard !n.rest, !result.isEmpty else { throw SORIError.invalidScore("쉼표에는 타이를 연결할 수 없어요.") }
                    result[result.count-1].duration = result[result.count-1].duration+n.duration
                } else if !n.rest { result.append(RhythmSound(onset:cursor,duration:n.duration)) }
                cursor = cursor+n.duration
                continuing = n.tieNext || (i == tile.symbols.count-1 && ties.contains(cursor))
                if n.rest && continuing { throw SORIError.invalidScore("쉼표에는 타이를 연결할 수 없어요.") }
            }
        }
        guard !continuing else { throw SORIError.invalidScore("마지막 타이의 연결을 확인해 주세요.") }
        return result
    }
    func errorPositions(round: RhythmRound, tiles: [String:RhythmTile]) -> [RhythmTime] {
        guard let actual = try? sounds(round:round,tiles:tiles) else { return [] }
        let a = Dictionary(uniqueKeysWithValues:actual.map { ($0.onset,$0.duration) })
        let b = Dictionary(uniqueKeysWithValues:round.rhythm.map { ($0.onset,$0.duration) })
        var positions = Set<RhythmTime>()
        for time in Set(a.keys).union(Set(b.keys)) where a[time] != b[time] {
            if let x = a[time], let y = b[time] { positions.insert(time+min(x,y)) }
            else { positions.insert(time) }
        }
        return positions.sorted()
    }
}

struct RhythmSubmission: Codable {
    var id = UUID(); var activeMs: Int; var placements: [RhythmPlacement]; var ties: [RhythmTime]
}
struct RhythmListen: Codable {
    var id = UUID(); var reason: String; var startedMs: Int; var endedMs: Int; var completed: Bool
}
struct RhythmPlayRecord: Codable, Identifiable {
    var id: UUID { clientPlayId }
    var clientPlayId = UUID(); var catalogSha256: String; var roundId: String; var gameVersion = "rhythm-puzzle-v1"
    var choiceOrder: [String]; var startedAt: Date; var finishedAt: Date
    var outcome = "abandoned"; var activeMs = 0; var submissions: [RhythmSubmission] = []; var listens: [RhythmListen] = []
    var interruptions = 0; var priorExposures = 0; var priorPatternExposures = 0
}
struct RhythmReceipt: Codable { var id: UUID; var clientPlayId: UUID; var roundId: String; var catalogSha256: String }
struct RhythmDraft: Codable {
    var setIds: [String]; var index: Int; var board = RhythmBoard(); var undo: [RhythmBoard] = []
    var record: RhythmPlayRecord; var finished = false
    var wrongCount: Int { finished && record.outcome == "correct" ? max(0,record.submissions.count-1) : record.submissions.count }
    var hasListened: Bool { record.listens.contains { $0.completed && $0.reason != "reference" } }
    var hintLevel: Int { min(3,wrongCount) }
    mutating func submit(round: RhythmRound, tiles: [String:RhythmTile], now: Date = Date()) throws -> Bool {
        guard !finished, hasListened, record.submissions.count < 3 else { throw SORIError.configuration("음원을 끝까지 듣고 제출해 주세요.") }
        let actual = try board.sounds(round:round,tiles:tiles)
        record.submissions.append(RhythmSubmission(activeMs:record.activeMs,placements:board.placements,ties:board.ties))
        let correct = actual == round.rhythm
        if correct || record.submissions.count == 3 {
            finished = true; record.outcome = correct ? "correct" : "revealed"; record.finishedAt = now
        }
        return correct
    }
}
