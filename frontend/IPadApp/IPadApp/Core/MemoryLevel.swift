import Foundation

// Numbered Memory run levels. Each level has one fixed melody, so a retry, a later visit
// and a test fixture all hear the notes that match the level number shown.
// Milestones: 7 four notes in a bar, 13 two bars, 19 leaps up to a fourth,
// 25 eighth notes, 31 G and F major, 37 four bars. Earlier material stays in later levels.
struct MemoryLevel: Equatable, Identifiable {
    static let count = 42
    static let passAccuracy = 80
    static let all: [MemoryLevel] = build()
    static func level(_ number: Int) -> MemoryLevel { all[min(count,max(1,number))-1] }

    let number: Int
    let fifths: Int
    let degrees: [Int]
    let durations: [[Int]]
    var id: Int { number }
    var bars: Int { durations.count }
    var noteCount: Int { degrees.count }
    var bpm: Double { number >= 37 ? 80 : number >= 25 ? 72 : number >= 13 ? 66 : 60 }
    var tonicMidi: Int { fifths == 1 ? 67 : fifths == -1 ? 65 : 60 }
    var midis: [Int] { degrees.map { Self.midi(degree:$0,tonic:tonicMidi) } }
    var keyLabel: String { fifths == 1 ? "사장조" : fifths == -1 ? "바장조" : "다장조" }
    var signature: String { "\(fifths)|"+degrees.map(String.init).joined(separator:",")+"|"+durations.map { $0.map(String.init).joined(separator:",") }.joined(separator:"/") }
    var isMilestone: Bool { Self.milestones.contains { $0.level == number } }
    var stageTitle: String { Self.milestones.last { $0.level <= number }?.title ?? "" }
    static let milestones: [(level: Int, title: String)] = [
        (1,"한 마디 · 세 음"),(7,"한 마디 · 네 음"),(13,"두 마디"),(19,"4도 도약"),(25,"8분음표"),(31,"사장조 · 바장조"),(37,"네 마디")
    ]

    static func midi(degree: Int, tonic: Int) -> Int {
        let scale = [0,2,4,5,7,9,11]
        let octave = degree >= 0 ? degree/7 : (degree-6)/7
        return tonic+octave*12+scale[degree-octave*7]
    }

    var source: MelodySource {
        let meter = TimeSignature(numerator:4,denominator:4)
        var symbols: [ScoreSymbol] = [], events: [MusicEvent] = [], index = 0
        for (bar,pattern) in durations.enumerated() {
            var onset = bar*meter.ticksPerMeasure
            for duration in pattern {
                let midi = midis[index], pitch = MelodyRound.spelling(midi,fifths:fifths)
                var symbol = ScoreSymbol(measure:bar+1,onset:onset,duration:duration,midi:midi,step:pitch.0,octave:pitch.1,alter:pitch.2,
                    type:Self.type(duration),dots:0,tieStart:false,tieStop:false)
                // Eighth pairs always sit on a beat, so a pair is beamed from its first note.
                if duration == 240 {
                    let pairStart = (onset % 480) == 0
                    symbol.beams = [1: pairStart ? "begin" : "end"]
                }
                symbols.append(symbol); events.append(MusicEvent(midi:midi,onset:onset,duration:duration))
                onset += duration; index += 1
            }
        }
        let tonic = fifths == 1 ? "G" : fifths == -1 ? "F" : "C"
        let score = MusicScore(tempo:bpm,measures:bars,events:events,symbols:symbols,timeSignature:meter,
            keySignature:KeySignature(tonic:tonic,mode:"major",fifths:fifths))
        return MelodySource(score:score,fifths:fifths,mode:"major",clef:"G")
    }

    private static func type(_ duration: Int) -> String {
        switch duration { case 240: return "eighth"; case 960: return "half"; case 1920: return "whole"; default: return "quarter" }
    }

    // MARK: Generation

