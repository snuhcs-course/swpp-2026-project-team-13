import Foundation

struct PlaybackCursor: Codable, Equatable {
    var index = 0 // 0 = scale, 1...11 = main, 12 = finished
    var phase = "initial" // initial, segment, gap; legacy phases still decode
    var remainingWaitMs: Int? = nil
    var shortenedGap: Bool? = nil
    // Where a paused segment stopped, so resuming continues from that point.
    var segmentOffsetMs: Int? = nil

    static let nextSegmentLeadMs = 1500
    var canSkipForward: Bool {
        guard (1...10).contains(index), ["segment","gap"].contains(phase) else { return false }
        return shortenedGap != true || index < 10
    }
    var nextSegmentIndex: Int? { phase == "gap" && shortenedGap == true ? index + 1 : nil }
    // The progress indicator follows the requested target during its lead-in.
    var progressIndex: Int { min(12,max(0,nextSegmentIndex ?? index)) }
    @discardableResult mutating func skipForward() -> Bool {
        guard canSkipForward else { return false }
        // A gap cursor belongs to the preceding segment. Further taps move the
        // queued target forward, including while the 1.5-second lead is running.
        if shortenedGap == true { index += 1 }
        let remaining = phase == "gap" && shortenedGap != true ? remainingWaitMs : nil
        phase = "gap"; shortenedGap = true; segmentOffsetMs = nil
        remainingWaitMs = min(remaining ?? Self.nextSegmentLeadMs,Self.nextSegmentLeadMs)
        return true
    }
}

struct WritingTimerState: Equatable {
    var text: String
    var caption: String
    var urgent: Bool
    init(cursor: PlaybackCursor, plan: PlaybackPlan?, isPlaying: Bool) {
        urgent = false
        guard cursor.index <= 11 else { text = "0:00"; caption = "필기 시간 종료"; return }
        guard cursor.index > 0, cursor.phase == "gap", cursor.shortenedGap != true else {
            text = "—:—"
            caption = !isPlaying ? (cursor.phase == "initial" ? "재생 대기" : "일시정지") : cursor.shortenedGap == true ? "다음 구간 준비" : "재생 중"
            return
        }
        let limit = plan.flatMap { $0.steps.indices.contains(cursor.index-1) ? $0.steps[cursor.index-1].pauseAfterMs : nil }
            ?? (cursor.index == 11 ? 120_000 : 20_000)
        let seconds = max(0,((cursor.remainingWaitMs ?? limit)+999)/1000)
        text = String(format:"%d:%02d",seconds/60,seconds%60)
        caption = isPlaying ? "필기 남은 시간" : "일시정지"
        urgent = isPlaying && (1...5).contains(seconds)
    }
}
