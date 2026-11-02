import Foundation

// Mini-games own their state and never create or submit an Exam attempt.
enum MelodyMode: String, CaseIterable, Identifiable {
    case memory, groove
    var id: String { rawValue }
    var title: String { self == .memory ? "메모리" : "그루브" }
}

struct MelodySettings: Equatable {
    var mode: MelodyMode = .memory
    var bars = 4
    var startBar = 1
    var bpm = 96.0 // Quarter-note BPM, including compound meters.
    var gapMeasures = 1
    var inputBars = 2
    var advanceEarly = false
    func validate() throws {
        guard [2,4,8].contains(bars), (1...(9-bars)).contains(startBar),
              (40...180).contains(bpm), (1...4).contains(gapMeasures), (1...4).contains(inputBars) else {
            throw SORIError.invalidScore("멜로디 런 설정을 확인해 주세요.")
        }
    }
}

struct MelodyQuestion: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var file: String
    var key: String
    var beats: Int
    var beatType: Int
    var noteCount: Int
    var lowestMidi: Int
    var highestMidi: Int
    var sourceURL: String
    var fifths: Int? = nil
    var mode: String? = nil
    var isDemoEligible: Bool {
        if let fifths, let mode { return fifths == 0 && ["major","minor"].contains(mode) }
        return ["C major","A minor"].contains(key)
    }
}

struct MelodySource {
    var score: MusicScore
    var fifths: Int
    var mode: String
    var clef: String
    var isDemoEligible: Bool { fifths == 0 && ["major","minor"].contains(mode) }
    func validateDemoKey() throws {
        guard isDemoEligible else { throw SORIError.invalidScore("현재 데모에서는 조표 없는 다장조·가단조 문제만 사용할 수 있어요.") }
    }
    var keyLabel: String {
        let names = mode == "minor" ? ["Ab","Eb","Bb","F","C","G","D","A","E","B","F#","C#","G#","D#","A#"] : ["Cb","Gb","Db","Ab","Eb","Bb","F","C","G","D","A","E","B","F#","C#"]
        return names[min(14,max(0,fifths+7))]+" "+mode
    }
}

struct MelodyTarget: Equatable {
    var symbolIndices: [Int]
    var measure: Int
    var midi: Int
}

struct MelodyRound {
    let source: MelodySource
    let score: MusicScore
    let targets: [MelodyTarget]
    let symbolTargets: [Int: Int]

    init(source: MelodySource, start: Int, bars: Int) throws {
        guard start >= 1, bars > 0, start+bars-1 <= source.score.measures else {
            throw SORIError.invalidScore("플레이할 마디 범위를 확인해 주세요.")
        }
        self.source = source
        let ticks = source.score.ticksPerMeasure, offset = (start-1)*ticks
        var symbols = source.score.symbols.filter { (start..<(start+bars)).contains($0.measure) }
        for i in symbols.indices { symbols[i].measure -= start-1; symbols[i].onset -= offset }
        // A slice beginning/ending inside a tie is an independently playable phrase.
        if let i = symbols.firstIndex(where: { $0.midi != nil }) { symbols[i].tieStop = false }
        if let i = symbols.lastIndex(where: { $0.midi != nil }) { symbols[i].tieStart = false }
        var targets: [MelodyTarget] = [], mapping: [Int:Int] = [:], open: Int?
        for (i, symbol) in symbols.enumerated() {
            guard let midi = symbol.midi else { continue }
            let target: Int
            if symbol.tieStop, let prior = open {
                target = prior; targets[target].symbolIndices.append(i)
            } else {
                target = targets.count
                targets.append(MelodyTarget(symbolIndices:[i],measure:symbol.measure,midi:midi))
            }
            mapping[i] = target
            open = symbol.tieStart ? target : nil
        }
        self.targets = targets; self.symbolTargets = mapping
        self.score = MusicScore(tempo:source.score.tempo,measures:bars,
            events:try source.score.segment(from:start,through:start+bars-1),symbols:symbols,
            timeSignature:source.score.timeSignature)
    }

    func targetIndices(measure: Int) -> [Int] { targets.indices.filter { targets[$0].measure == measure } }
    var keyboardRange: ClosedRange<Int> {
        let low = targets.map(\.midi).min() ?? 60, high = targets.map(\.midi).max() ?? 72
        let bottom = max(24, (low/12)*12)
        return bottom...min(108,max(bottom+24,((high+11)/12)*12))
    }

