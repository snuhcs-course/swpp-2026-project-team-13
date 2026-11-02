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

// Engraved widths are intrinsic. Empty regions reserve modest space per pulse;
// neither note spacing nor noteheads expand to fill a wide iPad display.
struct RhythmBarLayout {
    struct Segment {
        let placement: RhythmPlacement?; let start: RhythmTime; let duration: RhythmTime
        let x: Double; let width: Double; let symbolXs: [Double]
    }
    let segments: [Segment]
    let width: Double
    let beginning: RhythmTime
    let round: RhythmRound
    init(round: RhythmRound, bar: Int, board: RhythmBoard, tiles: [String:RhythmTile], drawings: [String:RhythmDrawing]) {
        self.round = round; let beginning = round.measureDuration*bar; self.beginning = beginning
        var parts: [Segment] = [], cursor = beginning, x = bar == 0 ? 62.0 : 18.0
        let end = beginning+round.measureDuration
        let placed = board.placements.filter { beginning <= $0.start && $0.start < end }.sorted { $0.start < $1.start }
        func gap(until limit: RhythmTime) {
            while cursor < limit {
                let next = min(limit,beginning+round.pulse*((((cursor-beginning)/round.pulse).floor)+1))
                let duration = next-cursor, w = max(24,44*(duration/round.pulse).value)
                parts.append(Segment(placement:nil,start:cursor,duration:duration,x:x,width:w,symbolXs:[]))
                x += w; cursor = next
            }
        }
        for p in placed {
            gap(until:p.start)
            guard let tile = tiles[p.tileId] else { continue }
            let drawing = drawings[p.tileId]
            let spacing = min(90,36*sqrt((tile.duration/round.pulse).value))
            let w = max(spacing,drawing?.width ?? 44)
            parts.append(Segment(placement:p,start:p.start,duration:tile.duration,x:x,width:w,symbolXs:drawing?.symbolXs ?? []))
            x += w+4; cursor = p.start+tile.duration
        }
        gap(until:end)
        segments = parts; width = x+16
    }
    func x(at time: RhythmTime) -> Double {
        if time >= beginning+round.measureDuration { return width-12 }
        guard let part = segments.first(where: { $0.start <= time && time < $0.start+$0.duration }) else { return 18 }
        return part.x+(time-part.start).value/part.duration.value*part.width
    }
    func nearestTime(to x: Double, tiles: [String:RhythmTile]) -> RhythmTime {
        if let part = segments.first(where: { $0.x <= x && x <= $0.x+$0.width }), part.placement != nil { return part.start }
        var anchors = Set(segments.map(\.start))
        for i in 0..<round.pulsesPerMeasure {
            for divisor in [1,2,3,4] {
                for j in 0..<divisor { anchors.insert(beginning+round.pulse*i+(round.pulse/RhythmTime(divisor))*j) }
            }
        }
        return anchors.min { abs(self.x(at:$0)-x) < abs(self.x(at:$1)-x) } ?? beginning
    }
    func firstHead(_ placement: RhythmPlacement) -> Double? {
        guard let p = segments.first(where: { $0.placement == placement }), let head = p.symbolXs.first else { return nil }
        return p.x+head
    }
    func lastHead(_ placement: RhythmPlacement) -> Double? {
        guard let p = segments.first(where: { $0.placement == placement }), let head = p.symbolXs.last else { return nil }
        return p.x+head
    }
}
