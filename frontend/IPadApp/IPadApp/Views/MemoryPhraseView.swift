import SwiftUI

private struct MemoryGlyphBank: Decodable { let renderer: String; let glyphs: [String:RhythmVectorPath] }
enum MemoryGlyphInk {
    static let glyphs: [String:RhythmVectorPath] = {
        let bank: MemoryGlyphBank? = try? Bundled.decode("memory-glyphs-v1")
        return bank?.glyphs ?? [:]
    }()
    static func draw(_ name: String, at point: CGPoint, in context: GraphicsContext, color: Color) {
        guard let glyph = glyphs[name] else { return }
        let path = RhythmInk.path(glyph.commands).applying(CGAffineTransform(translationX:point.x,y:point.y))
        context.fill(path,with:.color(color),style:FillStyle(eoFill:false))
    }
}

struct MemoryPhraseView: View {
    let round: MelodyRound
    let answers: [Int?]
    var reveal = false
    var markErrors = false
    var selectedBar: Int? = nil
    var selectBar: ((Int)->Void)? = nil
    var body: some View {
        let shown = round.phraseDisplay(answers:answers,reveal:reveal)
        // Both comparison panels include both pitch ranges, so their heights match too.
        let comparison = round.phraseDisplay(answers:answers).0
        VStack(spacing:0) {
            ForEach(0..<((round.score.measures+1)/2),id:\.self) { row in
                let bars = Array((row*2+1)...min(round.score.measures,row*2+2))
                let layout = MemoryPhraseLayout(source:round.score,displayed:comparison,bars:bars,fifths:round.source.fifths,clef:round.source.clef)
                MemoryPhraseSystem(score:shown.0,layout:layout,clef:round.source.clef,fifths:round.source.fifths,
                    pending:shown.1,wrong:markErrors ? shown.2 : [],selectedBar:selectedBar,selectBar:selectBar)
            }
        }.accessibilityLabel("\(round.score.measures)마디 악보, \(shown.1.count)개 음표 미입력")
    }
}

