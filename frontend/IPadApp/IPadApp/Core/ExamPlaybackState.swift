import Foundation

struct PlaybackCursor: Codable, Equatable {
    var index = 0 // 0 = scale, 1...11 = main, 12 = finished
    var phase = "initial" // initial, segment, gap; legacy phases still decode
    var remainingWaitMs: Int? = nil
    var shortenedGap: Bool? = nil

    static let nextSegmentLeadMs = 1500
    var canSkipForward: Bool {
        guard (1...10).contains(index), ["segment","gap"].contains(phase) else { return false }
        return shortenedGap != true || index < 10
    }
    var nextSegmentIndex: Int? { phase == "gap" && shortenedGap == true ? index + 1 : nil }
    @discardableResult mutating func skipForward() -> Bool {
        guard canSkipForward else { return false }
        // A gap cursor belongs to the preceding segment. Further taps move the
        // queued target forward, including while the 1.5-second lead is running.
        if shortenedGap == true { index += 1 }
        let remaining = phase == "gap" && shortenedGap != true ? remainingWaitMs : nil
        phase = "gap"; shortenedGap = true
        remainingWaitMs = min(remaining ?? Self.nextSegmentLeadMs,Self.nextSegmentLeadMs)
        return true
    }
}
