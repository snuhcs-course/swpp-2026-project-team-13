import SwiftUI

struct RhythmBarFrames: PreferenceKey {
    static let defaultValue: [Int:CGRect] = [:]
    static func reduce(value: inout [Int:CGRect], nextValue: () -> [Int:CGRect]) { value.merge(nextValue(),uniquingKeysWith:{ _, b in b }) }
}

struct RhythmStaffBar: View {
    let round: RhythmRound; let bar: Int; let board: RhythmBoard
    let tiles: [String:RhythmTile]; let scale: CGFloat
    var hints: [RhythmTime] = []; var selected: RhythmPlacement? = nil
    var splitTie = true; var editable = false
    var tapPiece: (RhythmPlacement) -> Void = { _ in }
    var tapTie: (RhythmTime) -> Void = { _ in }
    private var layout: RhythmBarLayout { RhythmBarLayout(round:round,bar:bar,board:board,tiles:tiles,drawings:RhythmInk.drawings) }
    private var top: CGFloat { 16 }
    private var baseline: CGFloat { top+58*scale }
    private func point(_ x: Double) -> CGFloat { CGFloat(x)*scale }
    private func endpoints(_ time: RhythmTime) -> (CGFloat,CGFloat)? {
        guard let a = board.placements.first(where:{ board.end($0,tiles:tiles) == time }),
              let b = board.placements.first(where:{ $0.start == time }),
              let left = layout.lastHead(a), let right = layout.firstHead(b) else { return nil }
        return (point(left)+5*scale,point(right)-5*scale)
    }
    var body: some View {
        ZStack(alignment:.topLeading) {
            Canvas { context,size in
                RhythmInk.staff(in:context,from:0,to:size.width,baseline:baseline,scale:scale)
                if bar == 0 {
                    let font = Font.system(size:22*scale,weight:.bold,design:.serif)
                    context.draw(Text(String(round.meter.numerator)).font(font).foregroundColor(SolfegeTheme.ink),at:CGPoint(x:30*scale,y:baseline-8*scale))
                    context.draw(Text(String(round.meter.denominator)).font(font).foregroundColor(SolfegeTheme.ink),at:CGPoint(x:30*scale,y:baseline+8*scale))
                }
                for x in [CGFloat(0.5),size.width-0.5] {
                    var line = Path(); line.move(to:CGPoint(x:x,y:baseline-16*scale)); line.addLine(to:CGPoint(x:x,y:baseline+16*scale))
                    context.stroke(line,with:.color(SolfegeTheme.ink),lineWidth:0.9)
                }
                for part in layout.segments {
                    if let p = part.placement, let drawing = RhythmInk.drawings[p.tileId] {
                        RhythmInk.draw(drawing,in:context,at:CGPoint(x:point(part.x),y:top),scale:scale)
                    }
                }
                for time in board.ties {
                    if let ends = endpoints(time) {
                        context.fill(RhythmInk.tie(from:CGPoint(x:ends.0,y:baseline+7*scale),to:CGPoint(x:ends.1,y:baseline+7*scale)),with:.color(SolfegeTheme.ink))
                    }
                }
                if splitTie {
                    let beginning = round.measureDuration*bar, end = beginning+round.measureDuration
                    if bar == 1, board.ties.contains(beginning), let first = board.placements.first(where:{ $0.start == beginning }), let head = layout.firstHead(first) {
                        context.fill(RhythmInk.brokenTie(from:CGPoint(x:2,y:baseline+7*scale),to:CGPoint(x:point(head)-5*scale,y:baseline+7*scale),continuesRight:false),with:.color(SolfegeTheme.ink))
                    }
                    if bar == 0, board.ties.contains(end), let last = board.placements.first(where:{ board.end($0,tiles:tiles) == end }), let head = layout.lastHead(last) {
                        context.fill(RhythmInk.brokenTie(from:CGPoint(x:point(head)+5*scale,y:baseline+7*scale),to:CGPoint(x:size.width-2,y:baseline+7*scale),continuesRight:true),with:.color(SolfegeTheme.ink))
                    }
                }
            }.allowsHitTesting(false)
            ForEach(Array(layout.slots.enumerated()),id:\.offset) { _,slot in
                if slot.empty {
                    let highlighted = hints.contains { slot.start <= $0 && $0 < slot.start+slot.duration }
                    RoundedRectangle(cornerRadius:5)
                        .fill(highlighted ? Color.orange.opacity(0.1) : Color.gray.opacity(0.025))
                        .overlay(RoundedRectangle(cornerRadius:5).stroke(highlighted ? Color.orange : Color.gray.opacity(0.35),style:StrokeStyle(lineWidth:1,dash:[4,3])))
                        .overlay(alignment:.bottom) { Text(slot.label(pulse:round.pulse)).font(.system(size:10)).foregroundStyle(.secondary).padding(.bottom,3) }
                        .frame(width:max(8,point(slot.width)-4),height:82*scale)
                        .offset(x:point(slot.x)+2,y:top+12*scale).allowsHitTesting(false)
                }
            }
            ForEach(layout.segments.compactMap(\.placement)) { placement in
                if let part = layout.segments.first(where: { $0.placement == placement }) {
                    let hinted = hints.contains { placement.start <= $0 && $0 < placement.start+part.duration }
                    Button { tapPiece(placement) } label: {
                        RoundedRectangle(cornerRadius:8).fill(selected == placement ? Color.blue.opacity(0.1) : hinted ? Color.red.opacity(0.08) : .clear)
                            .overlay(RoundedRectangle(cornerRadius:8).stroke(selected == placement ? Color.blue.opacity(0.6) : .clear))
                            .frame(width:point(part.width),height:76*scale)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).offset(x:point(part.x),y:top+12*scale).disabled(!editable)
                        .accessibilityLabel("\(bar+1)마디 리듬 조각")
                        .accessibilityIdentifier("rhythm-piece-\(bar)-\(placement.start.description)")
                }
            }
            ForEach(board.ties.filter { endpoints($0) != nil },id:\.self) { time in
                if let ends = endpoints(time) {
                    Button { tapTie(time) } label: { Color.clear.frame(width:max(44,ends.1-ends.0),height:30).contentShape(Rectangle()) }
                        .offset(x:(ends.0+ends.1)/2-max(44,ends.1-ends.0)/2,y:baseline+7*scale)
                        .disabled(!editable).accessibilityLabel("붙임줄 삭제")
                }
            }
        }.frame(width:point(layout.width),height:128)
            .background(GeometryReader { geo in Color.clear.preference(key:RhythmBarFrames.self,value:editable ? [bar:geo.frame(in:.named("rhythm-puzzle"))] : [:]) })
    }
}