private struct MemoryPhraseSystem: View {
    let score: MusicScore; let layout: MemoryPhraseLayout; let clef: String; let fifths: Int
    let pending: Set<Int>; let wrong: Set<Int>; let selectedBar: Int?; let selectBar: ((Int)->Void)?
    @State private var available = CGFloat(800)
    private var scale: CGFloat { min(1.35,max(0.7,available/CGFloat(layout.width))) }
    var body: some View {
        ScrollView(.horizontal,showsIndicators:false) {
            Canvas { context,_ in
                context.scaleBy(x:scale,y:scale)
                render(in:context)
            }.frame(width:CGFloat(layout.width)*scale,height:CGFloat(layout.height)*scale)
                .overlay {
                    if let selectBar {
                        MiniGameTouchSurface(tapOnly:true,ended:{ _,point,tap in
                            guard tap, let bar = layout.bars.first(where:{ CGFloat($0.x)*scale <= point.x && point.x <= CGFloat($0.x+$0.width)*scale }) else { return }
                            selectBar(bar.number)
                        }).accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children:.contain)
                .overlay(alignment:.topLeading) {
                    if let selectBar {
                        HStack(spacing:0) {
                            ForEach(layout.bars,id:\.number) { bar in
                                Button("\(bar.number)마디 선택") { selectBar(bar.number) }
                                    .frame(width:CGFloat(bar.width)*scale,height:1).opacity(0.01)
                            }
                        }.accessibilityHidden(false)
                    }
                }
                .frame(minWidth:available,alignment:.center)
        }.frame(height:CGFloat(layout.height)*scale)
            .background(GeometryReader { geo in Color.clear.onAppear { available = geo.size.width }.onChange(of:geo.size.width) { _,w in available = w } })
            .background(.white)
    }
    private func render(in context: GraphicsContext) {
        let middle = CGFloat(layout.middle), top = middle-16, bottom = middle+16
        func line(_ a: CGPoint,_ b: CGPoint,_ color: Color = .black,_ width: CGFloat = 0.8) {
            var p = Path(); p.move(to:a); p.addLine(to:b); context.stroke(p,with:.color(color),lineWidth:width)
        }
        for bar in layout.bars {
            if selectedBar == bar.number {
                context.fill(Path(roundedRect:CGRect(x:bar.x+1,y:20,width:bar.width-2,height:layout.height-25),cornerRadius:8),with:.color(SolfegeTheme.violet.opacity(0.045)))
            }
            context.draw(Text("\(bar.number)").font(.system(size:10)).foregroundColor(.secondary),at:CGPoint(x:bar.x+8,y:14))
            line(CGPoint(x:bar.x,y:top),CGPoint(x:bar.x,y:bottom))
        }
        for j in -2...2 { line(CGPoint(x:0,y:middle+CGFloat(j)*8),CGPoint(x:layout.width,y:middle+CGFloat(j)*8),.black.opacity(0.65),0.65) }
        line(CGPoint(x:layout.width,y:top),CGPoint(x:layout.width,y:bottom))
        MemoryGlyphInk.draw("clef-"+clef,at:CGPoint(x:21,y:middle),in:context,color:.black)
        let keyPositions = fifths >= 0 ? [-16,-4,-20,-8,4,-12,0] : [0,-12,4,-8,8,-4,12]
        for i in 0..<abs(fifths) {
            MemoryGlyphInk.draw("accidental-\(fifths > 0 ? 1 : -1)",at:CGPoint(x:CGFloat(42+i*8),y:middle+CGFloat(keyPositions[i])+(clef == "F" ? 8 : 0)),in:context,color:.black)
        }
        if layout.bars.first?.number == 1 {
            let x = CGFloat(59+abs(fifths)*8)
            context.draw(Text(String(score.timeSignature.numerator)).font(.system(size:18,weight:.bold,design:.serif)),at:CGPoint(x:x,y:middle-8))
            context.draw(Text(String(score.timeSignature.denominator)).font(.system(size:18,weight:.bold,design:.serif)),at:CGPoint(x:x,y:middle+8))
        }
        let indices = score.symbols.indices.filter { index in layout.bars.contains(where:{$0.number == score.symbols[index].measure}) }
        func position(_ index: Int) -> CGPoint {
            CGPoint(x:layout.positions[index],y:layout.middle+MemoryPhraseLayout.pitchOffset(score.symbols[index],clef:clef))
        }
        func ink(_ i: Int) -> Color { pending.contains(i) ? .gray.opacity(0.32) : wrong.contains(i) ? .red.opacity(0.8) : .black }
        var groups: [[Int]] = [], group: [Int] = []
        for i in indices {
            let n = score.symbols[i]
            if n.beams[1] == "begin" { group = [i] }
            else if let first = group.first, n.measure == score.symbols[first].measure, n.beams[1] != nil {
                group.append(i)
                if n.beams[1] == "end" { groups.append(group); group = [] }
            } else { group = [] }
        }
        var stems: [Int:(Bool,CGFloat)] = [:]
        for group in groups {
            let ys = group.map { position($0).y }, down = group.map { position($0).y }.reduce(0,+)/CGFloat(group.count) < middle
            let end = down ? ys.max()!+29 : ys.min()!-29
            for i in group { stems[i] = (down,end) }
        }
        var state: [String:Int] = [:], bar = 0
        let altered = Array((fifths >= 0 ? "FCGDAEB" : "BEADGCF").prefix(abs(fifths))).map(String.init)
        for i in indices {
            let n = score.symbols[i], p = position(i), color = ink(i)
            if n.measure != bar { state = [:]; bar = n.measure }
            if n.midi == nil {
                MemoryGlyphInk.draw("rest-"+n.type,at:CGPoint(x:p.x,y:middle),in:context,color:.black)
                for d in 0..<n.dots { context.fill(Path(ellipseIn:CGRect(x:p.x+9+CGFloat(d)*4,y:middle-2,width:2.5,height:2.5)),with:.color(.black)) }
                continue
            }
            if p.y <= top-8 { for y in stride(from:top-8,through:p.y,by:-8) { line(CGPoint(x:p.x-8,y:y),CGPoint(x:p.x+8,y:y),color) } }
            if p.y >= bottom+8 { for y in stride(from:bottom+8,through:p.y,by:8) { line(CGPoint(x:p.x-8,y:y),CGPoint(x:p.x+8,y:y),color) } }
            MemoryGlyphInk.draw("note-"+n.type,at:p,in:context,color:color)
            if pending.contains(i) {
                context.stroke(Path(ellipseIn:CGRect(x:p.x-8,y:p.y-7,width:16,height:14)),with:.color(.gray.opacity(0.35)),style:StrokeStyle(lineWidth:0.7,dash:[2,2]))
            }
            let down = stems[i]?.0 ?? (p.y < middle), stemX = p.x+(down ? -4.6 : 4.6)
            let end = stems[i]?.1 ?? (p.y+(down ? 29 : -29))
            if n.type != "whole" {
                line(CGPoint(x:stemX,y:p.y),CGPoint(x:stemX,y:end),color,0.9)
                if stems[i] == nil { MemoryGlyphInk.draw("flag-"+n.type+(down ? "-down" : "-up"),at:CGPoint(x:stemX,y:end),in:context,color:color) }
            }
            let key = "\(n.step ?? "")\(n.octave)", prior = state[key] ?? (altered.contains(n.step ?? "") ? (fifths >= 0 ? 1 : -1) : 0)
            if !pending.contains(i) {
                if n.alter != prior && !n.tieStop { MemoryGlyphInk.draw("accidental-\(n.alter)",at:CGPoint(x:p.x-12,y:p.y),in:context,color:color) }
                state[key] = n.alter
            }
            for d in 0..<n.dots { context.fill(Path(ellipseIn:CGRect(x:p.x+9+CGFloat(d)*4,y:p.y-3,width:2.5,height:2.5)),with:.color(color)) }
            if n.tieStart {
                let next = i+1
                let endpoint = indices.contains(next) ? CGPoint(x:position(next).x-5,y:position(next).y+8) : CGPoint(x:layout.width-2,y:p.y+8)
                let path = indices.contains(next) ? RhythmInk.tie(from:CGPoint(x:p.x+5,y:p.y+8),to:endpoint) : RhythmInk.brokenTie(from:CGPoint(x:p.x+5,y:p.y+8),to:endpoint,continuesRight:true)
                context.fill(path,with:.color(color))
            }
            if n.tieStop, !indices.contains(i-1) { context.fill(RhythmInk.brokenTie(from:CGPoint(x:p.x-25,y:p.y+8),to:CGPoint(x:p.x-5,y:p.y+8),continuesRight:false),with:.color(color)) }
        }
        for group in groups {
            for level in 1...4 {
                for (offset,i) in group.enumerated() {
                    guard let beam = score.symbols[i].beams[level], let stem = stems[i] else { continue }
                    let p = position(i), x = p.x+(stem.0 ? -4.6 : 4.6), y = stem.1+CGFloat(level-1)*(stem.0 ? -5 : 5)
                    if ["begin","continue"].contains(beam),offset+1 < group.count,score.symbols[group[offset+1]].beams[level] != nil {
                        line(CGPoint(x:x,y:y),CGPoint(x:position(group[offset+1]).x+(stem.0 ? -4.6 : 4.6),y:y),ink(i),3.2)
                    } else if beam.contains("hook") { line(CGPoint(x:x,y:y),CGPoint(x:x+(beam == "forward hook" ? 9 : -9),y:y),ink(i),3.2) }
                }
            }
        }
        for i in indices where score.symbols[i].tupletStart {
            guard let end = indices.first(where:{$0 >= i && score.symbols[$0].measure == score.symbols[i].measure && score.symbols[$0].tupletStop}) else { continue }
            let a = position(i), b = position(end)
            let y = min(top-14,(i...end).map { stems[$0]?.1 ?? position($0).y-29 }.min()!-12)
            context.draw(Text(String(score.symbols[i].tupletActual)).font(.system(size:11,weight:.medium)),at:CGPoint(x:(a.x+b.x)/2,y:y))
            line(CGPoint(x:a.x,y:y+4),CGPoint(x:(a.x+b.x)/2-6,y:y+4),.black,0.6)
            line(CGPoint(x:(a.x+b.x)/2+6,y:y+4),CGPoint(x:b.x,y:y+4),.black,0.6)
        }
    }
}
