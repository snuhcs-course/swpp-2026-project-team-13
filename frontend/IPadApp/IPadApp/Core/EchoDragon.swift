import Foundation

enum EchoDragonRule: String, Codable {
    case follow, mirror
    var title: String { self == .follow ? "따라 하기" : "거울 대답" }
    var instruction: String {
        self == .follow ? "같은 간격, 같은 방향으로 답해요." : "같은 간격, 반대 방향으로 답해요."
    }
}

struct EchoDragonInterval: Equatable, Identifiable {
    let semitones: Int
    let name: String
    var id: Int { semitones }
    static let all: [Self] = [
        .init(semitones:1,name:"단2도 · 반음"), .init(semitones:2,name:"장2도 · 온음"),
        .init(semitones:3,name:"단3도"), .init(semitones:4,name:"장3도"),
        .init(semitones:5,name:"완전4도"), .init(semitones:6,name:"트라이톤"),
        .init(semitones:7,name:"완전5도"), .init(semitones:8,name:"단6도"),
        .init(semitones:9,name:"장6도"), .init(semitones:10,name:"단7도"),
        .init(semitones:11,name:"장7도"), .init(semitones:12,name:"완전8도")
    ]
    static func at(_ semitones: Int) -> Self { all[min(12,max(1,semitones))-1] }
}

// One number is one call-and-response puzzle. There are no sets inside a level.
struct EchoDragonLevel: Identifiable, Equatable {
    static let count = 72
    static let milestones: [(number: Int, semitones: Int)] = [
        (1,1),(2,2),(7,3),(13,4),(19,5),(31,6),
        (37,7),(43,8),(49,9),(55,10),(61,11),(67,12)
    ]
    let number: Int
    var id: Int { number }
    var maximum: Int { Self.milestones.last { $0.number <= number }?.semitones ?? 1 }
    var introducedInterval: EchoDragonInterval? {
        Self.milestones.first { $0.number == number }.map { .at($0.semitones) }
    }
    var rule: EchoDragonRule {
        if number < 25 || introducedInterval != nil { return .follow }
        if number <= 27 { return .mirror }
        return number.isMultiple(of:2) ? .follow : .mirror
    }
    var title: String {
        if number == 25 { return "호수 속 드래곤" }
        if let interval = introducedInterval { return "새로운 소리 · \(interval.name)" }
        return rule == .mirror ? "거울에 보내는 인사" : "드래곤과 한마디"
    }
    var introduction: String? {
        if number == 25 { return "호수에 비친 친구에게 인사해요. 올라가는 소리에는 내려가며, 내려가는 소리에는 올라가며 답해요. 간격은 같아요." }
        guard let interval = introducedInterval else { return nil }
        return "\(interval.name)은 \(interval.semitones)반음 간격이에요. 먼저 들어보고 피아노로 답해 보세요. 처음에는 ‘건반 힌트’를 써도 좋아요."
    }
}

struct EchoDragonChallenge: Equatable {
    let level: EchoDragonLevel
    let interval: Int
    let callRoot: Int
    let callDirection: Int
    let replyRoot: Int
    let choices: [Int]
    var callEnd: Int { callRoot + callDirection*interval }
    var replyDirection: Int { level.rule == .mirror ? -callDirection : callDirection }
    var answer: Int { replyRoot + replyDirection*interval }
    var directionLabel: String { replyDirection > 0 ? "위로" : "아래로" }
    var keyboardRange: ClosedRange<Int> {
        let notes = choices + [replyRoot]
        let low = (notes.min()! / 12)*12
        let high = max(low+12,((notes.max()!+11)/12)*12)
        return low...high
    }
    func isCorrect(_ midi: Int) -> Bool {
        // Signed distance, including octave: pitch-class matching is insufficient.
        midi-replyRoot == replyDirection*interval
    }

    static func make(number: Int, variation: UInt64 = 0) -> Self {
        let level = EchoDragonLevel(number:min(EchoDragonLevel.count,max(1,number)))
        var random = EchoDragonRandom(seed:UInt64(level.number) &* 7919 &+ variation)
        let pool = Array(1...((25...27).contains(level.number) ? 2 : level.maximum))
        let interval = level.introducedInterval?.semitones ?? pool[(level.number-3+pool.count) % pool.count]
        let direction: Int
        if level.number < 26 || level.introducedInterval != nil { direction = 1 }
        else if level.number == 26 { direction = -1 }
        else { direction = random.next().isMultiple(of:2) ? 1 : -1 }
        let root = level.number <= 2 ? 60 : 55+Int(random.next()%13)
        var reply = root
        if level.number >= 5 {
            repeat { reply = 57+Int(random.next()%13) } while reply == root
        }
        let replyDirection = level.rule == .mirror ? -direction : direction
        // Close distractors keep earlier intervals in use without a 12-button UI.
        var neighbors = pool.filter { $0 != interval }.sorted {
            let a = abs($0-interval), b = abs($1-interval)
            return a == b ? $0 < $1 : a < b
        }
        neighbors = Array(neighbors.prefix(3)) + [interval]
        // The first guided puzzle has a real alternative, although only one interval is taught.
        if neighbors.count == 1 { neighbors.append(interval+1) }
        let choices = neighbors.map { reply + replyDirection*$0 }.sorted()
        return Self(level:level,interval:interval,callRoot:root,callDirection:direction,
                    replyRoot:reply,choices:choices)
    }
}

private struct EchoDragonRandom {
    var seed: UInt64
    mutating func next() -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed ^ (seed >> 32)
    }
}

struct EchoDragonProgress: Codable, Equatable {
    private(set) var stars: [Int:Int] = [:]
    var unlocked: Int {
        (1...EchoDragonLevel.count).first { stars[$0] == nil } ?? EchoDragonLevel.count
    }
    var completed: Int { stars.count }
    var totalStars: Int { stars.values.reduce(0,+) }
    mutating func record(level: Int, stars value: Int) {
        guard (1...EchoDragonLevel.count).contains(level), level <= unlocked, (1...3).contains(value) else { return }
        stars[level] = max(stars[level] ?? 0,value)
    }
    static func load(_ data: Data?) throws -> Self {
        guard let data else { return Self() }
        var progress = try JSONDecoder().decode(Self.self,from:data)
        progress.stars = progress.stars.filter { (1...EchoDragonLevel.count).contains($0.key) && (1...3).contains($0.value) }
        let firstMissing = (1...EchoDragonLevel.count).first { progress.stars[$0] == nil } ?? (EchoDragonLevel.count+1)
        progress.stars = progress.stars.filter { $0.key < firstMissing }
        return progress
    }
    static func earnedStars(attempts: Int, hint: Bool) -> Int {
        hint ? 1 : attempts <= 1 ? 3 : attempts == 2 ? 2 : 1
    }
}