    func events(answers: [Int?]) -> [MusicEvent] {
        var result: [MusicEvent] = []
        for (index,target) in targets.enumerated() {
            guard answers.indices.contains(index), let midi = answers[index],
                  let first = target.symbolIndices.first else { continue }
            result.append(MusicEvent(midi:midi,onset:score.symbols[first].onset,
                duration:target.symbolIndices.reduce(0) { $0+score.symbols[$1].duration }))
        }
        return result
    }

    // Uses the existing renderer with rhythm intact; unanswered pitches sit on a neutral line.
    func display(measure: Int, answers: [Int?], reveal: Bool = false) -> (MusicScore, Set<Int>, Set<Int>) {
        let indices = score.symbols.indices.filter { score.symbols[$0].measure == measure }
        var symbols: [ScoreSymbol] = [], pending: Set<Int> = [], wrong: Set<Int> = []
        for originalIndex in indices {
            var symbol = score.symbols[originalIndex]
            symbol.measure = 1; symbol.onset -= (measure-1)*score.ticksPerMeasure
            if let target = symbolTargets[originalIndex] {
                let answer = answers.indices.contains(target) ? answers[target] : nil
                if !reveal {
                    if let answer, answer != targets[target].midi {
                        let pitch = Self.spelling(answer, fifths:source.fifths)
                        symbol.midi = answer; symbol.step = pitch.0; symbol.octave = pitch.1; symbol.alter = pitch.2
                    } else if answer == nil {
                        pending.insert(symbols.count)
                        symbol.midi = source.clef == "F" ? 50 : 71
                        symbol.step = source.clef == "F" ? "D" : "B"
                        symbol.octave = source.clef == "F" ? 3 : 4; symbol.alter = 0
                    }
                }
                if answer != targets[target].midi { wrong.insert(symbols.count) }
            }
            symbols.append(symbol)
        }
        return (MusicScore(tempo:score.tempo,measures:1,events:[],symbols:symbols,timeSignature:score.timeSignature),pending,wrong)
    }

    static func spelling(_ midi: Int, fifths: Int) -> (String,Int,Int) {
        let sharp = [("C",0),("C",1),("D",0),("D",1),("E",0),("F",0),("F",1),("G",0),("G",1),("A",0),("A",1),("B",0)]
        let flat = [("C",0),("D",-1),("D",0),("E",-1),("E",0),("F",0),("G",-1),("G",0),("A",-1),("A",0),("B",-1),("B",0)]
        let pitch = (fifths < 0 ? flat : sharp)[midi % 12]
        return (pitch.0,midi/12-1,pitch.1)
    }
    static func noteName(_ midi: Int?) -> String {
        guard let midi else { return "미입력" }
        return ["C","C♯","D","E♭","E","F","F♯","G","A♭","A","B♭","B"][midi % 12]+String(midi/12-1)
    }
}

struct MelodyAnswers {
    let round: MelodyRound
    private(set) var pitches: [Int?]
    // Undo follows actual input order, including after moving to another bar.
    private var history: [Int] = []
    init(round: MelodyRound) { self.round = round; pitches = Array(repeating:nil,count:round.targets.count) }
    func next(in measure: Int) -> Int? { round.targetIndices(measure:measure).first { pitches[$0] == nil } }
    func complete(_ measure: Int) -> Bool { next(in:measure) == nil }
    @discardableResult mutating func enter(_ midi: Int, measure: Int) -> Bool {
        guard (0...127).contains(midi), let index = next(in:measure) else { return false }
        pitches[index] = midi; history.append(index); return true
    }
    @discardableResult mutating func undo(in measure: Int? = nil) -> Int? {
        guard let index = history.last, measure == nil || round.targets[index].measure == measure else { return nil }
        history.removeLast()
        pitches[index] = nil; return round.targets[index].measure
    }
    mutating func clear(measure: Int) {
        let indices = Set(round.targetIndices(measure:measure))
        for i in indices { pitches[i] = nil }; history.removeAll { indices.contains($0) }
    }
    var result: MelodyResult { MelodyResult(expected:round.targets.map(\.midi),actual:pitches) }
}

