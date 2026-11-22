import CoreGraphics

enum TutorialTarget: Hashable {
    case start, replay, keyboard, firstKey, notation, choices, tie, submit
    case progress, timer, tools, next, playPause, undo, erase
    case rhythmTapTile, rhythmDragTile, dropSlot, tieStart, tieEnd, character
}

enum TutorialPopupRule: Equatable {
    case center, above(TutorialTarget), below(TutorialTarget)
    case aboveKeyboard(TutorialTarget), memoryGap, aboveNotation
    case belowNotationTrailing, scoreLowerTrailing
}

// These are the agreed teaching positions, not a search for any empty corner.
// Coordinates always come from the actual control or notation view.
struct TutorialPopupLayout {
    let frame: CGRect
    let isResolved: Bool
    var compact: Bool { frame.width > 450 && frame.height < 230 }

    static func rule(kind: TutorialKind, page: Int) -> TutorialPopupRule {
        guard page > 0 else { return .center }
        switch kind {
        case .echoDragon:
            switch page {
            case 1: return .above(.start)
            case 2: return .above(.replay)
            case 3: return .aboveKeyboard(.firstKey)
            case 4: return .aboveKeyboard(.keyboard)
            default: return .above(.submit)
            }
        case .memoryRun:
            switch page {
            case 1: return .above(.start)
            case 2: return .above(.replay)
            case 3, 4: return .memoryGap
            default: return .above(.submit)
            }
        case .rhythmPuzzle:
            switch page {
            case 1: return .above(.start)
            case 2: return .above(.replay)
            case 3: return .aboveNotation
            case 4: return .belowNotationTrailing
            case 5: return .above(.tie)
            default: return .above(.submit)
            }
        case .exam:
            switch page {
            case 1, 5: return .below(.progress)
            case 2: return .below(.timer)
            case 3: return .below(.tools)
            case 4: return .scoreLowerTrailing
            case 6: return .above(.next)
            default: return .above(.submit)
            }
        }
    }

    init(kind: TutorialKind, page: Int, viewport: CGSize, anchors: [TutorialTarget: CGRect], largeText: Bool = false) {
        let bounds = CGRect(x: 12, y: 12, width: max(0, viewport.width-24), height: max(0, viewport.height-24))
        let gap: CGFloat = 14
        let width = min(CGFloat(360), bounds.width)
        let height = min(CGFloat(largeText ? 380 : kind == .exam ? 340 : 260), bounds.height)
        let wide = min(CGFloat(largeText ? 940 : 840), bounds.width)
        func anchor(_ key: TutorialTarget) -> CGRect? {
            // Before listening starts, the main action occupies the future
            // submit slot. The Next control itself is always present.
            let rect = anchors[key] ?? (key == .submit ? anchors[.start] : nil)
            guard let rect, !rect.isNull, !rect.isEmpty else { return nil }
            return rect
        }
        var rect = CGRect(x: bounds.midX-width/2, y: bounds.midY-height/2, width: width, height: height)
        var resolved = true
        switch Self.rule(kind: kind, page: page) {
        case .center: break
        case .above(let key):
            if let target = anchor(key) {
                var h = min(height, max(96, target.minY-gap-bounds.minY))
                if kind == .rhythmPuzzle && page == 5, let staff = anchor(.notation) {
                    h = min(h, max(96, target.minY-staff.maxY-2*gap))
                }
                rect = CGRect(x: target.midX-width/2, y: target.minY-gap-h, width: width, height: h)
            } else { resolved = false }
        case .below(let key):
            if let target = anchor(key) {
                let x = key == .timer ? target.maxX-width : key == .tools ? target.minX : target.midX-width/2
                rect = CGRect(x: x, y: target.maxY+gap, width: width, height: height)
            } else { resolved = false }
        case .aboveKeyboard(let key):
            if let keys = anchor(.keyboard) {
                let x = anchor(key)?.midX ?? keys.midX
                let h = min(height, max(96, keys.minY-gap-bounds.minY))
                rect = CGRect(x: x-width/2, y: keys.minY-gap-h, width: width, height: h)
            } else { resolved = false }
        case .memoryGap:
            if let staff = anchor(.notation), let keys = anchor(.keyboard) {
                let top = staff.maxY+gap, bottom = keys.minY-gap
                let h = min(CGFloat(largeText ? 190 : 144), max(96, bottom-top))
                rect = CGRect(x: bounds.midX-wide/2, y: (top+bottom-h)/2, width: wide, height: h)
            } else { resolved = false }
        case .aboveNotation:
            if let staff = anchor(.notation) {
                let h = min(CGFloat(largeText ? 176 : 128), max(96, staff.minY-gap-bounds.minY))
                rect = CGRect(x: bounds.midX-wide/2, y: staff.minY-gap-h, width: wide, height: h)
            } else { resolved = false }
        case .belowNotationTrailing:
            if let staff = anchor(.notation) {
                rect = CGRect(x: staff.maxX-width, y: staff.maxY+gap, width: width, height: height)
            } else { resolved = false }
        case .scoreLowerTrailing:
            if let staff = anchor(.notation) {
                rect = CGRect(x: staff.maxX-width-12, y: staff.maxY-height-12, width: width, height: height)
            } else { resolved = false }
        }
        rect.origin.x = min(max(bounds.minX, rect.minX), bounds.maxX-rect.width)
        rect.origin.y = min(max(bounds.minY, rect.minY), bounds.maxY-rect.height)
        frame = rect; isResolved = resolved
    }
}
