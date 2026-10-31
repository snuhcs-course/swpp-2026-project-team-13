import Foundation

struct PlaybackCursor: Codable, Equatable {
    var index = 0 // 0 = scale, 1...11 = main, 12 = finished
    var phase = "initial" // initial, segment, gap; legacy phases still decode
    var remainingWaitMs: Int? = nil
    var shortenedGap: Bool? = nil

    static let nextSegmentLeadMs = 3000
    var canShortenWritingWait: Bool {
        phase == "gap" && (1...10).contains(index) && shortenedGap != true &&
            (remainingWaitMs ?? 0) > Self.nextSegmentLeadMs
    }
    @discardableResult mutating func shortenWritingWait() -> Bool {
        guard canShortenWritingWait else { return false }
        remainingWaitMs = Self.nextSegmentLeadMs; shortenedGap = true
        return true
    }
}