struct MelodyResult {
    let expected: [Int]
    let actual: [Int?]
    var correct: Int { expected.indices.filter { actual.indices.contains($0) && actual[$0] == expected[$0] }.count }
    var accuracy: Int { expected.isEmpty ? 0 : Int((Double(correct)*100/Double(expected.count)).rounded()) }
    var bestCombo: Int {
        var best = 0, current = 0
        for i in expected.indices {
            current = actual.indices.contains(i) && actual[i] == expected[i] ? current+1 : 0
            best = max(best,current)
        }
        return best
    }
    var points: Int {
        var points = 0, combo = 0
        for i in expected.indices {
            if actual.indices.contains(i), actual[i] == expected[i] { combo += 1; points += 100+min(combo-1,10)*10 }
            else { combo = 0 }
        }
        return points
    }
}

enum MelodyPhase: String { case countIn, listen, beat, input }
struct MelodyWindow: Equatable {
    var phase: MelodyPhase
    var measure: Int
    var start: Int
    var end: Int
}
struct MelodyTimeline {
    static let earlyInputMilliseconds = 180
    static let audioLeadMilliseconds = 150
    static func ticks(milliseconds: Int, bpm: Double) -> Int {
        Int(ceil(Double(milliseconds)/1000*bpm/60*480))
    }
    var windows: [MelodyWindow]
    let pulseTicks: Int
    let meter: TimeSignature
    var end: Int { windows.last?.end ?? 0 }
    init(round: MelodyRound, settings: MelodySettings, fromMeasure: Int = 1) {
        meter = round.score.timeSignature
        // Count every notated beat: 3/4 = three quarters, 6/8 = six eighths.
        // All preparation windows contain complete measures, even after an early advance.
        pulseTicks = 1920/meter.denominator
        var windows: [MelodyWindow] = [], tick = 0
        func append(_ phase: MelodyPhase, _ measure: Int, _ duration: Int) {
            guard duration > 0 else { return }
            windows.append(MelodyWindow(phase:phase,measure:measure,start:tick,end:tick+duration)); tick += duration
        }
        append(.countIn,fromMeasure,meter.ticksPerMeasure)
        for measure in fromMeasure...round.score.measures {
            append(.listen,measure,meter.ticksPerMeasure)
            if settings.mode == .memory { append(.beat,measure,settings.gapMeasures*meter.ticksPerMeasure) }
            else {
                append(.beat,measure,meter.ticksPerMeasure)
                append(.input,measure,settings.inputBars*meter.ticksPerMeasure)
            }
        }
        self.windows = windows
    }
    func index(at tick: Int) -> Int? { windows.firstIndex { $0.start <= tick && tick < $0.end } }
    func inputIndex(at tick: Int, bpm: Double) -> Int? {
        let early = Self.ticks(milliseconds:Self.earlyInputMilliseconds,bpm:bpm)
        return windows.firstIndex { $0.phase == .input && $0.start-early <= tick && tick < $0.end }
    }
    func clickEvents(leadTicks: Int = 0) -> [MusicEvent] {
        stride(from:0,to:end,by:pulseTicks).map { MusicEvent(midi:60,onset:$0+leadTicks,duration:30) }
    }
    // Early completion advances on the next beat with enough audio scheduling lead time.
    // The sequencer clock and click track never restart or seek.
    @discardableResult mutating func shortenInput(at index: Int, now: Int, lead: Int) -> Bool {
        guard windows.indices.contains(index), windows[index].phase == .input else { return false }
        // Early input must never consume any of the preceding preparation beats.
        let boundary = max(windows[index].start+pulseTicks,((now+lead+pulseTicks-1)/pulseTicks)*pulseTicks)
        guard boundary < windows[index].end else { return false }
        let removed = windows[index].end-boundary
        windows[index].end = boundary
        for i in (index+1)..<windows.count { windows[i].start -= removed; windows[i].end -= removed }
        return true
    }
    func midi(tempo: Double, leadTicks: Int = 0) -> Data {
        // The reference track is explicitly appended by the audio service. Do not rely
        // on a MIDI importer retaining an empty tempo-only track as a music track.
        return MIDIFile.make(events:clickEvents(leadTicks:leadTicks),totalTicks:end+leadTicks,tempo:tempo,velocity:75,firstNoteVelocity:105)
    }
}
