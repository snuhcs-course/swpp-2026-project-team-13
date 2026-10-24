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
    private var sequencer: AVAudioSequencer?
    private var main: MusicScore?
    private var scale: MusicScore?
    private var plan: PlaybackPlan?
    private var runner: Task<Void, Never>?
    private var prepared = false

    init() { engine.attach(sampler); engine.connect(sampler, to: engine.mainMixerNode, format: nil) }
    func prepare(main: MusicScore, scale: MusicScore, plan: PlaybackPlan) throws {
        pause(); prepared = false
        try plan.validate()
        struct Instrument: Decodable { var id: String; var sha256: String; var program: Int; var bankMsb: Int; var bankLsb: Int; var gainDb: Float }
        let manifest: Instrument = try Bundled.decode("instrument-profile")
        guard manifest.id == plan.instrumentProfileId, let url = Bundle.main.url(forResource: manifest.id, withExtension: "sf2"),
              try Data(contentsOf: url).sha256 == manifest.sha256 else { throw SORIError.invalidScore("SOUND_BANK_UNAVAILABLE: 피아노 리소스가 손상되었거나 없습니다.") }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .default, options: [])
        try audio.setActive(true)
        try sampler.loadSoundBankInstrument(at: url, program: UInt8(manifest.program), bankMSB: UInt8(manifest.bankMsb), bankLSB: UInt8(manifest.bankLsb))
        engine.mainMixerNode.outputVolume = pow(10, manifest.gainDb / 20)
        self.main = main; self.scale = scale; self.plan = plan
        // Validate every segment before starting the server's advisory clock.
        for i in 0...11 { _ = try midi(index: i) }
        let seq = AVAudioSequencer(audioEngine: engine)
        try seq.load(from: midi(index: 0), options: [])
        seq.tracks.forEach { $0.destinationAudioUnit = sampler }; seq.prepareToPlay(); sequencer = seq
        engine.prepare(); try engine.start(); engine.pause()
        prepared = true; message = "스케일과 11개 구간이 준비되었어요"
    }
    func restore(_ cursor: PlaybackCursor) {
        self.cursor = cursor
        message = cursor.index > 11 ? "모든 구간 재생 완료" : "재생 계속을 누르면 현재 구간부터 시작해요"
    }
    private func midi(index: Int) throws -> Data {
        guard let plan, let main, let scale else { throw SORIError.invalidScore("PLAYBACK_PREPARE_FAILED") }
        let score = index == 0 ? scale : main
        let from = index == 0 ? 1 : plan.steps[index-1].fromMeasure
        let through = index == 0 ? 2 : plan.steps[index-1].toMeasure
        return try MIDIFile.make(events: score.segment(from: from, through: through), totalTicks: (through-from+1)*1920, tempo: plan.tempoBpm)
    }
    func resume() {
        guard prepared, !isPlaying, cursor.index <= 11 else { return }
        isPlaying = true
        runner = Task { [weak self] in
            guard let self, let plan else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try engine.start()
                while cursor.index <= 11 {
                    try Task.checkCancellation()
                    let index = cursor.index
                    if cursor.phase != "gap" {
                        message = index == 0 ? "스케일 제시" : "\(index) / 11 · \(plan.steps[index-1].fromMeasure)–\(plan.steps[index-1].toMeasure)마디"
                        guard let seq = sequencer else { throw SORIError.invalidScore("PLAYBACK_PREPARE_FAILED: 시퀀서가 없습니다.") }
                        seq.stop()
                        try seq.load(from: midi(index: index), options: [])
                        seq.tracks.forEach { $0.destinationAudioUnit = sampler }; seq.currentPositionInBeats = 0; seq.prepareToPlay()
                        try seq.start()
                        let bars = index == 0 ? 2 : plan.steps[index-1].toMeasure-plan.steps[index-1].fromMeasure+1
                        try await Task.sleep(for: .seconds(Double(bars*4)*60/Double(plan.tempoBpm)))
                        seq.stop(); sampler.sendController(123, withValue: 0, onChannel: 0)
                        try await Task.sleep(for: .milliseconds(plan.releaseTailMs))
                        silence()
                        cursor.phase = "gap"; try onCursor?(cursor)
                    }
                    let gap = cursor.index == 0 ? plan.pauseAfterScaleMs : plan.steps[cursor.index-1].pauseAfterMs
                    message = cursor.index == 0 ? "잠시 후 문제를 재생해요" : "필기 시간 · 다음 구간 준비"
                    if gap > 0 { try await Task.sleep(for: .milliseconds(gap)) }
                    cursor.index += 1; cursor.phase = "segment"; try onCursor?(cursor)
                }
                message = "모든 구간 재생 완료 · 필기를 마무리해 주세요"; isPlaying = false; engine.pause()
            } catch is CancellationError { }
            catch { pause(); onError?(error) }
        }
    }
    private func silence() {
        sequencer?.stop()
        sampler.sendController(120, withValue: 0, onChannel: 0)
        sampler.sendController(123, withValue: 0, onChannel: 0)

    }
    func pause() {
        runner?.cancel(); runner = nil; silence(); engine.pause(); isPlaying = false
        if prepared, cursor.index <= 11 { message = "일시 정지 · 현재 구간부터 계속할 수 있어요" }
    }
}