struct RhythmPuzzleBoardView: View {
    @ObservedObject var game: RhythmPuzzleModel
    let round: RhythmRound; var compact = false
    var body: some View {
        RhythmStaffSystem(round:round,board:game.board,tiles:game.tiles,compact:compact,hints:game.hintPositions+(game.missingPosition.map { [$0] } ?? []),selected:game.selectedTiePiece,editable:game.canEdit,tapPiece:game.tapPiece,tapTie:game.toggleTie,connect:game.connect)
    }
}

struct RhythmStaffSystem: View {
    let round: RhythmRound; let board: RhythmBoard; let tiles: [String:RhythmTile]
    var compact = false; var hints: [RhythmTime] = []; var selected: RhythmPlacement? = nil; var editable = false
    var tapPiece: (RhythmPlacement) -> Void = { _ in }; var tapTie: (RhythmTime) -> Void = { _ in }
    var connect: (RhythmPlacement,RhythmPlacement) -> Void = { _,_ in }
    var body: some View {
        GeometryReader { geo in
            let a = RhythmBarLayout(round:round,bar:0,board:board,tiles:tiles,drawings:RhythmInk.drawings)
            let b = RhythmBarLayout(round:round,bar:1,board:board,tiles:tiles,drawings:RhythmInk.drawings)
            let scale = min(CGFloat(1.2),max(0.7,geo.size.width/CGFloat(a.width+b.width)))
            ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:0) { staff(0,scale:scale,split:false); staff(1,scale:scale,split:false) }
                        .overlay(alignment:.topLeading) {
                            Canvas { context,_ in
                                let boundary = round.measureDuration
                                guard board.ties.contains(boundary),
                                      let left = board.placements.first(where:{ board.end($0,tiles:tiles) == boundary }),
                                      let right = board.placements.first(where:{ $0.start == boundary }),
                                      let x = a.lastHead(left), let y = b.firstHead(right) else { return }
                                let start = CGPoint(x:CGFloat(x+5)*scale,y:16+65*scale)
                                let end = CGPoint(x:CGFloat(a.width+y-5)*scale,y:16+65*scale)
                                context.fill(RhythmInk.tie(from:start,to:end),with:.color(SolfegeTheme.ink))
                            }.allowsHitTesting(false)
                        }
                        .overlay {
                            if editable {
                                MiniGameTouchSurface { start,end,tap in
                                    func part(at point: CGPoint) -> RhythmPlacement? {
                                        guard point.y >= 24, point.y < 16+100*scale else { return nil }
                                        let x = Double(point.x/scale)
                                        let layout = x < a.width ? a : b
                                        let local = x < a.width ? x : x-a.width
                                        return layout.segments.first { $0.x <= local && local <= $0.x+$0.width }?.placement
                                    }
                                    if tap {
                                        // A narrow curved hit region separates ties from notehead boxes.
                                        for t in board.ties {
                                            guard let left = board.placements.first(where:{board.end($0,tiles:tiles) == t}), let right = board.placements.first(where:{$0.start == t}) else { continue }
                                            let leftLayout = left.start < round.measureDuration ? a : b
                                            let rightLayout = right.start < round.measureDuration ? a : b
                                            guard let lx = leftLayout.lastHead(left), let rx = rightLayout.firstHead(right) else { continue }
                                            let x1 = CGFloat(lx+5+(left.start < round.measureDuration ? 0 : a.width))*scale
                                            let x2 = CGFloat(rx-5+(right.start < round.measureDuration ? 0 : a.width))*scale
                                            let path = RhythmInk.tie(from:CGPoint(x:x1,y:16+65*scale),to:CGPoint(x:x2,y:16+65*scale))
                                            if path.strokedPath(StrokeStyle(lineWidth:16)).contains(end) { tapTie(t); return }
                                        }
                                        if let p = part(at:end) { tapPiece(p) }
                                    } else if let first = part(at:start), let second = part(at:end), first != second { connect(first,second) }
                                }
                                .accessibilityHidden(true)
                            }
                        }
                        .frame(width:CGFloat(a.width+b.width)*scale)
            }.frame(maxWidth:.infinity,alignment:.center)
        }.frame(height:140)
    }
    private func staff(_ bar: Int, scale: CGFloat, split: Bool) -> some View {
        RhythmStaffBar(round:round,bar:bar,board:board,tiles:tiles,scale:scale,hints:hints,selected:selected,splitTie:split,editable:editable,tapPiece:tapPiece,tapTie:tapTie)
    }
}

struct RhythmReferenceView: View {
    let round: RhythmRound; let tiles: [String:RhythmTile]
    var compact = false
    var body: some View { RhythmStaffSystem(round:round,board:RhythmBoard(placements:round.solution,ties:round.solutionTies),tiles:tiles,compact:compact) }
}
