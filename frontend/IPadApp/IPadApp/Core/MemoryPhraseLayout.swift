import Foundation

extension MelodyRound {
    func phraseDisplay(answers: [Int?], reveal: Bool = false) -> (MusicScore,Set<Int>,Set<Int>) {
        var symbols: [ScoreSymbol] = [], pending: Set<Int> = [], wrong: Set<Int> = []
        for bar in 1...score.measures {
            let part = display(measure:bar,answers:answers,reveal:reveal)
            pending.formUnion(part.1.map { $0+symbols.count }); wrong.formUnion(part.2.map { $0+symbols.count })
            symbols += part.0.symbols.map { n in var n = n; n.measure = bar; n.onset += (bar-1)*score.ticksPerMeasure; return n }
        }
        var value = score; value.symbols = symbols
        return (value,pending,wrong)
    }
}

// Shared source-rhythm coordinates for the correct phrase and every editable answer.
struct MemoryPhraseLayout {
    struct Bar { let number: Int; let x: Double; let width: Double }
    let bars: [Bar]; let positions: [Double]; let width: Double
    let middle: Double; let height: Double
    static func pitchOffset(_ n: ScoreSymbol, clef: String) -> Double {
        guard n.midi != nil else { return 0 }
        let step = ["C":0,"D":1,"E":2,"F":3,"G":4,"A":5,"B":6][n.step ?? "B"] ?? 6
        return Double((clef == "F" ? 22 : 34)-(n.octave*7+step))*4
    }
    init(source: MusicScore, displayed: MusicScore, bars numbers: [Int], fifths: Int, clef: String) {
        var x = 0.0, points = Array(repeating:0.0,count:source.symbols.count), bars: [Bar] = []
        for (offset,bar) in numbers.enumerated() {
            let start = x
            x += offset == 0 ? 82+Double(abs(fifths))*8 : 20
            for i in source.symbols.indices where source.symbols[i].measure == bar {
                let n = source.symbols[i]
                x += 10 // reserves accidental space even if the learner changes the pitch
                points[i] = x
                x += max(19,min(39,27*sqrt(max(0.0625,Double(n.duration)/480))))+Double(n.dots)*4
            }
            x += 14; bars.append(Bar(number:bar,x:start,width:x-start))
        }
        let offsets = (source.symbols+displayed.symbols).filter { numbers.contains($0.measure) && $0.midi != nil }.map { Self.pitchOffset($0,clef:clef) }
        middle = max(65,45-(offsets.min() ?? 0))
        height = max(middle+58,middle+(offsets.max() ?? 0)+36)
        self.bars = bars; positions = points; width = max(160,x)
    }
}
