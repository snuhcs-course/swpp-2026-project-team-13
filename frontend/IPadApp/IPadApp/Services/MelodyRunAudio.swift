import AVFoundation

@MainActor final class MelodyRunAudio {
    private let graph: PianoAudioGraph
    private var livePiano = AVAudioUnitSampler()
    private var sequencer: AVAudioSequencer?
    private var referenceTrack: AVMusicTrack?
    private var held: [Int:Int] = [:]
    private var previousBufferDuration: TimeInterval?
    private var transportLeadTicks = 0
    private var noteVelocity: UInt8 = 76
    private(set) var ready = false
    init(graph: PianoAudioGraph = PianoAudioGraph()) { self.graph = graph }
    var tick: Int { Int(((sequencer?.currentPositionInBeats ?? 0)*480).rounded(.down))-transportLeadTicks }
    var isRunning: Bool { graph.engine.isRunning }

    func prepare() throws {
        if ready && graph.engine.isRunning { stopClock(); releaseKeys(); return }
        stop(); ready = false
        let profile = try ClassicalPiano.load()
        let bank = profile.url
        guard let click = Bundle.main.url(forResource:"sori-click-v1",withExtension:"wav") else {
            throw SolfegeError.invalidScore("피아노 음원이 포함된 최신 앱으로 다시 설치해 주세요.")
        }
        let session = AVAudioSession.sharedInstance()
        previousBufferDuration = session.preferredIOBufferDuration > 0 ? session.preferredIOBufferDuration : session.ioBufferDuration
        try session.setCategory(.playback,mode:.default,options:[])
        try session.setPreferredIOBufferDuration(0.0058)
        try session.setActive(true)
        noteVelocity = profile.noteVelocity
        try graph.rebuild(bank:bank,program:profile.program,bankMSB:profile.bankMsb,bankLSB:profile.bankLsb,clickURL:click,gain:pow(10,profile.gainDb/20))
        // Live keys have their own sampler: reference note-offs cannot silence a held key.
        livePiano = AVAudioUnitSampler()
        graph.engine.attach(livePiano)
        graph.engine.connect(livePiano,to:graph.engine.mainMixerNode,format:nil)
        try livePiano.loadSoundBankInstrument(at:bank,program:profile.program,bankMSB:profile.bankMsb,bankLSB:profile.bankLsb)
        graph.engine.prepare(); try graph.engine.start(); ready = true
    }

    func start(_ timeline: MelodyTimeline, round: MelodyRound, settings: MelodySettings) throws {
        stopClock()
        discardSequence()
        transportLeadTicks = MelodyTimeline.ticks(milliseconds:MelodyTimeline.audioLeadMilliseconds,bpm:settings.bpm)
        guard let first = timeline.windows.first(where: { $0.phase == .listen }) else {
            throw SolfegeError.invalidScore("게임 오디오 준비 실패")
        }
        let through = settings.mode == .memory ? round.score.measures : first.measure
        let events = try round.score.segment(from:first.measure,through:through).map {
            MusicEvent(midi:$0.midi,onset:$0.onset+first.start+transportLeadTicks,duration:$0.duration)
        }
        let length = timeline.end+transportLeadTicks
        let piano = MIDIFile.make(events:events,totalTicks:length,tempo:settings.bpm,velocity:Int(noteVelocity))
        let clicks = timeline.clickEvents(leadTicks:transportLeadTicks)
        var tracks = [piano]
        if !clicks.isEmpty {
            tracks.append(MIDIFile.make(events:clicks,totalTicks:length,tempo:settings.bpm,
                                        velocity:75,firstNoteVelocity:105,channel:1))
        }
        let seq = AVAudioSequencer(audioEngine:graph.engine)
        try seq.load(from:tracks.count == 1 ? piano : MIDIFile.combining(tracks),options:[])
        guard seq.tracks.count == tracks.count else { throw SolfegeError.invalidScore("게임 오디오 준비 실패") }
        // Piano is always track/channel 0; count-in is a separate track/channel.
        // Do not route every imported track to the click sampler, then append
        // a second channel-0 track: the audible reference must use the SF2 piano.
        seq.tracks[0].destinationAudioUnit = graph.piano
        if seq.tracks.count == 2 { seq.tracks[1].destinationAudioUnit = graph.click }
        referenceTrack = seq.tracks[0]; sequencer = seq
        graph.engine.prepare(); try graph.engine.start()
        seq.currentPositionInBeats = 0; seq.prepareToPlay(); try seq.start()
    }

