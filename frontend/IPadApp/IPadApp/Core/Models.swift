import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Server enums intentionally remain strings: an added enum value must never crash decoding.
struct UserProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var displayName: String
    var learningGoal: String
}
struct KeySignature: Codable, Equatable { var tonic: String; var mode: String; var fifths: Int }
struct TimeSignature: Codable, Equatable {
    var numerator: Int; var denominator: Int
    var ticksPerMeasure: Int { numerator * 480 * 4 / denominator }
    var supported: Bool { [(4,4), (3,4), (6,8)].contains { $0.0 == numerator && $0.1 == denominator } }
}
struct SheetSystem: Codable, Equatable {
    var index: Int; var firstMeasure: Int; var lastMeasure: Int
    var staffLineY: [Double]; var barlineX: [Double]
}
struct SheetLayout: Codable, Equatable {
    var id: String
    var logicalWidth: Int; var logicalHeight: Int; var exportScale: Int
    var pixelWidth: Int; var pixelHeight: Int
    var templatePngUrl: URL; var templateSha256: String; var systems: [SheetSystem]
    func validate() throws {
        guard ["staff-8bars-v1", "staff-8bars-4-4-v2", "staff-8bars-3-4-v2", "staff-8bars-6-8-v2"].contains(id), logicalWidth == 1330, logicalHeight == 846,
              exportScale == 2, pixelWidth == 2660, pixelHeight == 1692,
              systems.count == 2, systems.allSatisfy({ $0.staffLineY.count == 5 && $0.barlineX.count == 5 }) else {
            throw SORIError.unsupported("지원하지 않는 오선 템플릿입니다.")
        }
    }
}
struct ScoreAsset: Codable, Equatable {
    var url: URL; var contentType: String; var sha256: String; var sizeBytes: Int
    var musicxmlVersion: String; var profile: String; var partId: String; var measureCount: Int
    var sourceTempoBpm: Double? = nil
}
struct ScoreAssets: Codable, Equatable { var main: ScoreAsset; var scale: ScoreAsset }
struct QuestionSummary: Codable, Identifiable, Equatable {
    var id: UUID; var version: Int; var title: String; var source: String
    var keySignature: KeySignature; var timeSignature: TimeSignature
    var measureCount: Int; var recommendedDurationSeconds: Int
    var tempo: TempoSetting? = nil
}
struct Question: Codable, Identifiable, Equatable {
    var id: UUID; var version: Int; var title: String; var source: String
    var keySignature: KeySignature; var timeSignature: TimeSignature
    var measureCount: Int; var recommendedDurationSeconds: Int
    var description: String; var timePolicy: String; var clef: String
    var sheetLayout: SheetLayout; var contentPolicy: String; var scoreVisibility: String; var scoreAssets: ScoreAssets
    var tempo: TempoSetting? = nil
    func validate() throws {
        try sheetLayout.validate()
        guard source == "practice", keySignature.tonic == "C", keySignature.mode == "major", keySignature.fifths == 0,
              timeSignature.supported, measureCount == 8,
              timePolicy == "advisory", clef == "treble", contentPolicy == "client_readable_practice",
              scoreVisibility == "after_submission" else { throw SORIError.unsupported("지원하지 않는 문제 형식입니다.") }
    }
}
struct QuestionPage: Codable { var count: Int; var next: URL?; var previous: URL?; var results: [QuestionSummary] }
struct PlaybackStep: Codable, Equatable {
    var order: Int; var fromMeasure: Int; var toMeasure: Int; var scoreKind: String; var pauseAfterMs: Int
}
struct ScalePlayback: Codable, Equatable { var scoreKind: String; var fromMeasure: Int; var toMeasure: Int }
struct CountInPlayback: Codable, Equatable {
    var measures: Int; var beforeStepOrders: [Int]
    var beatsPerMeasure: Int; var beatUnit: Int
    var accentVelocity: Int; var velocity: Int; var profileId: String
    var ticksPerBeat: Int { 480 * 4 / beatUnit }
    var totalTicks: Int { measures * beatsPerMeasure * ticksPerBeat }
}
struct TempoSetting: Codable, Equatable {
    var policyId: String; var beatUnit: String; var bpm: Int
    var minimumBpm: Int; var maximumBpm: Int
    var quarterBpm: Double { Double(bpm) * (beatUnit == "dotted_quarter" ? 1.5 : 1) }
    var label: String { "\(beatUnit == "dotted_quarter" ? "♩." : "♩") = \(bpm)" }
    func validate(meter: TimeSignature? = nil) throws {
        guard ["quarter","dotted_quarter"].contains(beatUnit), !policyId.isEmpty,
              minimumBpm > 0, maximumBpm >= minimumBpm, (minimumBpm...maximumBpm).contains(bpm),
              quarterBpm >= 40, quarterBpm <= 200 else { throw SORIError.unsupported("템포 설정을 확인해 주세요.") }
        if let meter {
            guard beatUnit == (meter.denominator == 8 ? "dotted_quarter" : "quarter") else { throw SORIError.unsupported("템포의 기준 음표가 박자와 다릅니다.") }
        }
    }
}
struct PlaybackPlan: Codable, Equatable {
    var version: Int; var engine: String; var tempoBpm: Double; var instrumentProfileId: String
    var tuningHz: Double; var transposeSemitones: Int; var velocity: Int; var gateRatio: Double; var releaseTailMs: Int
    var scale: ScalePlayback; var pauseAfterScaleMs: Int
    var allowManualPause: Bool; var allowManualReplay: Bool; var interruptionPolicy: String; var steps: [PlaybackStep]
    var initialDelayMs: Int? = nil
    var countIn: CountInPlayback? = nil
    var tempo: TempoSetting? = nil

