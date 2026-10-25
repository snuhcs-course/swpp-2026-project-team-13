import SwiftUI

protocol ScoreRenderer {
    func render(_ score: MusicScore, context: inout GraphicsContext, size: CGSize)
}

// Limited native notation renderer. Submitted handwriting keeps an independent coordinate system.
struct NativeScoreRenderer: ScoreRenderer {
    func render(_ score: MusicScore, context: inout GraphicsContext, size: CGSize) {
        context.scaleBy(x: size.width / 1330, y: size.width / 1330)
        let bars:[[CGFloat]] = [[54.0,450,725,1000,1276],[54.0,397,690,983,1276]]
        func line(_ a: CGPoint, _ b: CGPoint, width: CGFloat = 1.5) {
            var path = Path(); path.move(to:a); path.addLine(to:b)
            context.stroke(path, with:.color(.black), lineWidth:width)
        }
        func text(_ string:String, x:CGFloat, y:CGFloat, size:CGFloat = 28) {
            context.draw(Text(string).font(.system(size:size)).foregroundColor(.black), at:CGPoint(x:x,y:y))
        }
        for system in 0..<2 {
            let top:CGFloat = system == 0 ? 164.0 : 499.0
            for j in 0..<5 { line(CGPoint(x:54,y:top+CGFloat(j)*12),CGPoint(x:1276,y:top+CGFloat(j)*12)) }
            for x in bars[system] { line(CGPoint(x:x,y:top),CGPoint(x:x,y:top+48)) }
            text("𝄞",x:84,y:top+23,size:75)
            if system == 0 {
                text(String(score.timeSignature.numerator),x:126,y:top+13,size:29)
                text(String(score.timeSignature.denominator),x:126,y:top+37,size:29)
            }
        }
        func position(_ symbol:ScoreSymbol) -> CGPoint {
            let system = (symbol.measure-1)/4, index = (symbol.measure-1)%4
            let left = bars[system][index], right = bars[system][index+1]
            let lead:CGFloat = index == 0 ? (system == 0 ? 112.0 : 75.0) : 35.0
            let fraction = CGFloat(symbol.onset % score.ticksPerMeasure) / CGFloat(score.ticksPerMeasure)
            let diatonic = ["C":0,"D":1,"E":2,"F":3,"G":4,"A":5,"B":6]
            let pitch = symbol.octave*7 + (diatonic[symbol.step ?? "E"] ?? 2)
            return CGPoint(x:left+lead+(right-left-lead-28)*fraction,y:(system == 0 ? 212.0 : 547.0)-CGFloat(pitch-(4*7+2))*6)
        }
        // Flat shared beams make every member use the same stem direction and endpoint.
        var groups:[[Int]] = [], current:[Int] = []
        for (i,n) in score.symbols.enumerated() {
            if n.beams[1] == "begin" { current = [i] }
            else if !current.isEmpty, score.symbols[current[0]].measure == n.measure, n.beams[1] != nil {
                current.append(i)
                if n.beams[1] == "end" { groups.append(current); current = [] }
            } else { current = [] }
        }
        var stems:[Int:(down:Bool,end:CGFloat)] = [:]
        for group in groups {
            let points = group.map { position(score.symbols[$0]) }
            let top:CGFloat = score.symbols[group[0]].measure <= 4 ? 164.0 : 499.0
            let down = points.map { $0.y }.reduce(0,+)/CGFloat(points.count) < top+24
            let end = down ? points.map { $0.y }.max()! + 38 : points.map { $0.y }.min()! - 38
            for index in group { stems[index] = (down,end) }
        }
        var accidentalState:[String:Int] = [:], previousMeasure = 0
        for (i,n) in score.symbols.enumerated() {
            let p = position(n)
            let bottom:CGFloat = n.measure <= 4 ? 212.0 : 547.0
            let top = bottom-48
            if n.measure != previousMeasure { accidentalState = [:]; previousMeasure = n.measure }
            if n.midi == nil {
                let middle = top+24
                if n.type == "whole" || n.type == "half" {
                    context.fill(Path(CGRect(x:p.x-9,y:n.type == "whole" ? middle-12 : middle-6,width:18,height:6)),with:.color(.black))
                } else if n.type == "quarter" {
                    var rest = Path(); rest.move(to:CGPoint(x:p.x-4,y:middle-20)); rest.addLine(to:CGPoint(x:p.x+6,y:middle-9)); rest.addLine(to:CGPoint(x:p.x-4,y:middle+2)); rest.addLine(to:CGPoint(x:p.x+5,y:middle+12)); rest.addQuadCurve(to:CGPoint(x:p.x-4,y:middle+22),control:CGPoint(x:p.x-14,y:middle+12)); context.stroke(rest,with:.color(.black),lineWidth:4)
                } else {
                    let count = n.type == "16th" ? 2 : 1
                    for k in 0..<count { context.fill(Path(ellipseIn:CGRect(x:p.x-7-CGFloat(k)*3,y:middle-8+CGFloat(k)*8,width:9,height:8)),with:.color(.black)) }
                    line(CGPoint(x:p.x+3,y:middle-7),CGPoint(x:p.x-5,y:middle+20),width:3)
                }
                for dot in 0..<n.dots { context.fill(Path(ellipseIn:CGRect(x:p.x+13+CGFloat(dot)*7,y:middle-4,width:4,height:4)),with:.color(.black)) }
                continue
            }
            if p.y >= bottom+12 { for y in stride(from:bottom+12,through:p.y,by:12) { line(CGPoint(x:p.x-15,y:y),CGPoint(x:p.x+15,y:y)) } }
            if p.y <= top-12 { for y in stride(from:top-12,through:p.y,by:-12) { line(CGPoint(x:p.x-15,y:y),CGPoint(x:p.x+15,y:y)) } }
            let head = Path(ellipseIn:CGRect(x:p.x-10,y:p.y-6,width:20,height:12))
            if n.type == "whole" || n.type == "half" { context.stroke(head,with:.color(.black),lineWidth:2.5) } else { context.fill(head,with:.color(.black)) }
            let down = stems[i]?.down ?? (p.y < top+24)
            if n.type != "whole" {
                let x = p.x+(down ? -9 : 9), end = stems[i]?.end ?? (p.y+(down ? 38 : -38))
                line(CGPoint(x:x,y:p.y),CGPoint(x:x,y:end),width:2)
                if stems[i] == nil {
                    let count = n.type == "16th" ? 2 : n.type == "eighth" ? 1 : 0
                    for k in 0..<count {
                        let y = end+CGFloat(k)*(down ? -7 : 7)
                        var flag = Path(); flag.move(to:CGPoint(x:x,y:y)); flag.addQuadCurve(to:CGPoint(x:x+13,y:y+(down ? -21 : 21)),control:CGPoint(x:x+25,y:y+(down ? -9 : 9))); context.stroke(flag,with:.color(.black),lineWidth:3)
                    }
                }
            }
            let key = "\(n.step ?? "")\(n.octave)", prior = accidentalState[key] ?? 0
            if n.alter != prior && !n.tieStop { text(n.alter == 0 ? "♮" : n.alter == 1 ? "♯" : n.alter == -1 ? "♭" : n.alter == 2 ? "𝄪" : "𝄫",x:p.x-23,y:p.y,size:28) }
            accidentalState[key] = n.alter
            for dot in 0..<n.dots { context.fill(Path(ellipseIn:CGRect(x:p.x+16+CGFloat(dot)*7,y:p.y-5,width:4,height:4)),with:.color(.black)) }
            if n.tieStart, i+1 < score.symbols.count {
                let next = position(score.symbols[i+1]); let end = next.x > p.x ? CGPoint(x:next.x-9,y:next.y+12) : CGPoint(x:1270,y:p.y+12)
                var tie = Path(); tie.move(to:CGPoint(x:p.x+8,y:p.y+12)); tie.addQuadCurve(to:end,control:CGPoint(x:(p.x+end.x)/2,y:p.y+34)); context.stroke(tie,with:.color(.black),lineWidth:2)
            }
            if n.tieStop, i > 0, score.symbols[i-1].measure == 4 && n.measure == 5 {
                var tie = Path(); tie.move(to:CGPoint(x:115,y:p.y+12)); tie.addQuadCurve(to:CGPoint(x:p.x-8,y:p.y+12),control:CGPoint(x:125,y:p.y+32)); context.stroke(tie,with:.color(.black),lineWidth:2)
            }
        }
        for group in groups {
            for level in 1...2 {
                for (offset,index) in group.enumerated() {
                    guard let beam = score.symbols[index].beams[level], let stem = stems[index] else { continue }
                    let p = position(score.symbols[index]); let x = p.x+(stem.down ? -9 : 9), y = stem.end+CGFloat(level-1)*(stem.down ? -7 : 7)
                    if ["begin","continue"].contains(beam), offset+1 < group.count, score.symbols[group[offset+1]].beams[level] != nil {
                        let next = position(score.symbols[group[offset+1]])
                        line(CGPoint(x:x,y:y),CGPoint(x:next.x+(stem.down ? -9 : 9),y:y),width:5)
                    } else if beam == "forward hook" || beam == "backward hook" {
                        line(CGPoint(x:x,y:y),CGPoint(x:x+(beam == "forward hook" ? 13 : -13),y:y),width:5)
                    }
                }
            }
        }
        for (i,n) in score.symbols.enumerated() where n.tupletStart {
            guard let endIndex = (i..<score.symbols.count).first(where:{ score.symbols[$0].measure == n.measure && score.symbols[$0].tupletStop }) else { continue }
            let a = position(n), b = position(score.symbols[endIndex])
            let top:CGFloat = n.measure <= 4 ? 164.0 : 499.0
            let y = min(top-20,(i...endIndex).map { stems[$0]?.end ?? (position(score.symbols[$0]).y-42) }.min()! - 16)
            text(String(n.tupletActual),x:(a.x+b.x)/2,y:y,size:20)
            line(CGPoint(x:a.x,y:y+7),CGPoint(x:(a.x+b.x)/2-12,y:y+7),width:1)
            line(CGPoint(x:(a.x+b.x)/2+12,y:y+7),CGPoint(x:b.x,y:y+7),width:1)
        }
    }
}
struct ScoreView: View {
    let score:MusicScore
    var body: some View { Canvas { context,size in NativeScoreRenderer().render(score,context:&context,size:size) }.aspectRatio(1330.0/846,contentMode:.fit).background(.white).accessibilityLabel("제출 후 확인하는 정답 악보, 8마디") }
}
