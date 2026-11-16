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
        guard bpm.isFinite, (20...400).contains(bpm) else { throw SolfegeError.invalidScore("재생 속도를 확인해 주세요.") }
        let from = measure ?? 1, to = measure ?? score.measures
        return PracticeReviewClip(events:try score.segment(from:from,through:to),ticks:(to-from+1)*score.ticksPerMeasure,bpm:bpm)
    }
}
