import Foundation
import CoreGraphics

enum TutorialKind: String, CaseIterable, Codable {
    case echoDragon, memoryRun, rhythmPuzzle, exam
    var title: String {
        switch self {
        case .echoDragon: return "Echo Dragon"
        case .memoryRun: return "Memory run"
        case .rhythmPuzzle: return "Rhythm puzzle"
        case .exam: return "시험 모드"
        }
    }
}
enum TutorialHint: String { case rhythmSpecialLengths }

// The caller supplies LocalStore's per-server/per-account directory. This also
// makes account deletion remove tutorial history, without retaining a user ID.
struct TutorialProgressStore {
    let root: URL
    private var file: URL { root.appendingPathComponent("tutorial-overlays-v2.json") }
    func hasSeen(_ kind: TutorialKind) -> Bool {
        (try? load().contains(kind.rawValue)) ?? false
    }
    func markSeen(_ kind: TutorialKind) throws {
        try mark(kind.rawValue)
    }
    func hasSeenHint(_ hint: TutorialHint) -> Bool { (try? load().contains("hint:"+hint.rawValue)) ?? false }
    func markHintSeen(_ hint: TutorialHint) throws { try mark("hint:"+hint.rawValue) }
    private func mark(_ key: String) throws {
        var seen = try load()
        seen.insert(key)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(seen).write(to: file, options: .atomic)
    }
    private func load() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: file))
    }
}

// Only the floating coach gets a frame. The demo always keeps the full viewport.
// Try regular cards and shallow banners against *all* active interaction areas.
struct TutorialFloatingLayout {
    let frame: CGRect
    var compact: Bool { frame.width > 450 && frame.height < 230 }
    init(viewport: CGSize, avoiding obstacles: [CGRect], interactive: Bool, largeText: Bool = false) {
        let bounds = CGRect(origin: .zero, size: viewport).insetBy(dx: 12, dy: 12)
        let regular = CGSize(width: min(360, bounds.width), height: min(largeText ? 380 : 260, bounds.height))
        guard interactive else {
            frame = CGRect(x: bounds.midX-regular.width/2, y: bounds.midY-regular.height/2, width: regular.width, height: regular.height)
            return
        }
        let wide = min(largeText ? 960 : 840, bounds.width)
        let sizes = [regular, CGSize(width: wide, height: min(largeText ? 200 : 156, bounds.height)),
                     CGSize(width: wide, height: min(largeText ? 176 : 128, bounds.height)),
                     CGSize(width: wide, height: min(largeText ? 152 : 112, bounds.height))]
        let protected = obstacles.filter { !$0.isNull && !$0.isEmpty }.map { $0.insetBy(dx: -8, dy: -8) }
        var best = CGRect(origin: bounds.origin, size: regular), bestScore = CGFloat.infinity
        for (rank, size) in sizes.enumerated() {
            let xs = [bounds.minX, bounds.midX-size.width/2, bounds.maxX-size.width] + protected.flatMap { [$0.minX-size.width, $0.maxX] }
            let ys = [bounds.minY, bounds.midY-size.height/2, bounds.maxY-size.height] + protected.flatMap { [$0.minY-size.height, $0.maxY] }
            for x in xs { for y in ys {
                let rect = CGRect(x: min(max(bounds.minX, x), bounds.maxX-size.width),
                                  y: min(max(bounds.minY, y), bounds.maxY-size.height), width: size.width, height: size.height)
                let overlap = protected.reduce(CGFloat.zero) { total, area in
                    let intersection = rect.intersection(area)
                    return total + (intersection.isNull ? 0 : intersection.width*intersection.height)
                }
                let score = overlap*10000 + CGFloat(rank)*10 + abs(rect.midX-bounds.midX)*0.01 + (rect.minY-bounds.minY)*0.001
                if score < bestScore { bestScore = score; best = rect }
            } }
        }
        frame = best
    }
}

// Use the same untransposed click sample and notated beat length as the games.
struct TutorialCountIn {
    let ticks: Int
    let clicks: [MusicEvent]
    init(meter: TimeSignature, enabled: Bool) {
        let count = CountInPlayback(measures: 1, beforeStepOrders: [1], beatsPerMeasure: meter.numerator,
                                   beatUnit: meter.denominator, accentVelocity: 105, velocity: 75, profileId: "sori-click-v1")
        ticks = enabled ? count.totalTicks : 0
        clicks = enabled ? (0..<count.beatsPerMeasure).map {
            MusicEvent(midi: 60, onset: $0*count.ticksPerBeat, duration: min(40, count.ticksPerBeat))
        } : []
    }
}

// Choose a side with enough room, then constrain the bubble to the visible
// viewport. Used for small iPads, split windows and larger accessibility text.
struct TutorialBubbleLayout {
    let frame: CGRect
    init(viewport: CGSize, target: CGRect?, preferredHeight: CGFloat) {
        let bounds = CGRect(origin: .zero, size: viewport).insetBy(dx: 16, dy: 16)
        let width = min(360, max(0, bounds.width))
        let height = min(preferredHeight, max(0, bounds.height))
        guard let target, !target.isEmpty else {
            frame = CGRect(x: bounds.midX-width/2, y: bounds.midY-height/2, width: width, height: height)
            return
        }
        let gap: CGFloat = 16
        let above = max(0, target.minY-gap-bounds.minY)
        let below = max(0, bounds.maxY-target.maxY-gap)
        let left = max(0, target.minX-gap-bounds.minX)
        let right = max(0, bounds.maxX-target.maxX-gap)
        var rect: CGRect
        if max(above, below) >= min(height, 260) {
            let h = min(height, max(above, below))
            rect = CGRect(x: target.midX-width/2,
                          y: below >= above ? target.maxY+gap : target.minY-gap-h,
                          width: width, height: h)
        } else if max(left, right) >= 230 {
            let w = min(width, max(left, right))
            rect = CGRect(x: right >= left ? target.maxX+gap : target.minX-gap-w,
                          y: target.midY-height/2, width: w, height: height)
        } else {
            rect = CGRect(x: bounds.midX-width/2, y: bounds.midY-height/2, width: width, height: height)
        }
        rect.origin.x = min(max(bounds.minX, rect.minX), bounds.maxX-rect.width)
        rect.origin.y = min(max(bounds.minY, rect.minY), bounds.maxY-rect.height)
        frame = rect
    }
}
