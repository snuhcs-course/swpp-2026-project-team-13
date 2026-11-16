import AVFoundation
import Combine

// One prepared sequence per score/tempo. Switching ranges only seeks; it never
// reloads MIDI or replaces a sequencer while the graph is rendering.
@MainActor final class PracticeReviewPlayback: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published private(set) var measure: Int?
    @Published private(set) var range: PracticeReviewRange?
    private let graph = PianoAudioGraph()
    private var sequencer: AVAudioSequencer?
    private var runner: Task<Void,Never>?
    private var generation = UUID()
    private var preparedVoice: String?
    private struct Instrument {
        var url: URL; var program: UInt8; var msb: UInt8; var lsb: UInt8; var gain: Float
    }
    private var instrument: Instrument?
    private var preparedScore: MusicScore?
    private var preparedBpm: Double?
    private var arrangement: PracticeReviewSequence?
    private var activeSlice: PracticeReviewSequence.Slice?
    private var velocity = 80

    var positionSeconds: TimeInterval {
        guard let seq = sequencer, let slice = activeSlice, let bpm = preparedBpm else { return 0 }
        return max(0,(seq.currentPositionInBeats*480-Double(slice.musicStart))/480*60/bpm)
    }
    func play(score: MusicScore, range: PracticeReviewRange = .full, bpm: Double, voice: String) async throws {
        cancelMonitor(); silence(); activeSlice = nil
        let request = generation
        self.range = range; measure = range.from; isPaused = false; isPlaying = true
        // Let the button update before first-use instrument preparation.
        await Task.yield()
        do {
            try check(request)
            if preparedScore != score || preparedBpm != bpm || preparedVoice != voice || !graph.engine.isRunning {
                try prepare(score:score,bpm:bpm,voice:voice)
            }
            try check(request)
            guard let seq = sequencer, let slice = arrangement?.slice(for:range) else {
                throw SolfegeError.invalidScore("재생할 마디를 확인해 주세요.")
            }
            activeSlice = slice
            seq.currentPositionInBeats = Double(slice.start)/480
            seq.prepareToPlay(); try seq.start()
            monitor(request)
        } catch {
            if request == generation { stop() }
            throw error
        }
    }
    func pause() {
        guard isPlaying else { return }
        isPlaying = false; isPaused = activeSlice != nil
        cancelMonitor(); silence()
    }
    func resume() async throws {
        guard isPaused, let seq = sequencer, activeSlice != nil else { return }
        cancelMonitor(); let request = generation
        isPaused = false; isPlaying = true
        await Task.yield()
        do {
            try check(request)
            if !graph.engine.isRunning { try graph.engine.start() }
            seq.prepareToPlay(); try seq.start(); monitor(request)
        } catch {
            if request == generation { stop() }
            throw error
        }
    }
    // Stop returns to the chosen range's beginning and keeps prepared music.
    func stop() {
        isPlaying = false; isPaused = false
        cancelMonitor(); silence(); measure = nil
        if let slice = activeSlice { sequencer?.currentPositionInBeats = Double(slice.start)/480 }
    }
    func shutdown() {
        stop(); graph.engine.stop(); sequencer = nil
        preparedVoice = nil; instrument = nil; preparedScore = nil; preparedBpm = nil; arrangement = nil; activeSlice = nil
    }
    private func check(_ request: UUID) throws {
        try Task.checkCancellation()
        guard generation == request else { throw CancellationError() }
    }
    private func cancelMonitor() { generation = UUID(); runner?.cancel(); runner = nil }
    private func silence() {
        sequencer?.stop()
        graph.piano.sendController(120,withValue:0,onChannel:0)
        graph.piano.sendController(123,withValue:0,onChannel:0)
    }
    private func monitor(_ request: UUID) {
        guard let seq = sequencer, let slice = activeSlice, let score = preparedScore, let bpm = preparedBpm else { return }
        let left = max(0,Double(slice.end)/480-seq.currentPositionInBeats)*60/bpm
        let deadline = ProcessInfo.processInfo.systemUptime+left+0.2
        runner = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.milliseconds(20)) } catch { return }
                guard let self, self.generation == request, self.isPlaying, let current = self.sequencer else { return }
                let tick = Int(current.currentPositionInBeats*480)
                if tick >= slice.end || !current.isPlaying || ProcessInfo.processInfo.systemUptime >= deadline { self.stop(); return }
                let next = min(slice.range.through,slice.range.from+max(0,tick-slice.musicStart)/score.ticksPerMeasure)
                if self.measure != next { self.measure = next }
            }
        }
    }
    private func prepare(score: MusicScore, bpm: Double, voice: String) throws {
        let music = try PracticeReviewSequence(score:score,bpm:bpm)
        silence(); sequencer = nil; graph.engine.stop()
        preparedScore = nil; preparedBpm = nil
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback,mode:.default,options:[]); try audio.setActive(true)
        if preparedVoice != voice || instrument == nil {
            let url: URL, program: UInt8, msb: UInt8, lsb: UInt8, gain: Float
            if voice == "grand-piano" {
                let profile = try ClassicalPiano.load()
                url = profile.url; program = profile.program; msb = profile.bankMsb; lsb = profile.bankLsb
                gain = pow(10,profile.gainDb/20); velocity = Int(profile.noteVelocity)
            } else {
                struct Bank: Decodable { var sha256: String; var sizeBytes: Int }
                let choices: InstrumentChoices = try Bundled.decode("instruments")
                let bank: Bank = try Bundled.decode("instrument-bank")
                guard let choice = choices.voices.first(where: { $0.id == voice }),
                      let resource = Bundle.main.url(forResource:"GeneralUser-GS",withExtension:"sf2") else {
                    throw SolfegeError.invalidScore("선택한 악기의 음원이 없습니다.")
                }
                let bytes = try Data(contentsOf:resource,options:.mappedIfSafe)
                guard bytes.count == bank.sizeBytes, bytes.sha256 == bank.sha256 else { throw SolfegeError.invalidScore("악기 음원을 확인해 주세요.") }
                url = resource; program = choice.program; msb = 121; lsb = 0; gain = pow(10,choice.gainDb/20); velocity = 80
            }
            instrument = Instrument(url:url,program:program,msb:msb,lsb:lsb,gain:gain)
            preparedVoice = voice
        }
        guard let instrument else { throw SolfegeError.invalidScore("악기 음원을 준비해 주세요.") }
        // A different score/tempo gets a clean graph. Ordinary seeks, pauses and
        // stops above keep this graph alive, so bar taps never reload the bank.
        try graph.rebuild(bank:instrument.url,program:instrument.program,bankMSB:instrument.msb,bankLSB:instrument.lsb,clickURL:nil,gain:instrument.gain)
        let seq = AVAudioSequencer(audioEngine:graph.engine)
        try seq.load(from:MIDIFile.make(events:music.events,totalTicks:music.ticks,tempo:bpm,velocity:velocity),options:[])
        for track in seq.tracks { track.destinationAudioUnit = graph.piano }
        seq.rate = 1
        sequencer = seq; arrangement = music; preparedScore = score; preparedBpm = bpm
        try graph.engine.start()
    }
    func configurationChanged(_ notification: Notification) {
        guard let engine = notification.object as? AVAudioEngine, engine === graph.engine, !engine.isRunning else { return }
        shutdown()
    }
}