    static func exam(meter: TimeSignature, setting: TempoSetting? = nil, scaleMeasures: Int? = nil) -> PlaybackPlan {
        let selected = setting ?? TempoDefaults.setting(for:meter)
        let ranges = [(1,8),(1,2),(1,2),(1,4),(3,4),(3,6),(5,6),(5,8),(7,8),(7,8),(1,8)]
        return PlaybackPlan(version:4,engine:"local_midi",tempoBpm:selected.quarterBpm,instrumentProfileId:"sori-piano-v2",
            tuningHz:440,transposeSemitones:0,velocity:80,gateRatio:1,releaseTailMs:300,
            scale:ScalePlayback(scoreKind:"scale",fromMeasure:1,toMeasure:scaleMeasures ?? (meter.numerator == 4 ? 2 : 3)),pauseAfterScaleMs:2000,
            allowManualPause:true,allowManualReplay:false,interruptionPolicy:"restart_current_segment",
            steps:ranges.enumerated().map { i, range in
                PlaybackStep(order:i+1,fromMeasure:range.0,toMeasure:range.1,scoreKind:"main",pauseAfterMs:i == 10 ? 120000 : 20000)
            },initialDelayMs:2000,
            countIn:CountInPlayback(measures:1,beforeStepOrders:[1,11],beatsPerMeasure:meter.numerator,beatUnit:meter.denominator,
                accentVelocity:110,velocity:70,profileId:"sori-click-v1"),tempo:selected)
    }
    func nominalDurationSeconds(meter: TimeSignature) -> Double {
        let bars = scale.toMeasure-scale.fromMeasure+1 + steps.reduce(0) { $0+$1.toMeasure-$1.fromMeasure+1 }
        let countTicks = (countIn?.totalTicks ?? 0) * (countIn?.beforeStepOrders.count ?? 0)
        let audio = Double(bars*meter.ticksPerMeasure+countTicks)/480*60/tempoBpm
        let pauses = (initialDelayMs ?? 0)+pauseAfterScaleMs+steps.reduce(0) { $0+$1.pauseAfterMs }
        return audio+Double(pauses)/1000
    }
    func validate() throws {
        let ranges = [(1,8),(1,2),(1,2),(1,4),(3,4),(3,6),(5,6),(5,8),(7,8),(7,8),(1,8)]
        guard [2,3,4].contains(version), engine == "local_midi",
              instrumentProfileId == (version == 4 ? "sori-piano-v2" : "sori-piano-v1"), tuningHz == 440,
              transposeSemitones == 0, velocity == 80, gateRatio == 1, releaseTailMs == 300,
              tempoBpm.isFinite, (40...200).contains(tempoBpm), allowManualPause, !allowManualReplay,
              interruptionPolicy == "restart_current_segment", scale.scoreKind == "scale", scale.fromMeasure == 1,
              (version == 4 ? [2,3].contains(scale.toMeasure) : scale.toMeasure == 2), pauseAfterScaleMs >= 0, steps.count == 11,
              zip(steps,ranges).enumerated().allSatisfy({ i,pair in
                  pair.0.order == i+1 && pair.0.fromMeasure == pair.1.0 && pair.0.toMeasure == pair.1.1 && pair.0.scoreKind == "main" && pair.0.pauseAfterMs >= 0
              }) else { throw SORIError.unsupported("지원하지 않는 재생 계획입니다.") }
        if version >= 3 {
            guard initialDelayMs == 2000, pauseAfterScaleMs == 2000, let countIn,
                  countIn.measures == 1, countIn.beforeStepOrders == [1,11],
                  TimeSignature(numerator:countIn.beatsPerMeasure,denominator:countIn.beatUnit).supported,
                  countIn.accentVelocity == 110, countIn.velocity == 70, countIn.profileId == "sori-click-v1",
                  steps.enumerated().allSatisfy({ $0.element.pauseAfterMs == ($0.offset == 10 ? 120000 : 20000) })
            else { throw SORIError.unsupported("시험의 예비박·필기 시간 설정을 확인해 주세요.") }
        } else if countIn != nil || (initialDelayMs ?? 0) != 0 {
            throw SORIError.unsupported("구버전 재생 계획에 예비박을 추가할 수 없습니다.")
        }
        if version == 4 {
            guard let tempo, let countIn, abs(tempo.quarterBpm-tempoBpm) < 0.000001 else { throw SORIError.unsupported("템포 환산이 일치하지 않습니다.") }
            try tempo.validate(meter:TimeSignature(numerator:countIn.beatsPerMeasure,denominator:countIn.beatUnit))
        }
    }
}
struct Answer: Codable, Identifiable, Equatable {
    var id: UUID; var attemptId: UUID; var clientAnswerId: UUID; var revision: Int; var answerFormatVersion: Int
    var sheetLayoutId: String; var imageWidth: Int; var imageHeight: Int; var contentType: String
    var sizeBytes: Int; var sha256: String; var createdAt: Date; var imageUrl: URL
}
struct Attempt: Codable, Identifiable, Equatable {
    var id: UUID; var status: String; var gradingMode: String; var createdAt: Date
    var startedAt: Date?; var recommendedEndAt: Date?; var submittedAt: Date?; var submittedAnswerId: UUID?; var latestAnswer: Answer?
    var question: Question; var playbackPlan: PlaybackPlan; var serverTime: Date
}
struct BBox: Codable, Equatable {
    var x: Double; var y: Double; var width: Double; var height: Double
    var isValid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1.000001 && y + height <= 1.000001 }
}
struct Annotation: Codable, Identifiable, Equatable { var id: String; var type: String; var measure: Int?; var bbox: BBox?; var message: String }
struct Feedback: Codable, Equatable { var summary: String; var recommendations: [String] }
struct GradingFailure: Codable, Equatable { var code: String; var message: String; var retryable: Bool }
struct Grading: Codable, Equatable {
    var attemptId: UUID; var answerId: UUID; var jobId: UUID; var gradingMode: String; var gradingVersion: String
    var status: String; var stage: String; var score: Int?; var pitchAccuracy: Double?; var rhythmAccuracy: Double?
    var feedback: Feedback?; var annotations: [Annotation]; var failure: GradingFailure?; var pollAfterMs: Int
    var createdAt: Date; var updatedAt: Date; var serverTime: Date
    var isPending: Bool { status == "queued" || status == "processing" }
    var canRetry: Bool { status == "failed" && failure?.retryable == true }
}
struct FieldError: Codable, Equatable { var field: String; var code: String; var message: String }
struct ErrorDetail: Codable, Equatable { var code: String; var message: String; var fields: [FieldError]; var retryAfterMs: Int? }
struct ErrorEnvelope: Codable, Equatable { var error: ErrorDetail; var requestId: String }

