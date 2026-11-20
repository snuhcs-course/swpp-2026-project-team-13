import Foundation

// Coordinates accompany the actual engraved image, including natural-width exceptions.
struct PracticeReviewGeometry: Codable, Equatable {
    var logicalWidth: Int
    var logicalHeight: Int
    var systems: [SheetSystem]
    init(logicalWidth: Int, logicalHeight: Int, systems: [SheetSystem]) {
        self.logicalWidth = logicalWidth; self.logicalHeight = logicalHeight; self.systems = systems
    }
    init(sheet: SheetLayout) {
        self.init(logicalWidth:sheet.logicalWidth,logicalHeight:sheet.logicalHeight,systems:sheet.systems)
    }
    var isValid: Bool {
        guard (1...4096).contains(logicalWidth), (1...2048).contains(logicalHeight), systems.count == 2 else { return false }
        return systems.enumerated().allSatisfy { index, system in
            system.index == index+1 && system.firstMeasure == index*4+1 && system.lastMeasure == index*4+4 &&
            system.staffLineY.count == 5 && system.barlineX.count == 5 &&
            system.staffLineY.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= Double(logicalHeight) } &&
            system.barlineX.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= Double(logicalWidth) } &&
            zip(system.barlineX,system.barlineX.dropFirst()).allSatisfy { $0 < $1 } &&
            zip(system.staffLineY,system.staffLineY.dropFirst()).allSatisfy { $0 < $1 }
        }
    }
    var strips: [AnswerSystemCrop] {
        guard isValid else { return [] }
        return systems.enumerated().compactMap { index, s in
            guard let first = s.staffLineY.first, let last = s.staffLineY.last else { return nil }
            // Split the inter-staff gap once; neither handwriting nor glyphs are duplicated.
            let previous = index > 0 ? (systems[index-1].staffLineY.last!+first)/2 : 0
            let next = index+1 < systems.count ? (last+systems[index+1].staffLineY.first!)/2 : Double(logicalHeight)
            let top = max(previous,first-80), bottom = min(next,last+80)
            return AnswerSystemCrop(id:s.index,bounds:BBox(x:0,y:top/Double(logicalHeight),width:1,height:(bottom-top)/Double(logicalHeight)))
        }
    }
}

enum PracticeReviewPopover {
    // The source rectangle and output use the same view-local coordinates.
    static func frame(anchor: BBox, width: Double, height: Double, containerWidth: Double, containerHeight: Double) -> BBox {
        let margin = 12.0, gap = 10.0
        let w = max(0,min(width,containerWidth-2*margin)), h = max(0,min(height,containerHeight-2*margin))
        let right = anchor.x+anchor.width+gap
        let preferred = right+w <= containerWidth-margin ? right : anchor.x-gap-w
        return BBox(x:max(margin,min(preferred,containerWidth-margin-w)),
                    y:max(margin,min(anchor.y+anchor.height/2-h/2,containerHeight-margin-h)),width:w,height:h)
    }
}

struct PracticeReviewClip {
    var events: [MusicEvent]
    var ticks: Int
    var bpm: Double
    static func make(score: MusicScore, measure: Int?, bpm: Double) throws -> PracticeReviewClip {
        try make(score:score,from:measure ?? 1,through:measure ?? score.measures,bpm:bpm)
    }
    static func make(score: MusicScore, from: Int, through to: Int, bpm: Double) throws -> PracticeReviewClip {
        guard bpm.isFinite, (20...400).contains(bpm) else { throw SolfegeError.invalidScore("재생 속도를 확인해 주세요.") }
        return PracticeReviewClip(events:try score.segment(from:from,through:to),ticks:(to-from+1)*score.ticksPerMeasure,bpm:bpm)
    }
}

struct PracticeReviewRange: Hashable {
    var from: Int
    var through: Int
    var measures: ClosedRange<Int> { from...through }
    var label: String { from == through ? "\(from)마디" : "\(from)–\(through)마디" }
    static let full = PracticeReviewRange(from:1,through:8)
}

struct PracticeReviewSelection {
    var range = PracticeReviewRange.full
    var selecting = false
    private(set) var anchor: Int?
    private var previousRange: PracticeReviewRange?
    mutating func begin() { previousRange = range; selecting = true; anchor = nil }
    mutating func cancel() { range = previousRange ?? range; previousRange = nil; selecting = false; anchor = nil }
    mutating func all() { range = .full; previousRange = nil; selecting = false; anchor = nil }
    // Returns true only for the normal one-tap immediate playback action.
    mutating func tap(_ measure: Int) -> Bool {
        guard (1...8).contains(measure) else { return false }
        guard selecting else { range = PracticeReviewRange(from:measure,through:measure); return true }
        if let anchor {
            range = PracticeReviewRange(from:min(anchor,measure),through:max(anchor,measure))
            self.anchor = nil; previousRange = nil; selecting = false
        } else { anchor = measure; range = PracticeReviewRange(from:measure,through:measure) }
        return false
    }
}

// One sequence is prepared per score/tempo. Each contiguous range has its own
// clipped notes and a silent lead, so ties and leading rests survive seeking.
// Selecting another bar only seeks; it never reloads MIDI into a running engine.
struct PracticeReviewSequence {
    struct Slice {
        var range: PracticeReviewRange
        var start: Int
        var musicStart: Int
        var end: Int
    }
    var events: [MusicEvent] = []
    var slices: [Slice] = []
    var ticks = 0
    init(score: MusicScore, bpm: Double) throws {
        guard score.measures == 8, bpm.isFinite, (20...400).contains(bpm) else { throw SolfegeError.invalidScore("재생할 문제를 확인해 주세요.") }
        let lead = max(1,Int((bpm*480/60*0.12).rounded()))
        let gap = max(960,Int((bpm*480/60*2).rounded()))
        for first in 1...score.measures {
            for last in first...score.measures {
                let clip = try PracticeReviewClip.make(score:score,from:first,through:last,bpm:bpm)
                let start = ticks, musicStart = start+lead, end = musicStart+clip.ticks
                slices.append(Slice(range:PracticeReviewRange(from:first,through:last),start:start,musicStart:musicStart,end:end))
                events += clip.events.map { MusicEvent(midi:$0.midi,onset:$0.onset+musicStart,duration:$0.duration) }
                ticks = end+gap
            }
        }
    }
    func slice(for range: PracticeReviewRange) -> Slice? { slices.first { $0.range == range } }
}
