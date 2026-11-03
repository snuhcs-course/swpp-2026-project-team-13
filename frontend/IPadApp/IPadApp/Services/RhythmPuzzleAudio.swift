import AVFoundation

@MainActor final class RhythmPuzzleAudio {
    private let graph = PianoAudioGraph()
    private var sequencer: AVAudioSequencer?
    private var ready = false
    private var profile: ClassicalPiano?
    private(set) var endTick = 0
    var tick: Int { Int(((sequencer?.currentPositionInBeats ?? 0)*480).rounded(.down)) }
    var running: Bool { graph.engine.isRunning }
    func owns(_ notification: Notification) -> Bool { (notification.object as? AVAudioEngine) === graph.engine }
    func play(_ round: RhythmRound, reference: Bool = false) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback,mode:.default,options:[]); try session.setActive(true)
        let selected = try profile ?? ClassicalPiano.load()
        profile = selected
        if !ready || !graph.engine.isRunning {
            guard let click = Bundle.main.url(forResource:"sori-click-v1",withExtension:"wav") else { throw SORIError.invalidScore("예비박 음원이 없어요.") }
            try graph.rebuild(bank:selected.url,program:selected.program,bankMSB:selected.bankMsb,bankLSB:selected.bankLsb,clickURL:click,gain:pow(10,selected.gainDb/20))
            try graph.engine.start(); ready = true
        }
        let count = CountInPlayback(measures:1,beforeStepOrders:[1],beatsPerMeasure:round.meter.numerator,beatUnit:round.meter.denominator,
                                    accentVelocity:110,velocity:70,profileId:"sori-click-v1")
        let notes = reference ? round.rhythm.map { RhythmNote(onset:$0.onset,duration:$0.duration,midi:72) } : round.audio
        // Both count-in and melody share the same sequencer; the beat joins exactly.
        let events = try notes.map { n -> MusicEvent in
            guard let start = n.onset.ticks, let duration = n.duration.ticks else { throw SORIError.invalidScore("정확히 재생할 수 없는 리듬 길이입니다.") }
            return MusicEvent(midi:n.midi,onset:start,duration:duration)
        }
        guard let total = round.totalDuration.ticks else { throw SORIError.invalidScore("리듬 길이를 확인해 주세요.") }
        let data = MIDIFile.withCountIn(events:events,totalTicks:total,tempo:round.tempoBpm,countIn:count,velocity:Int(selected.noteVelocity))
        let seq = AVAudioSequencer(audioEngine:graph.engine)
        try seq.load(from:data,options:[])
        guard seq.tracks.count == 2 else { throw SORIError.invalidScore("리듬 재생 트랙을 확인해 주세요.") }
        for (i,track) in seq.tracks.enumerated() { track.destinationAudioUnit = i == 0 ? graph.piano : graph.click }
        endTick = count.totalTicks+total
        sequencer = seq; seq.currentPositionInBeats = 0; seq.prepareToPlay(); try seq.start()
    }
    func stop() {
        sequencer?.stop(); sequencer = nil
        for unit in [graph.piano,graph.click] { unit.sendController(120,withValue:0,onChannel:0); unit.sendController(123,withValue:0,onChannel:0) }
    }
    func invalidate() { stop(); graph.engine.stop(); ready = false }
    func shutdown() { invalidate() }
}
