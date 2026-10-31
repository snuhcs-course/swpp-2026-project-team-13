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
    var voiceId = "grand-piano"
    private let audioGraph = PianoAudioGraph()
    private var engine: AVAudioEngine { audioGraph.engine }
    private var sampler: AVAudioUnitSampler { audioGraph.piano }
    private var metronome: AVAudioUnitSampler { audioGraph.click }
    private var sequencer: AVAudioSequencer?
    private var main: MusicScore?
    private var scale: MusicScore?
    private var plan: PlaybackPlan?
    private var runner: Task<Void, Never>?
    private var prepared = false
    private var waitAnchor: TimeInterval?
    private var waitInitialMs = 0
    private var graphNeedsRebuild = true
    private var playbackGeneration = UUID()
    private var instrumentURL: URL?
    private var clickURL: URL?
    private var instrumentProgram: UInt8 = 0
    private var bankMSB: UInt8 = 121
    private var bankLSB: UInt8 = 0
    private var outputGain: Float = 1
    private var noteVelocity = 80

    func prepare(main: MusicScore, scale: MusicScore, plan: PlaybackPlan) throws {
        prepared = false; pause()
        try plan.validate()
        if let count = plan.countIn {
            guard count.beatsPerMeasure == main.timeSignature.numerator, count.beatUnit == main.timeSignature.denominator,
                  scale.timeSignature == main.timeSignature, scale.measures == plan.scale.toMeasure,
                  main.measures == 8 else { throw SORIError.invalidScore("예비박과 문제의 박자표가 다릅니다.") }
        }
        struct Bank: Decodable { var sha256:String; var sizeBytes:Int }
        let choices: InstrumentChoices = try Bundled.decode("instruments")
        guard let voice = choices.voices.first(where: { $0.id == voiceId }) else {
            throw SORIError.invalidScore("음원 리소스가 없습니다. 음원이 포함된 최신 앱으로 설치해 주세요.")
        }
        if voiceId == "grand-piano" {
            let piano = try ClassicalPiano.load()
            instrumentURL = piano.url; instrumentProgram = piano.program; bankMSB = piano.bankMsb; bankLSB = piano.bankLsb
            outputGain = pow(10,piano.gainDb/20); noteVelocity = Int(piano.noteVelocity)
        } else {
            guard let url = Bundle.main.url(forResource:"GeneralUser-GS",withExtension:"sf2") else { throw SORIError.invalidScore("음원 리소스가 없습니다.") }
            let bank: Bank = try Bundled.decode("instrument-bank")
            let data = try Data(contentsOf:url)
            guard data.count == bank.sizeBytes, data.sha256 == bank.sha256 else { throw SORIError.invalidScore("SOUND_BANK_UNAVAILABLE: 음원 리소스가 손상되었습니다.") }
            instrumentURL = url; instrumentProgram = voice.program; bankMSB = 121; bankLSB = 0
            outputGain = pow(10,voice.gainDb / 20); noteVelocity = plan.velocity
        }
        clickURL = nil
        if let count = plan.countIn {
            guard let url = Bundle.main.url(forResource:count.profileId,withExtension:"wav") else { throw SORIError.invalidScore("예비박 소리 리소스가 없습니다.") }
            clickURL = url
        }
        self.main = main; self.scale = scale; self.plan = plan
        for i in 0...11 { _ = try midi(index:i) }
        try rebuildAudioGraph()
        prepared = true; message = "스케일·예비박·11개 구간이 준비되었어요"
    }
    // A sampler is rebuilt after leaving a problem or an audio interruption. Reusing a
    // stopped I/O graph can leave a running sequencer connected to a silent instrument.
    private func rebuildAudioGraph() throws {
        sequencer?.stop(); sequencer = nil; engine.stop()
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback,mode:.default,options:[])
        try audio.setActive(true)
        guard let url = instrumentURL else { throw SORIError.invalidScore("SOUND_BANK_UNAVAILABLE") }
        try audioGraph.rebuild(bank:url,program:instrumentProgram,bankMSB:bankMSB,bankLSB:bankLSB,clickURL:clickURL,gain:outputGain)
        sequencer = AVAudioSequencer(audioEngine:engine)
        engine.prepare(); graphNeedsRebuild = false
    }
    func audioConfigurationChanged(_ notification: Notification) {
        guard let changed = notification.object as? AVAudioEngine, changed === engine else { return }
        invalidateAudio()
    }
    func invalidateAudio() { pause(); graphNeedsRebuild = true }
    func stopForPreparation() { prepared = false; pause() }
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
        let through = index == 0 ? plan.scale.toMeasure : plan.steps[index-1].toMeasure
        let events = try score.segment(from:from,through:through)
        let ticks = (through-from+1)*score.ticksPerMeasure
        if let count = countIn(index:index) { return MIDIFile.withCountIn(events:events,totalTicks:ticks,tempo:plan.tempoBpm,countIn:count,velocity:noteVelocity) }
        return MIDIFile.make(events:events,totalTicks:ticks,tempo:plan.tempoBpm,velocity:noteVelocity)
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
        let generation = UUID(); playbackGeneration = generation
        isPlaying = true
        runner = Task { [weak self] in
            guard let self, let plan else { return }
            do {
                try Task.checkCancellation()
                guard generation == playbackGeneration else { throw CancellationError() }
                if graphNeedsRebuild { try rebuildAudioGraph() }
                try AVAudioSession.sharedInstance().setActive(true)
                try engine.start()
                if cursor.index == 0, cursor.phase == "initial" {
                    try await wait(plan.initialDelayMs ?? 0,label:"시작 대기")
                    cursor.phase = "segment"; try onCursor?(cursor)
                }
                while cursor.index <= 11 {
                    try Task.checkCancellation()
                    guard generation == playbackGeneration else { throw CancellationError() }
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
                        let bars = index == 0 ? plan.scale.toMeasure-plan.scale.fromMeasure+1 : plan.steps[index-1].toMeasure-plan.steps[index-1].fromMeasure+1
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
            catch { if generation == playbackGeneration { pause(); onError?(error) } }
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
        playbackGeneration = UUID(); graphNeedsRebuild = true
        runner?.cancel(); runner = nil
        checkpointWait(); waitAnchor = nil
        silence(); engine.pause(); isPlaying = false
        if prepared, cursor.index <= 11 {
            if wasPlaying { do { try onCursor?(cursor) } catch { onError?(error) } }
            message = "일시 정지 · 재생 구간은 처음부터, 필기 시간은 남은 시간부터 이어져요"
        }
    }
}
