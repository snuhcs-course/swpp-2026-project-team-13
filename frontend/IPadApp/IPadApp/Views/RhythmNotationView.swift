import SwiftUI

// A single-line rhythm staff: exact timing, readable note values, grouped tuplets.
// It intentionally contains no source pitches or accidentals.
struct RhythmNotationView: View {
    let symbols: [RhythmSymbol]
    let duration: RhythmTime
    var body: some View {
        Canvas { context,size in
            let y: CGFloat = 49, stem: CGFloat = 17, padding: CGFloat = 15
            let usable = max(1,size.width-2*padding)
            var offset = RhythmTime.zero, points: [CGFloat] = []
            for n in symbols { points.append(padding+CGFloat((offset/duration).value)*usable); offset = offset+n.duration }
            func line(_ a: CGPoint,_ b: CGPoint,_ width: CGFloat = 1.4,_ color: Color = .black) {
                var p = Path(); p.move(to:a); p.addLine(to:b); context.stroke(p,with:.color(color),lineWidth:width)
            }
            func text(_ value: String,_ x: CGFloat,_ y: CGFloat,_ size: CGFloat = 13) {
                context.draw(Text(value).font(.system(size:size,weight:.medium)).foregroundColor(.black),at:CGPoint(x:x,y:y))
            }
            func flags(_ n: RhythmSymbol) -> Int { ["eighth":1,"16th":2,"32nd":3,"64th":4,"128th":5][n.type] ?? 0 }
            line(CGPoint(x:0,y:y),CGPoint(x:size.width,y:y),0.8,.gray.opacity(0.4))
            var groups: [[Int]] = [], group: [Int] = []
            for i in symbols.indices {
                let n = symbols[i]
                let matches = group.last.map { symbols[$0].group == n.group && !symbols[$0].groupEnd } ?? true
                if n.rest || flags(n) == 0 || !matches {
                    if !group.isEmpty { groups.append(group); group = [] }
                }
                if !n.rest && flags(n) > 0 { group.append(i) }
            }
            if !group.isEmpty { groups.append(group) }
            let beamed = Set(groups.filter { $0.count > 1 }.flatMap { $0 })
            for (i,n) in symbols.enumerated() {
                let x = points[i]
                if n.rest {
                    if n.type == "whole" || n.type == "half" {
                        context.fill(Path(CGRect(x:x-5,y:n.type == "whole" ? y : y-4,width:12,height:4)),with:.color(.black))
                    } else if n.type == "quarter" {
                        var p = Path(); p.move(to:CGPoint(x:x-3,y:y-15)); p.addLine(to:CGPoint(x:x+4,y:y-6)); p.addLine(to:CGPoint(x:x-3,y:y+2)); p.addLine(to:CGPoint(x:x+4,y:y+9)); p.addQuadCurve(to:CGPoint(x:x-3,y:y+15),control:CGPoint(x:x-10,y:y+8)); context.stroke(p,with:.color(.black),lineWidth:2.5)
                    } else {
                        for k in 0..<max(1,flags(n)) { context.fill(Path(ellipseIn:CGRect(x:x-5-CGFloat(k)*2,y:y-8+CGFloat(k)*5,width:6,height:5)),with:.color(.black)) }
                        line(CGPoint(x:x+3,y:y-9),CGPoint(x:x-3,y:y+13),2)
                    }
                } else {
                    let head = Path(ellipseIn:CGRect(x:x-5,y:y-3.5,width:n.type == "whole" ? 13 : 11,height:7))
                    if n.type == "whole" || n.type == "half" { context.stroke(head,with:.color(.black),lineWidth:1.7) }
                    else { context.fill(head,with:.color(.black)) }
                    if n.type != "whole" { line(CGPoint(x:x+5,y:y),CGPoint(x:x+5,y:stem),1.3) }
                    if !beamed.contains(i) {
                        for k in 0..<flags(n) {
                            let top = stem+CGFloat(k)*5
                            var flag = Path(); flag.move(to:CGPoint(x:x+5,y:top)); flag.addQuadCurve(to:CGPoint(x:x+13,y:top+15),control:CGPoint(x:x+24,y:top+5)); context.stroke(flag,with:.color(.black),lineWidth:2)
                        }
                    }
                    if n.tieNext {
                        let next = i+1 < points.count ? points[i+1]-5 : size.width-2
                        var tie = Path(); tie.move(to:CGPoint(x:x+4,y:y+8)); tie.addQuadCurve(to:CGPoint(x:max(x+7,next),y:y+8),control:CGPoint(x:(x+next)/2,y:y+25)); context.stroke(tie,with:.color(.black),lineWidth:1.5)
                    }
                }
                for dot in 0..<n.dots { context.fill(Path(ellipseIn:CGRect(x:x+11+CGFloat(dot)*5,y:y-5,width:3,height:3)),with:.color(.black)) }
            }
            for indices in groups where indices.count > 1 {
                let levels = indices.map { flags(symbols[$0]) }.max() ?? 1
                for level in 1...levels {
                    for (j,i) in indices.enumerated() where flags(symbols[i]) >= level {
                        let x = points[i]+5, top = stem+CGFloat(level-1)*5
                        if j+1 < indices.count, flags(symbols[indices[j+1]]) >= level {
                            line(CGPoint(x:x,y:top),CGPoint(x:points[indices[j+1]]+5,y:top),3.3)
                        } else if level > 1 && (j == 0 || flags(symbols[indices[j-1]]) < level) {
                            line(CGPoint(x:x,y:top),CGPoint(x:x+(j == indices.count-1 ? -8 : 8),y:top),3.3)
                        }
                    }
                }
            }
            let tuplets = Dictionary(grouping:symbols.indices.filter { symbols[$0].group > 0 },by:{ symbols[$0].group })
            for indices in tuplets.values {
                guard let a = indices.min(), let b = indices.max() else { continue }
                let left = points[a], right = points[b]+6, mid = (left+right)/2
                text(String(symbols[a].actual),mid,5,11)
                if right-left > 20 {
                    line(CGPoint(x:left,y:9),CGPoint(x:mid-7,y:9),0.8)
                    line(CGPoint(x:mid+7,y:9),CGPoint(x:right,y:9),0.8)
                    line(CGPoint(x:left,y:9),CGPoint(x:left,y:13),0.8)
                    line(CGPoint(x:right,y:9),CGPoint(x:right,y:13),0.8)
                }
            }
        }.accessibilityElement(children:.ignore).accessibilityLabel("리듬 악보, \(symbols.count)개 음표 또는 쉼표")
    }
}
