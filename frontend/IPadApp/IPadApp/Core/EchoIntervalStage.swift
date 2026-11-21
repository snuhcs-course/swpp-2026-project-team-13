import Foundation

// Echo's curriculum is procedural UI/game logic, not a downloadable score bank.
// Version it independently: published Memory/Rhythm sets remain untouched.
struct EchoIntervalStage: Equatable {
    static let version = "echo-interval-stages-1"
    static let questionCount = 10
    static let lives = 3
    let number: Int
    init(_ number: Int) { self.number = min(10,max(1,number)) }
    static func forStair(_ number: Int) -> Self? {
        guard let index = DrillStairs.stages.filter({ $0.game == .echoDragon }).firstIndex(where:{ $0.number == number }) else { return nil }
        return Self(index+1)
    }
    var title: String {
        switch number {
        case 1: return "단2도와 장2도"
        case 2: return "장3도와 단3도"
        case 3: return "단2도부터 장3도까지"
        case 4: return "완전4도 · 증4도 · 완전5도"
        case 5: return "단2도부터 완전5도까지"
        case 6: return "장6도와 단6도"
        case 7: return "장7도와 단7도"
        case 8,9: return "반음부터 옥타브까지"
        default: return "자유 음역 · 최대 2옥타브"
        }
    }
    var intervals: [Int] {
        switch number {
        case 1: return [1,2]
        case 2: return [3,4]
        case 3: return Array(1...4)
        case 4: return [5,6,7]
        case 5: return Array(1...7)
        case 6: return [8,9]
        case 7: return [10,11]
        case 8,9: return Array(1...12)
        default: return Array(1...24)
        }
    }
    var keyboardRange: ClosedRange<Int> { number == 10 ? 48...84 : 60...84 }
    var questions: [EchoIntervalQuestion] {
        var random = EchoIntervalRandom(state:UInt64(number)*7919)
        let pool = intervals
        var sizes: [Int]
        if pool.count <= Self.questionCount {
            sizes = (0..<Self.questionCount).map { pool[$0 % pool.count] }
        } else {
            // Cover the whole span, including the largest interval, in ten turns.
            // The two octave-review stages sample different interior intervals.
            sizes = (0..<Self.questionCount).map { i in
                let position = Int((Double(i)*Double(pool.count-1)/Double(Self.questionCount-1)).rounded())
                return pool[(position + (number == 9 ? 1 : 0)) % pool.count]
            }
        }
        sizes.shuffle(using:&random)
        var directions = Array(repeating:1,count:5)+Array(repeating:-1,count:5)
        // Stage 8 introduces each direction in a block; stage 9 mixes both.
        if number != 8 { directions.shuffle(using:&random) }
        return sizes.enumerated().map { index, size in
            let distance = directions[index]*size
            let replyRange = Self.roots(in:keyboardRange,distance:distance)
            let reply = replyRange.lowerBound + Int(random.next()%UInt64(replyRange.count))
            let callRange = Self.roots(in:48...84,distance:distance)
            let candidates = Array(callRange).filter { $0 != reply }
            let call = candidates[Int(random.next()%UInt64(candidates.count))]
            return EchoIntervalQuestion(id:"\(Self.version)-\(number)-\(index+1)",
                call:[call,call+distance],replyStart:reply,distance:distance,keyboardRange:keyboardRange)
        }
    }
    private static func roots(in range: ClosedRange<Int>, distance: Int) -> ClosedRange<Int> {
        max(range.lowerBound,range.lowerBound-distance)...min(range.upperBound,range.upperBound-distance)
    }
}

struct EchoIntervalQuestion: Equatable, Identifiable {
    let id: String
    let call: [Int]
    let replyStart: Int
    let distance: Int
    let keyboardRange: ClosedRange<Int>
    var answer: [Int] { [replyStart,replyStart+distance] }
    func accepts(_ notes: [Int]) -> Bool {
        // Signed semitones, including the octave; pitch-class matching is wrong.
        notes.count == 2 && notes[0] == replyStart && notes[1]-notes[0] == distance
    }
}

struct EchoIntervalRun {
    let stage: EchoIntervalStage
    let questions: [EchoIntervalQuestion]
    private(set) var index = 0
    private(set) var mistakes = 0
    private(set) var solved: [Bool]
    private(set) var errors: [Int]
    var question: EchoIntervalQuestion { questions[index] }
    var hearts: Int { max(0,EchoIntervalStage.lives-mistakes) }
    var failed: Bool { hearts == 0 }
    var complete: Bool { solved.allSatisfy { $0 } }
    init(stage: EchoIntervalStage) {
        self.stage=stage; questions=stage.questions
        solved=Array(repeating:false,count:questions.count)
        errors=Array(repeating:0,count:questions.count)
    }
    // Call only after the player's complete answer has been replayed.
    @discardableResult mutating func grade(_ notes: [Int]) -> Bool? {
        guard !failed, !complete, !solved[index], notes.count == 2 else { return nil }
        let correct=question.accepts(notes)
        if correct { solved[index]=true }
        else { mistakes+=1; errors[index]+=1 }
        return correct
    }
    mutating func advance() {
        guard solved[index], !complete, !failed, index+1<questions.count else { return }
        index+=1
    }
}

private struct EchoIntervalRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state ^ (state >> 32)
    }
}
