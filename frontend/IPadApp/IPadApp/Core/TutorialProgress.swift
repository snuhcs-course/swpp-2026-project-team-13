import Foundation

enum TutorialKind: String, CaseIterable, Codable {
    case echoDragon, memoryRun, rhythmPuzzle, exam
    var title: String {
        switch self {
        case .echoDragon: return "Echo Dragon"
        case .memoryRun: return "Memory run"
        case .rhythmPuzzle: return "Rhythm puzzle"
        case .exam: return "Exam"
        }
    }
}
enum TutorialHint: String { case rhythmSpecialLengths }

// The caller supplies LocalStore's per-server/per-account directory. This also
// makes account deletion remove tutorial history, without retaining a user ID.
struct TutorialProgressStore {
    let root: URL
    private var file: URL { root.appendingPathComponent("tutorial-overlays-v1.json") }
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
