import Foundation
import AVFoundation
import AudioToolbox

@MainActor protocol ScorePlaybackEngine: AnyObject {
    func prepare(main: MusicScore, scale: MusicScore, plan: PlaybackPlan) throws
    func pause()
    func resume()
}

@MainActor final class PianoPlayback: ObservableObject, ScorePlaybackEngine {
    @Published private(set) var isPlaying = false
    @Published private(set) var cursor = PlaybackCursor()
    @Published private(set) var message = "재생 준비 중"
    var onCursor: ((PlaybackCursor) throws -> Void)?
    var onError: ((Error) -> Void)?
    private var engine = AVAudioEngine()
    private var sampler = AVAudioUnitSampler()
    private var metronome = AVAudioUnitSampler()
    private var sequencer: AVAudioSequencer?
    private var main: MusicScore?
    private var scale: MusicScore?
    private var plan: PlaybackPlan?
    private var runner: Task<Void, Never>?
    private var prepared = false
    private var waitAnchor: TimeInterval?
    private var waitInitialMs = 0

    init() {
        engine.attach(sampler); engine.connect(sampler,to:engine.mainMixerNode,format:nil)
        engine.attach(metronome); engine.connect(metronome,to:engine.mainMixerNode,format:nil)
    }
    func prepare(main: MusicScore, scale: MusicScore, plan: PlaybackPlan) throws {
        prepared = false; pause()
        try plan.validate()
        if let count = plan.countIn {
            guard count.beatsPerMeasure == main.timeSignature.numerator, count.beatUnit == main.timeSignature.denominator,
                  scale.timeSignature == main.timeSignature else { throw SORIError.invalidScore("예비박과 문제의 박자표가 다릅니다.") }
        }
        struct Instrument: Decodable { var id:String; var sha256:String; var program:Int; var bankMsb:Int; var bankLsb:Int; var gainDb:Float }
        let manifest: Instrument = try Bundled.decode("instrument-profile")
        guard manifest.id == plan.instrumentProfileId, let url = Bundle.main.url(forResource:manifest.id,withExtension:"sf2"),
              try Data(contentsOf:url).sha256 == manifest.sha256 else { throw SORIError.invalidScore("SOUND_BANK_UNAVAILABLE: 피아노 리소스가 손상되었거나 없습니다.") }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback,mode:.default,options:[])
        try audio.setActive(true)
        try sampler.loadSoundBankInstrument(at:url,program:UInt8(manifest.program),bankMSB:UInt8(manifest.bankMsb),bankLSB:UInt8(manifest.bankLsb))
        if let count = plan.countIn {
            guard let clickURL = Bundle.main.url(forResource:count.profileId,withExtension:"wav") else { throw SORIError.invalidScore("예비박 소리 리소스가 없습니다.") }
            try metronome.loadAudioFiles(at:[clickURL])
        }
        engine.mainMixerNode.outputVolume = pow(10,manifest.gainDb / 20)
        self.main = main; self.scale = scale; self.plan = plan
        for i in 0...11 { _ = try midi(index:i) }
        let seq = AVAudioSequencer(audioEngine:engine)
        try seq.load(from:midi(index:0),options:[])
        route(seq,index:0); seq.prepareToPlay(); sequencer = seq
        engine.prepare(); try engine.start(); engine.pause()
        prepared = true; message = "스케일·예비박·11개 구간이 준비되었어요"
    }
    func restore(_ cursor: PlaybackCursor) {
        self.cursor = cursor
        message = cursor.index > 11 ? "필기 시간 종료 · 답안을 제출해 주세요" : "재생 계속을 누르면 저장된 단계부터 이어져요"
    }
    private func countIn(index:Int) -> CountInPlayback? {
        guard let count = plan?.countIn, count.beforeStepOrders.contains(index) else { return nil }
        return count
    }
    private func midi(index:Int) throws -> Data {
        guard let plan, let main, let scale else { throw SORIError.invalidScore("PLAYBACK_PREPARE_FAILED") }
        let score = index == 0 ? scale : main
        let from = index == 0 ? 1 : plan.steps[index-1].fromMeasure
        let through = index == 0 ? 2 : plan.steps[index-1].toMeasure
        let events = try score.segment(from:from,through:through)
        let ticks = (through-from+1)*score.ticksPerMeasure
        if let count = countIn(index:index) { return MIDIFile.withCountIn(events:events,totalTicks:ticks,tempo:plan.tempoBpm,countIn:count) }
        return MIDIFile.make(events:events,totalTicks:ticks,tempo:plan.tempoBpm)
    }
    private func route(_ seq:AVAudioSequencer,index:Int) {
        for (trackIndex,track) in seq.tracks.enumerated() {
            track.destinationAudioUnit = trackIndex == 1 && countIn(index:index) != nil ? metronome : sampler
        }
    }
    private func checkpointWait() {
        if let anchor = waitAnchor {
            cursor.remainingWaitMs = max(0,Int(ceil(Double(waitInitialMs)-(ProcessInfo.processInfo.systemUptime-anchor)*1000)))
        }
    }
    private func wait(_ milliseconds:Int,label:String,releaseTail:Bool = false) async throws {
        waitInitialMs = cursor.remainingWaitMs ?? milliseconds
        waitAnchor = ProcessInfo.processInfo.systemUptime
        cursor.remainingWaitMs = waitInitialMs
        try onCursor?(cursor)
        var released = !releaseTail
        while (cursor.remainingWaitMs ?? 0) > 0 {
            try Task.checkCancellation()
            let remaining = cursor.remainingWaitMs ?? 0
            message = "\(label) · \((remaining+999)/1000)초"
            // Natural piano release occupies the beginning of the prescribed pause, not extra time.
            if !released, remaining <= waitInitialMs-min(plan?.releaseTailMs ?? 0,waitInitialMs) {
                silence(); released = true
            }
            try await Task.sleep(for:.milliseconds(min(remaining,released ? 1000 : 100)))
            checkpointWait()
            try onCursor?(cursor)
        }
        if releaseTail { silence() }
        waitAnchor = nil; cursor.remainingWaitMs = nil
    }
    func resume() {
        guard prepared, !isPlaying, cursor.index <= 11 else { return }
        isPlaying = true
        runner = Task { [weak self] in
            guard let self, let plan else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try engine.start()
                if cursor.index == 0, cursor.phase == "initial" {
                    try await wait(plan.initialDelayMs ?? 0,label:"시작 대기")
                    cursor.phase = "segment"; try onCursor?(cursor)
                }
                while cursor.index <= 11 {
                    try Task.checkCancellation()
                    let index = cursor.index
                    if cursor.phase != "gap" {
                        guard let seq = sequencer, let score = (index == 0 ? self.scale : self.main) else { throw SORIError.invalidScore("PLAYBACK_PREPARE_FAILED") }
                        seq.stop()
                        try seq.load(from:midi(index:index),options:[])
                        route(seq,index:index)
                        seq.currentPositionInBeats = 0; seq.prepareToPlay()
                        let count = countIn(index:index)
                        message = count.map { "예비박 · \($0.beatsPerMeasure)/\($0.beatUnit) · \($0.beatsPerMeasure)박" }
                            ?? (index == 0 ? "스케일 제시" : "\(index) / 11 · \(plan.steps[index-1].fromMeasure)–\(plan.steps[index-1].toMeasure)마디")
                        try seq.start()
                        let began = ProcessInfo.processInfo.systemUptime
                        let bars = index == 0 ? 2 : plan.steps[index-1].toMeasure-plan.steps[index-1].fromMeasure+1
                        let countTicks = count?.totalTicks ?? 0
                        let seconds = Double(bars*score.ticksPerMeasure+countTicks) / 480 * 60 / Double(plan.tempoBpm)
                        if countTicks > 0 {
                            try await Task.sleep(for:.seconds(Double(countTicks) / 480 * 60 / Double(plan.tempoBpm)))
                            message = "\(index) / 11 · 1–8마디"
                        }
                        let remaining = max(0,seconds-(ProcessInfo.processInfo.systemUptime-began))
                        if remaining > 0 { try await Task.sleep(for:.seconds(remaining)) }
                        seq.stop()
                        sampler.sendController(123,withValue:0,onChannel:0)
                        metronome.sendController(123,withValue:0,onChannel:0)
                        cursor.phase = "gap"; cursor.remainingWaitMs = nil; try onCursor?(cursor)
                    }
                    let gap = index == 0 ? plan.pauseAfterScaleMs : plan.steps[index-1].pauseAfterMs
                    let label = index == 0 ? "예비박까지" : index == 11 ? "마지막 필기 시간" : "필기 시간"
                    try await wait(gap,label:label,releaseTail:true)
                    cursor.index += 1; cursor.phase = "segment"; try onCursor?(cursor)
                }
                message = "필기 시간 종료 · 답안을 제출해 주세요"
                isPlaying = false; engine.pause()
            } catch is CancellationError { }
            catch { pause(); onError?(error) }
        }
    }
    private func silence() {
        sequencer?.stop()
        for unit in [sampler,metronome] {
            unit.sendController(120,withValue:0,onChannel:0)
            unit.sendController(123,withValue:0,onChannel:0)
        }
    }
    func pause() {
        let wasPlaying = isPlaying
        runner?.cancel(); runner = nil
        checkpointWait(); waitAnchor = nil
        silence(); engine.pause(); isPlaying = false
        if prepared, cursor.index <= 11 {
            if wasPlaying { do { try onCursor?(cursor) } catch { onError?(error) } }
            message = "일시 정지 · 재생 구간은 처음부터, 필기 시간은 남은 시간부터 이어져요"
        }
    }
}
