import Foundation

struct RhythmVectorCommand: Decodable { let op: String; let values: [Double] }
struct RhythmVectorPath: Decodable { let commands: [RhythmVectorCommand]; let fill: Bool; let stroke: Double }
struct RhythmDrawing: Decodable {
    let width: Double; let height: Double; let baseline: Double
    let symbolXs: [Double]; let paths: [RhythmVectorPath]
}
struct RhythmEngraving: Decodable {
    let renderer: String; let catalogSha256: String; let tiles: [String:RhythmDrawing]
}

// Every position belongs to musical time, including while the board is empty.
struct RhythmBarLayout {
    struct Segment {
        let placement: RhythmPlacement?; let start: RhythmTime; let duration: RhythmTime
        let x: Double; let width: Double; let symbolXs: [Double]
        var drawingScale = 1.0
        var drawingInset = 0.0
    }
    let segments: [Segment]
    let width: Double
    let beginning: RhythmTime
    let round: RhythmRound
    init(round: RhythmRound, bar: Int, board: RhythmBoard, tiles: [String:RhythmTile], drawings: [String:RhythmDrawing]) {
        self.round = round; let beginning = round.measureDuration*bar; self.beginning = beginning
        var parts: [Segment] = [], cursor = beginning
        let leading = bar == 0 ? 62.0 : 18.0
        let pulseWidth = 100.0
        func position(_ t: RhythmTime) -> Double { leading+((t-beginning)/round.pulse).value*pulseWidth }
        let end = beginning+round.measureDuration
        let placed = board.placements.filter { beginning <= $0.start && $0.start < end }.sorted { $0.start < $1.start }
        func gap(until limit: RhythmTime) {
            while cursor < limit {
                let next = min(limit,beginning+round.pulse*((((cursor-beginning)/round.pulse).floor)+1))
                let duration = next-cursor, w = pulseWidth*(duration/round.pulse).value
                parts.append(Segment(placement:nil,start:cursor,duration:duration,x:position(cursor),width:w,symbolXs:[]))
                cursor = next
            }
        }
        for p in placed {
            gap(until:p.start)
            guard let tile = tiles[p.tileId] else { continue }
            let drawing = drawings[p.tileId]
            let w = pulseWidth*(tile.duration/round.pulse).value
            let glyphScale = min(1,max(0.05,(w-8)/(drawing?.width ?? 44)))
            let inset = max(4,(w-(drawing?.width ?? 44)*glyphScale)/2)
            let heads = (drawing?.symbolXs ?? []).map { inset+$0*glyphScale }
            parts.append(Segment(placement:p,start:p.start,duration:tile.duration,x:position(p.start),width:w,
                                 symbolXs:heads,drawingScale:glyphScale,drawingInset:inset))
            cursor = p.start+tile.duration
        }
        gap(until:end)
        segments = parts; width = position(end)+16
    }
    func x(at time: RhythmTime) -> Double {
        if time >= beginning+round.measureDuration { return width-16 }
        guard let part = segments.first(where: { $0.start <= time && time < $0.start+$0.duration }) else { return 18 }
        return part.x+(time-part.start).value/part.duration.value*part.width
    }
    func nearestTime(to x: Double, tiles: [String:RhythmTile]) -> RhythmTime {
        // The whole visible slot belongs to its start. The centre of an empty
        // beat is still that beat, never a newly invented half/third of a beat.
        // Partial slots after a dotted note retain their exact fractional start.
        if let part = segments.first(where: { $0.x <= x && x < $0.x+$0.width }) { return part.start }
        func distance(_ part: Segment) -> Double { max(0,max(part.x-x,x-(part.x+part.width))) }
        return segments.min {
            let a = distance($0), b = distance($1)
            return a == b ? $0.start < $1.start : a < b
        }?.start ?? beginning
    }
    func firstHead(_ placement: RhythmPlacement) -> Double? {
        guard let p = segments.first(where: { $0.placement == placement }), let head = p.symbolXs.first else { return nil }
        return p.x+head
    }
    func lastHead(_ placement: RhythmPlacement) -> Double? {
        guard let p = segments.first(where: { $0.placement == placement }), let head = p.symbolXs.last else { return nil }
        return p.x+head
    }
    struct Slot {
        let start: RhythmTime; let duration: RhythmTime; let x: Double; let width: Double; let empty: Bool
        func label(pulse: RhythmTime) -> String {
            let fraction = duration/pulse
            return fraction == RhythmTime(1) ? "" : fraction == RhythmTime(1,2) ? "½박" : fraction.description+"박"
        }
    }
    var slots: [Slot] {
        segments.flatMap { part -> [Slot] in
            var result: [Slot] = [], time = part.start
            while time < part.start+part.duration {
                let boundary = beginning+round.pulse*((((time-beginning)/round.pulse).floor)+1)
                let stop = min(boundary,part.start+part.duration)
                let left = part.x+(time-part.start).value/part.duration.value*part.width
                let w = (stop-time).value/part.duration.value*part.width
                result.append(Slot(start:time,duration:stop-time,x:left,width:w,empty:part.placement == nil))
                time = stop
            }
            return result
        }
    }
}

enum MiniGameGesture {
    // Screen points, independent of score scaling. Pencil taps include normal tip drift.
    static func isTap(maximumDistance: Double, pencil: Bool) -> Bool { maximumDistance <= (pencil ? 16 : 10) }
}
