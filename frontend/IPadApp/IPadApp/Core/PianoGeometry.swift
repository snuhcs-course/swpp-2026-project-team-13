import Foundation

struct PianoKeyGeometry {
    let midi: Int
    let x: Double
    let width: Double
    let height: Double
    let black: Bool
}
struct PianoGeometry {
    let keys: [PianoKeyGeometry]
    static func isBlack(_ midi: Int) -> Bool { [1,3,6,8,10].contains(midi % 12) }
    init(range: ClosedRange<Int>) {
        let whites = range.filter { !Self.isBlack($0) }
        let width = 1/Double(max(1,whites.count))
        var keys: [PianoKeyGeometry] = []
        for (index,midi) in whites.enumerated() {
            keys.append(PianoKeyGeometry(midi:midi,x:Double(index)*width,width:width,height:1,black:false))
        }
        for midi in range where Self.isBlack(midi) {
            let before = whites.filter { $0 < midi }.count
            keys.append(PianoKeyGeometry(midi:midi,x:Double(before)*width-width*0.31,width:width*0.62,height:0.62,black:true))
        }
        self.keys = keys
    }
    func key(x: Double, y: Double) -> Int? {
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        // Black keys win in the overlapping upper region, white keys below it.
        return keys.reversed().first { x >= $0.x && x < $0.x+$0.width && y <= $0.height }?.midi
    }
}
