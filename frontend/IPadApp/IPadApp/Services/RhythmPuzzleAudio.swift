import AVFoundation

@MainActor final class RhythmPuzzleAudio {
    private let graph: PianoAudioGraph
    private var transport: PianoSequenceTransport?
    private var sequencer: AVAudioSequencer? { transport?.sequencer }
    private var ready = false
    private var profile: ClassicalPiano?
    private var audioLeadTicks = 0
    init(graph: PianoAudioGraph = PianoAudioGraph()) { self.graph=graph }
    private(set) var endTick = 0
    var tick: Int { Int(((sequencer?.currentPositionInBeats ?? 0)*480).rounded(.down))-audioLeadTicks }
    var running: Bool { graph.engine.isRunning }
    func owns(_ notification: Notification) -> Bool { (notification.object as? AVAudioEngine) === graph.engine }
    func prepare() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback,mode:.default,options:[]); try session.setActive(true)
        let selected = try profile ?? ClassicalPiano.load()
        profile = selected
        if !ready {
            invalidate()
            guard let click = Bundle.main.url(forResource:"sori-click-v1",withExtension:"wav") else { throw SolfegeError.invalidScore("예비박 음원이 없어요.") }
            try graph.rebuild(bank:selected.url,program:selected.program,bankMSB:selected.bankMsb,bankLSB:selected.bankLsb,clickURL:click,gain:pow(10,selected.gainDb/20))
            transport=PianoSequenceTransport(graph:graph)
            try graph.engine.start(); ready = true
        }
    }
    func play(_ round: RhythmRound, reference: Bool = false, includeCountIn: Bool = true) throws {
        stop(); try prepare()
        guard let selected = profile else { throw SolfegeError.invalidScore("피아노 음원을 준비하지 못했어요.") }
        let count = CountInPlayback(measures:1,beforeStepOrders:[1],beatsPerMeasure:round.meter.numerator,beatUnit:round.meter.denominator,
                                    accentVelocity:110,velocity:70,profileId:"sori-click-v1")
        let notes = round.audio
        // Both count-in and melody share the same sequencer; the beat joins exactly.
        let events = try notes.map { n -> MusicEvent in
            guard let start = n.onset.ticks, let duration = n.duration.ticks else { throw SolfegeError.invalidScore("정확히 재생할 수 없는 리듬 길이입니다.") }
            return MusicEvent(midi:n.midi,onset:start,duration:duration)
        }
        guard let total = round.totalDuration.ticks else { throw SolfegeError.invalidScore("리듬 길이를 확인해 주세요.") }
        let countIn = includeCountIn && !reference
        let prefix=countIn ? count.totalTicks : 0
        // Match Memory's short scheduling lead. A zero-time note can be lost
        // while hardware resumes after a paused edit, especially without a
        // count-in. Shift both tracks together; keep the board's clock logical.
        audioLeadTicks=MelodyTimeline.ticks(milliseconds:MelodyTimeline.audioLeadMilliseconds,bpm:round.tempoBpm)
        let shifted=events.map { MusicEvent(midi:$0.midi,onset:$0.onset+prefix+audioLeadTicks,duration:$0.duration) }
        let clicks: [MusicEvent] = countIn ? (0..<(count.measures*count.beatsPerMeasure)).map {
            MusicEvent(midi:60,onset:$0*count.ticksPerBeat+audioLeadTicks,duration:min(40,count.ticksPerBeat))
        } : []
        guard let transport else { throw SolfegeError.invalidScore("리듬 재생기를 준비하지 못했어요.") }
        endTick=prefix+total
        try transport.configure(piano:shifted,clicks:clicks,totalTicks:endTick+audioLeadTicks,bpm:round.tempoBpm,
                                pianoVelocity:selected.noteVelocity,clickVelocity:UInt8(count.velocity),accentVelocity:UInt8(count.accentVelocity))
        try transport.start()
    }
    func stop() {
        transport?.stop()
        for unit in [graph.piano,graph.click] { unit.sendController(120,withValue:0,onChannel:0); unit.sendController(123,withValue:0,onChannel:0) }
    }
    func invalidate() { graph.engine.stop(); stop(); transport = nil; ready = false; audioLeadTicks = 0 }
    func shutdown() { invalidate() }
}