    private static func patterns(number: Int, final: Bool) -> [[Int]] {
        if number < 7 { return [[480,480,960],[960,480,480],[480,960,480]] }
        if number < 13 { return [[480,480,480,480]] }
        var plain: [[Int]] = final ? [[480,480,960],[480,480,480,480]] : [[480,480,480,480],[480,480,960],[960,480,480]]
        if number >= 25 {
            plain += final ? [[240,240,480,960]] : [[240,240,480,480,480],[480,480,240,240,480],[480,240,240,480,480],[240,240,240,240,960]]
        }
        return plain
    }

    private static func keyFifths(_ number: Int) -> Int {
        // New keys arrive at 31; 37 keeps C major so the four-bar step is the only new thing.
        guard number >= 31, number != 37 else { return 0 }
        return [1,-1,0][(number-31) % 3]
    }

    private static func build() -> [MemoryLevel] {
        var levels: [MemoryLevel] = [], seen: Set<String> = []
        for number in 1...count {
            var rng = SplitMix(seed:UInt64(number) &* 0x9E37_79B9_7F4A_7C15)
            for _ in 0..<500 {
                guard let level = make(number:number,rng:&rng), !seen.contains(level.signature) else { continue }
                seen.insert(level.signature); levels.append(level); break
            }
        }
        precondition(levels.count == count,"Memory run levels could not be generated")
        return levels
    }

    private static func make(number: Int, rng: inout SplitMix) -> MemoryLevel? {
        let bars = number >= 37 ? 4 : number >= 13 ? 2 : 1
        var durations: [[Int]] = []
        for bar in 0..<bars {
            let options = patterns(number:number,final:bar == bars-1 && bars > 1)
            var choice = options[rng.next(options.count)]
            // From level 25 the first bar always carries eighth notes.
            if number >= 25, bar == 0, !choice.contains(240) { choice = options.filter { $0.contains(240) }[rng.next(options.filter { $0.contains(240) }.count)] }
            durations.append(choice)
        }
        let total = durations.reduce(0) { $0+$1.count }
        let steps = number >= 19 ? [-3,-2,-1,1,2,3] : [-1,1]
        // Longer phrases close on the tonic; one-bar fragments may stop anywhere in the octave.
        let endings: Set<Int> = bars > 1 ? [0,7] : Set(0...7)
        // Randomised depth-first search for a melody within one octave above the tonic.
        func search(_ path: [Int]) -> [Int]? {
            if path.count == total {
                guard endings.contains(path.last!) else { return nil }
                if number >= 19 && !zip(path,path.dropFirst()).contains(where: { abs($1-$0) == 3 }) { return nil }
                return path
            }
            var options = steps.map { path.last!+$0 }.filter { (0...7).contains($0) }
            for i in options.indices.reversed() { options.swapAt(i,rng.next(i+1)) }
            for next in options { if let found = search(path+[next]) { return found } }
            return nil
        }
        let starts = [0,2,4].shuffledDeterministic(&rng)
        for start in starts { if let degrees = search([start]) {
            return MemoryLevel(number:number,fifths:keyFifths(number),degrees:degrees,durations:durations)
        } }
        return nil
    }
}

struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextValue() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(_ upper: Int) -> Int { upper <= 1 ? 0 : Int(nextValue() % UInt64(upper)) }
}

private extension Array {
    func shuffledDeterministic(_ rng: inout SplitMix) -> [Element] {
        var copy = self
        for i in copy.indices.reversed() { copy.swapAt(i,rng.next(i+1)) }
        return copy
    }
}

// Device-local progress: the highest open level and the best accuracy per level.
struct MemoryLevelProgress: Codable, Equatable {
    var unlocked = 1
    var best: [Int:Int] = [:]
    var cleared: Set<Int> { Set(best.filter { $0.value >= MemoryLevel.passAccuracy }.keys) }
    // Returns true when the result passes. Only the next number opens, and never relocks.
    @discardableResult mutating func record(level: Int, accuracy: Int) -> Bool {
        best[level] = Swift.max(best[level] ?? 0,accuracy)
        guard accuracy >= MemoryLevel.passAccuracy else { return false }
        unlocked = Swift.min(MemoryLevel.count,Swift.max(unlocked,level+1))
        return true
    }
}
