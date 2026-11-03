import SwiftUI

enum RhythmInk {
    static let drawings: [String:RhythmDrawing] = {
        let engraving: RhythmEngraving? = try? Bundled.decode("rhythm-engraving-v3")
        return engraving?.tiles ?? [:]
    }()
    static func path(_ commands: [RhythmVectorCommand]) -> Path {
        var result = Path()
        for command in commands {
            let v = command.values
            switch command.op {
            case "M" where v.count == 2: result.move(to:CGPoint(x:v[0],y:v[1]))
            case "L" where v.count == 2: result.addLine(to:CGPoint(x:v[0],y:v[1]))
            case "C" where v.count == 6:
                result.addCurve(to:CGPoint(x:v[4],y:v[5]),control1:CGPoint(x:v[0],y:v[1]),control2:CGPoint(x:v[2],y:v[3]))
            case "Q" where v.count == 4: result.addQuadCurve(to:CGPoint(x:v[2],y:v[3]),control:CGPoint(x:v[0],y:v[1]))
            case "Z": result.closeSubpath()
            default: break
            }
        }
        return result
    }
    static func draw(_ drawing: RhythmDrawing, in context: GraphicsContext, at origin: CGPoint = .zero, scale: CGFloat = 1) {
        var context = context; context.translateBy(x:origin.x,y:origin.y); context.scaleBy(x:scale,y:scale)
        for item in drawing.paths {
            let shape = path(item.commands)
            if item.fill { context.fill(shape,with:.color(SORITheme.ink)) }
            if item.stroke > 0 { context.stroke(shape,with:.color(SORITheme.ink),lineWidth:CGFloat(item.stroke)) }
        }
    }
    // Tapered engraving tie: pointed tips and a slightly heavier centre.
    static func tie(from a: CGPoint, to b: CGPoint) -> Path {
        let span = max(4,b.x-a.x), depth = min(18,max(6,sqrt(span)*1.15))
        let weight = min(2.3,max(1.3,span/85))
        var path = Path(); path.move(to:a)
        path.addCurve(to:b,control1:CGPoint(x:a.x+span*0.22,y:a.y+depth),control2:CGPoint(x:b.x-span*0.22,y:b.y+depth))
        path.addCurve(to:a,control1:CGPoint(x:b.x-span*0.22,y:b.y+depth-weight),control2:CGPoint(x:a.x+span*0.22,y:a.y+depth-weight))
        path.closeSubpath(); return path
    }
    static func brokenTie(from a: CGPoint, to b: CGPoint, continuesRight: Bool) -> Path {
        let span = max(4,b.x-a.x), depth = min(12,max(5,sqrt(span)))
        let thickness: CGFloat = 1.6
        var path = Path()
        if continuesRight {
            path.move(to:a)
            path.addCurve(to:CGPoint(x:b.x,y:b.y+depth),control1:CGPoint(x:a.x+span*0.25,y:a.y+depth),control2:CGPoint(x:b.x-span*0.2,y:b.y+depth))
            path.addLine(to:CGPoint(x:b.x,y:b.y+depth-thickness))
            path.addCurve(to:a,control1:CGPoint(x:b.x-span*0.2,y:b.y+depth-thickness),control2:CGPoint(x:a.x+span*0.25,y:a.y+depth-thickness))
        } else {
            path.move(to:CGPoint(x:a.x,y:a.y+depth))
            path.addCurve(to:b,control1:CGPoint(x:a.x+span*0.2,y:a.y+depth),control2:CGPoint(x:b.x-span*0.25,y:b.y+depth))
            path.addCurve(to:CGPoint(x:a.x,y:a.y+depth-thickness),control1:CGPoint(x:b.x-span*0.25,y:b.y+depth-thickness),control2:CGPoint(x:a.x+span*0.2,y:a.y+depth-thickness))
        }
        path.closeSubpath(); return path
    }
    static func staff(in context: GraphicsContext, from start: CGFloat, to end: CGFloat, baseline: CGFloat, scale: CGFloat = 1) {
        for i in -2...2 {
            let y = baseline+CGFloat(i)*8*scale
            var line = Path(); line.move(to:CGPoint(x:start,y:y)); line.addLine(to:CGPoint(x:end,y:y))
            context.stroke(line,with:.color(SORITheme.ink.opacity(0.38)),lineWidth:0.65*scale)
        }
    }
}

struct RhythmNotationView: View {
    let tile: RhythmTile
    var body: some View {
        Canvas { context,size in
            guard let drawing = RhythmInk.drawings[tile.id] else { return }
            let scale = min(1.12,(size.width-16)/CGFloat(drawing.width))
            let x = (size.width-CGFloat(drawing.width)*scale)/2
            let y = (size.height-CGFloat(drawing.height)*scale)/2
            RhythmInk.staff(in:context,from:8,to:size.width-8,baseline:y+58*scale,scale:scale)
            RhythmInk.draw(drawing,in:context,at:CGPoint(x:x,y:y),scale:scale)
        }.accessibilityElement(children:.ignore).accessibilityLabel("리듬 악보, \(tile.symbols.count)개 음표 또는 쉼표")
    }
}

// Two quarter notes and an engraving tie, matching the supplied reference.
struct RhythmTieIcon: View {
    var color: Color = .primary
    var body: some View {
        Canvas { context,size in
            var context = context
            context.scaleBy(x:size.width/32,y:size.height/32)
            for x in [CGFloat(7),CGFloat(25)] {
                var head = Path()
                head.move(to:CGPoint(x:x-4,y:22))
                head.addCurve(to:CGPoint(x:x+4,y:20),control1:CGPoint(x:x-4,y:18),control2:CGPoint(x:x+4,y:16))
                head.addCurve(to:CGPoint(x:x-4,y:22),control1:CGPoint(x:x+4,y:24),control2:CGPoint(x:x-4,y:26))
                context.fill(head,with:.color(color))
                var stem = Path(); stem.move(to:CGPoint(x:x+3.5,y:20)); stem.addLine(to:CGPoint(x:x+3.5,y:5))
                context.stroke(stem,with:.color(color),lineWidth:0.9)
            }
            context.fill(RhythmInk.tie(from:CGPoint(x:8,y:25),to:CGPoint(x:24,y:25)),with:.color(color))
        }.accessibilityHidden(true)
    }
}
