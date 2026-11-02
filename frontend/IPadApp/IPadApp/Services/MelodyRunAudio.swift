import AVFoundation

@MainActor final class MelodyRunAudio {
    private let graph = PianoAudioGraph()
    private var livePiano = AVAudioUnitSampler()
    private var sequencer: AVAudioSequencer?
    private var referenceTrack: AVMusicTrack?
    private var held: [Int:Int] = [:]
    private var previousBufferDuration: TimeInterval?
    private var transportLeadTicks = 0
    private var noteVelocity: UInt8 = 76
    private(set) var ready = false
    var tick: Int { Int(((sequencer?.currentPositionInBeats ?? 0)*480).rounded(.down))-transportLeadTicks }
    var isRunning: Bool { graph.engine.isRunning }

    func prepare() throws {
        stop(); ready = false
        let profile = try ClassicalPiano.load()
        let bank = profile.url
        guard let click = Bundle.main.url(forResource:"sori-click-v1",withExtension:"wav") else {
            throw SORIError.invalidScore("피아노 음원이 포함된 최신 앱으로 다시 설치해 주세요.")
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
        transportLeadTicks = MelodyTimeline.ticks(milliseconds:MelodyTimeline.audioLeadMilliseconds,bpm:settings.bpm)
        let seq = AVAudioSequencer(audioEngine:graph.engine)
        try seq.load(from:timeline.midi(tempo:settings.bpm,leadTicks:transportLeadTicks),options:[])
        guard !seq.tracks.isEmpty else { throw SORIError.invalidScore("게임 오디오 준비 실패") }
        for track in seq.tracks { track.destinationAudioUnit = graph.click }
        let reference = seq.createAndAppendTrack()
        reference.destinationAudioUnit = graph.piano
        reference.lengthInBeats = Double(timeline.end+transportLeadTicks)/480
        referenceTrack = reference
        sequencer = seq
        if settings.mode == .memory {
            for window in timeline.windows where window.phase == .listen { try schedule(window,round:round) }
        } else if let first = timeline.windows.first(where: { $0.phase == .listen }) {
            try schedule(first,round:round)
        }
        seq.currentPositionInBeats = 0; seq.prepareToPlay(); try seq.start()
    }

    func schedule(_ window: MelodyWindow, round: MelodyRound) throws {
        guard let track = referenceTrack else { throw SORIError.invalidScore("게임 오디오가 준비되지 않았어요.") }
        let events = try round.score.segment(from:window.measure,through:window.measure)
        for event in events {
            guard let midi = event.midi else { continue }
            let note = AVMIDINoteEvent(channel:0,key:UInt32(midi),velocity:UInt32(noteVelocity),duration:Double(event.duration)/480)
            track.addEvent(note,at:Double(window.start+event.onset+transportLeadTicks)/480)
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
        sequencer?.stop(); sequencer = nil; referenceTrack = nil; transportLeadTicks = 0
        for unit in [graph.piano,graph.click] {
            unit.sendController(120,withValue:0,onChannel:0)
            unit.sendController(123,withValue:0,onChannel:0)
        }
    }
    func stop() {
        stopClock(); releaseKeys(); graph.engine.stop(); ready = false
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
        transportLeadTicks = MelodyTimeline.ticks(milliseconds:MelodyTimeline.audioLeadMilliseconds,bpm:bpm)
        let seq = AVAudioSequencer(audioEngine:graph.engine)
        let shifted = events.map { MusicEvent(midi:$0.midi,onset:$0.onset+transportLeadTicks,duration:$0.duration) }
        try seq.load(from:MIDIFile.make(events:shifted,totalTicks:ticks+transportLeadTicks,tempo:bpm,velocity:Int(noteVelocity)),options:[])
        for track in seq.tracks { track.destinationAudioUnit = graph.piano }
        sequencer = seq; seq.currentPositionInBeats = 0; seq.prepareToPlay(); try seq.start()
    }
}
