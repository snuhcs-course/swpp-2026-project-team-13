import AVFoundation
import Combine

// Review playback owns its transport. It never advances or persists the exam cursor.
@MainActor final class PracticeReviewPlayback: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var measure: Int?
    private let graph = PianoAudioGraph()
    private var sequencer: AVAudioSequencer?
    private var runner: Task<Void,Never>?
    private var preparedVoice: String?
    private var velocity = 80

    func play(score: MusicScore, measure: Int? = nil, bpm: Double, voice: String) throws {
        let clip = try PracticeReviewClip.make(score:score,measure:measure,bpm:bpm)
        silence()
        if preparedVoice != voice || !graph.engine.isRunning { try prepare(voice:voice) }
        let seq = AVAudioSequencer(audioEngine:graph.engine)
        let lead = Int((bpm*480/60*0.12).rounded())
        let events = clip.events.map { MusicEvent(midi:$0.midi,onset:$0.onset+lead,duration:$0.duration) }
        try seq.load(from:MIDIFile.make(events:events,totalTicks:clip.ticks+lead,tempo:bpm,velocity:velocity),options:[])
        for track in seq.tracks { track.destinationAudioUnit = graph.piano }
        sequencer = seq; seq.currentPositionInBeats = 0; seq.prepareToPlay(); try seq.start()
        isPlaying = true; self.measure = measure ?? 1
        let started = ProcessInfo.processInfo.systemUptime
        let duration = Double(clip.ticks+lead)/480*60/bpm
        runner = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.milliseconds(40)) } catch { return }
                guard let self, self.sequencer === seq else { return }
                let tick = max(0,Int(seq.currentPositionInBeats*480)-lead)
                if tick >= clip.ticks || ProcessInfo.processInfo.systemUptime-started >= duration+0.1 { self.silence(); return }
                let next = measure ?? min(score.measures,tick/score.ticksPerMeasure+1)
                if self.measure != next { self.measure = next }
            }
        }
    }
    private func prepare(voice: String) throws {
        graph.engine.stop(); preparedVoice = nil
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback,mode:.default,options:[]); try audio.setActive(true)
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
            url = resource; program = choice.program; msb = 121; lsb = 0; gain = pow(10,choice.gainDb/20)
            velocity = 80
        }
        try graph.rebuild(bank:url,program:program,bankMSB:msb,bankLSB:lsb,clickURL:nil,gain:gain)
        try graph.engine.start(); preparedVoice = voice
    }
    private func silence() {
        runner?.cancel(); runner = nil; sequencer?.stop(); sequencer = nil
        graph.piano.sendController(120,withValue:0,onChannel:0)
        graph.piano.sendController(123,withValue:0,onChannel:0)
        isPlaying = false; measure = nil
    }
    func stop() { silence(); graph.engine.stop(); preparedVoice = nil }
    func configurationChanged(_ notification: Notification) {
        guard let engine = notification.object as? AVAudioEngine, engine === graph.engine, !engine.isRunning else { return }
        stop()
    }
}
