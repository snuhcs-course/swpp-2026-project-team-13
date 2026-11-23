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