enum SORIError: LocalizedError {
    case configuration(String), unsupported(String), invalidScore(String), storage(String), transport(String)
    case server(Int, ErrorEnvelope?, retryAfter: TimeInterval?)
    var errorDescription: String? {
        switch self {
        case .configuration(let m), .unsupported(let m), .invalidScore(let m), .storage(let m), .transport(let m): return m
        case .server(let status, let envelope, _):
            if status == 401 { return "인증이 만료되었습니다. 연결 설정에서 토큰을 갱신해 주세요. 필기는 보관되어 있습니다." }
            guard let envelope else { return "서버 응답을 확인해 주세요. (HTTP \(status))" }
            let fields = envelope.error.fields.map(\.message).joined(separator: "\n")
            return envelope.error.message + (fields.isEmpty ? "" : "\n" + fields) + "\n요청 ID: " + envelope.requestId
        }
    }
    var code: String? { if case .server(_, let e, _) = self { return e?.error.code }; return nil }
}

enum ContractJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer(); let value = try container.decode(String.self)
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: value) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid RFC3339 date")
        }; return decoder
    }
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }
}

// Continuous monotonic time includes system sleep; the device wall clock is never used.
enum MonotonicTime {
    static var now: TimeInterval {
        #if canImport(Darwin)
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
        #else
        return ProcessInfo.processInfo.systemUptime
        #endif
    }
}
struct AdvisoryClock {
    var secondsAtSync: TimeInterval = 0
    var uptimeAtSync: TimeInterval = 0
    mutating func sync(_ attempt: Attempt, uptime: TimeInterval = MonotonicTime.now) {
        secondsAtSync = max(0, attempt.recommendedEndAt?.timeIntervalSince(attempt.serverTime) ?? 0); uptimeAtSync = uptime
    }
    func remaining(uptime: TimeInterval = MonotonicTime.now) -> Int { max(0, Int(ceil(secondsAtSync - max(0, uptime - uptimeAtSync)))) }
}