    func schedule(_ window: MelodyWindow, round: MelodyRound) throws {
        let events = try round.score.segment(from:window.measure,through:window.measure)
        try schedule(events,at:window.start)
    }
    private func schedule(_ events: [MusicEvent], at start: Int) throws {
        guard let track = referenceTrack else { throw SolfegeError.invalidScore("게임 오디오가 준비되지 않았어요.") }
        for event in events {
            guard let midi = event.midi else { continue }
            let note = AVMIDINoteEvent(channel:0,key:UInt32(midi),velocity:UInt32(noteVelocity),duration:Double(event.duration)/480)
            track.addEvent(note,at:Double(start+event.onset+transportLeadTicks)/480)
        }
    }

    func noteOn(_ midi: Int) {
        guard ready, graph.engine.isRunning, (0...127).contains(midi) else { return }
        held[midi,default:0] += 1
        livePiano.startNote(UInt8(midi),withVelocity:noteVelocity,onChannel:0)
    }
    func noteOff(_ midi: Int) {
        guard let count = held[midi] else { return }
        if count > 1 { held[midi] = count-1 }
        else { held.removeValue(forKey:midi); livePiano.stopNote(UInt8(midi),onChannel:0) }
    }
    func releaseKeys() {
        held.removeAll()
        livePiano.sendController(120,withValue:0,onChannel:0)
        livePiano.sendController(123,withValue:0,onChannel:0)
    }
    func stopClock() {
        // Recall still needs the live keyboard. Keep the stopped sequence alive
        // until the engine is quiescent; sequencer.stop() only stops its player.
        sequencer?.stop()
        for unit in [graph.piano,graph.click] {
            unit.sendController(120,withValue:0,onChannel:0)
            unit.sendController(123,withValue:0,onChannel:0)
        }
    }
    private func discardSequence() {
        // AVAudioSequencer deinit detaches its MusicSequence from the engine.
        // Never let that race the engine's render thread (including on replay).
        graph.engine.stop()
        referenceTrack = nil; sequencer = nil; transportLeadTicks = 0
    }
    func stop() {
        stopClock(); releaseKeys(); discardSequence(); ready = false
        if let previous = previousBufferDuration, previous > 0 {
            try? AVAudioSession.sharedInstance().setPreferredIOBufferDuration(previous)
        }
        previousBufferDuration = nil
    }
    func owns(_ notification: Notification) -> Bool {
        guard let engine = notification.object as? AVAudioEngine else { return false }
        return engine === graph.engine
    }
    func replay(events: [MusicEvent], ticks: Int, bpm: Double) throws {
        stopClock(); releaseKeys()
        if !ready { try prepare() }
        discardSequence()
        transportLeadTicks = MelodyTimeline.ticks(milliseconds:MelodyTimeline.audioLeadMilliseconds,bpm:bpm)
        let seq = AVAudioSequencer(audioEngine:graph.engine)
        let shifted = events.map { MusicEvent(midi:$0.midi,onset:$0.onset+transportLeadTicks,duration:$0.duration) }
        try seq.load(from:MIDIFile.make(events:shifted,totalTicks:ticks+transportLeadTicks,tempo:bpm,velocity:Int(noteVelocity)),options:[])
        for track in seq.tracks { track.destinationAudioUnit = graph.piano }
        sequencer = seq
        graph.engine.prepare(); try graph.engine.start()
        seq.currentPositionInBeats = 0; seq.prepareToPlay(); try seq.start()
    }
}
