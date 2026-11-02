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
                    context.draw(Text(String(round.meter.numerator)).font(font).foregroundColor(SORITheme.ink),at:CGPoint(x:30*scale,y:baseline-8*scale))
                    context.draw(Text(String(round.meter.denominator)).font(font).foregroundColor(SORITheme.ink),at:CGPoint(x:30*scale,y:baseline+8*scale))
                }
                for x in [CGFloat(0.5),size.width-0.5] {
                    var line = Path(); line.move(to:CGPoint(x:x,y:baseline-16*scale)); line.addLine(to:CGPoint(x:x,y:baseline+16*scale))
                    context.stroke(line,with:.color(SORITheme.ink),lineWidth:0.9)
                }
                for part in layout.segments {
                    if let p = part.placement, let drawing = RhythmInk.drawings[p.tileId] {
                        RhythmInk.draw(drawing,in:context,at:CGPoint(x:point(part.x),y:top),scale:scale)
                    } else {
                        let x = point(part.x+part.width/2)
                        context.fill(Path(ellipseIn:CGRect(x:x-1.5,y:baseline+25*scale,width:3,height:3)),with:.color(.gray.opacity(0.25)))
                    }
                }
                for time in board.ties {
                    if let ends = endpoints(time) {
                        context.fill(RhythmInk.tie(from:CGPoint(x:ends.0,y:baseline+7*scale),to:CGPoint(x:ends.1,y:baseline+7*scale)),with:.color(SORITheme.ink))
                    }
                }
                if splitTie {
                    let beginning = round.measureDuration*bar, end = beginning+round.measureDuration
                    if bar == 1, board.ties.contains(beginning), let first = board.placements.first(where:{ $0.start == beginning }), let head = layout.firstHead(first) {
                        context.fill(RhythmInk.brokenTie(from:CGPoint(x:2,y:baseline+7*scale),to:CGPoint(x:point(head)-5*scale,y:baseline+7*scale),continuesRight:false),with:.color(SORITheme.ink))
                    }
                    if bar == 0, board.ties.contains(end), let last = board.placements.first(where:{ board.end($0,tiles:tiles) == end }), let head = layout.lastHead(last) {
                        context.fill(RhythmInk.brokenTie(from:CGPoint(x:point(head)+5*scale,y:baseline+7*scale),to:CGPoint(x:size.width-2,y:baseline+7*scale),continuesRight:true),with:.color(SORITheme.ink))
                    }
                }
            }.allowsHitTesting(false)
            ForEach(layout.segments.compactMap(\.placement)) { placement in
                if let part = layout.segments.first(where: { $0.placement == placement }) {
                    let hinted = hints.contains { placement.start <= $0 && $0 < placement.start+part.duration }
                    Button { tapPiece(placement) } label: {
                        RoundedRectangle(cornerRadius:8).fill(selected == placement ? Color.blue.opacity(0.1) : hinted ? Color.red.opacity(0.08) : .clear)
                            .overlay(RoundedRectangle(cornerRadius:8).stroke(selected == placement ? Color.blue.opacity(0.6) : .clear))
                            .frame(width:point(part.width),height:76*scale)
                    }.buttonStyle(.plain).offset(x:point(part.x),y:top+12*scale).disabled(!editable)
                        .accessibilityLabel("\(bar+1)마디 리듬 조각")
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
            .background(GeometryReader { geo in Color.clear.preference(key:RhythmBarFrames.self,value:[bar:geo.frame(in:.named("rhythm-puzzle"))]) })
            .simultaneousGesture(DragGesture(minimumDistance:14).onEnded { value in
                guard editable, value.startLocation.y >= baseline-4, value.location.y >= baseline-4 else { return }
                for t in board.validBoundaries(tiles:tiles) {
                    guard let ends = endpoints(t) else { continue }
                    let from = value.startLocation.x, to = value.location.x
                    if (abs(from-ends.0) < 25 && abs(to-ends.1) < 25) || (abs(from-ends.1) < 25 && abs(to-ends.0) < 25) { tapTie(t); return }
                }
            })
    }
}

struct RhythmPuzzleBoardView: View {
    @ObservedObject var game: RhythmPuzzleModel
    let round: RhythmRound; var compact = false
    var body: some View {
        RhythmStaffSystem(round:round,board:game.board,tiles:game.tiles,compact:compact,hints:game.hintPositions,selected:game.selectedTiePiece,editable:game.canEdit,tapPiece:game.tapPiece,tapTie:game.toggleTie)
    }
}

struct RhythmStaffSystem: View {
    let round: RhythmRound; let board: RhythmBoard; let tiles: [String:RhythmTile]
    var compact = false; var hints: [RhythmTime] = []; var selected: RhythmPlacement? = nil; var editable = false
    var tapPiece: (RhythmPlacement) -> Void = { _ in }; var tapTie: (RhythmTime) -> Void = { _ in }
    var body: some View {
        GeometryReader { geo in
            let a = RhythmBarLayout(round:round,bar:0,board:board,tiles:tiles,drawings:RhythmInk.drawings)
            let b = RhythmBarLayout(round:round,bar:1,board:board,tiles:tiles,drawings:RhythmInk.drawings)
            let scale = min(CGFloat(1.2),geo.size.width/CGFloat(compact ? max(a.width,b.width) : a.width+b.width+12))
            Group {
                if compact { VStack(spacing:0) { staff(0,scale:scale,split:true); staff(1,scale:scale,split:true) } }
                else {
                    HStack(spacing:12*scale) { staff(0,scale:scale,split:false); staff(1,scale:scale,split:false) }
                        .overlay(alignment:.topLeading) {
                            Canvas { context,_ in
                                let boundary = round.measureDuration
                                guard board.ties.contains(boundary),
                                      let left = board.placements.first(where:{ board.end($0,tiles:tiles) == boundary }),
                                      let right = board.placements.first(where:{ $0.start == boundary }),
                                      let x = a.lastHead(left), let y = b.firstHead(right) else { return }
                                let start = CGPoint(x:CGFloat(x+5)*scale,y:16+65*scale)
                                let end = CGPoint(x:CGFloat(a.width+12+y-5)*scale,y:16+65*scale)
                                context.fill(RhythmInk.tie(from:start,to:end),with:.color(SORITheme.ink))
                            }.allowsHitTesting(false)
                        }
                }
            }.frame(maxWidth:.infinity,alignment:.center)
        }.frame(height:compact ? 256 : 128)
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
