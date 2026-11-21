import SwiftUI

@MainActor protocol EchoIntervalPlaying: AnyObject {
    func prepare() throws
    func noteOn(_ midi: Int)
    func noteOff(_ midi: Int)
    func silence()
    func stop()
}

// Reuse the verified piano graph without changing either other minigame.
@MainActor final class EchoIntervalPiano: EchoIntervalPlaying {
    private let piano = MelodyRunAudio()
    func prepare() throws { if !piano.ready || !piano.isRunning { try piano.prepare() } }
    func noteOn(_ midi: Int) { piano.noteOn(midi) }
    func noteOff(_ midi: Int) { piano.noteOff(midi) }
    func silence() { piano.releaseKeys() }
    func stop() { piano.stop() }
}

enum EchoIntervalPhase: Equatable {
    case idle, singing, waiting, answerPlayback, puzzled, happy, failed, completed
    var busy: Bool { self == .singing || self == .answerPlayback }
}

@MainActor final class EchoIntervalStageModel: ObservableObject {
    @Published private(set) var run: EchoIntervalRun
    @Published private(set) var phase: EchoIntervalPhase = .idle
    @Published private(set) var inputs: [Int] = []
    @Published private(set) var soundingNote: Int?
    @Published private(set) var startReminder = false
    @Published var error: String?
    private let audio: EchoIntervalPlaying
    private let noteDuration: Duration
    private let gapDuration: Duration
    private var playback: Task<Void,Never>?
    private var request = UUID()
    private var heard = false
    private var held: Int?
    init(stage: EchoIntervalStage, audio: EchoIntervalPlaying? = nil,
         noteDuration: Duration = .milliseconds(450), gapDuration: Duration = .milliseconds(160)) {
        run=EchoIntervalRun(stage:stage); self.audio=audio ?? EchoIntervalPiano()
        self.noteDuration=noteDuration; self.gapDuration=gapDuration
    }
    var canEnter: Bool { heard && (phase == .waiting || phase == .puzzled) && !run.failed && !run.complete }
    var canListen: Bool { !phase.busy && !run.failed && !run.complete && !run.solved[run.index] }
    var canSubmit: Bool { canEnter && inputs.count == 2 }
    func listen() {
        guard canListen else { return }
        inputs=[]; startReminder=false
        play(run.question.call,answer:false)
    }
    func keyDown(_ midi: Int) {
        // One physical key at a time: simultaneous fingers are not a two-note answer.
        guard canEnter, held == nil, inputs.count < 2, run.question.keyboardRange.contains(midi) else { return }
        if inputs.isEmpty && midi != run.question.replyStart { startReminder=true; return }
        do { try audio.prepare() }
        catch { self.error=error.localizedDescription; return }
        held=midi; audio.noteOn(midi); inputs.append(midi); startReminder=false; phase = .waiting
    }
    func keyUp(_ midi: Int) {
        guard held == midi else { return }
        audio.noteOff(midi); held=nil
    }
    func undo() {
        guard canEnter, !inputs.isEmpty else { return }
        audio.silence(); held=nil; inputs.removeLast(); startReminder=false
    }
    func submit() {
        guard canSubmit else { return }
        play(inputs,answer:true)
    }
    func next() {
        guard phase == .happy else { return }
        run.advance(); inputs=[]; heard=false; phase = .idle; startReminder=false
        listen()
    }
    private func play(_ notes: [Int], answer: Bool) {
        cancelPlayback(); let id=request
        phase = answer ? .answerPlayback : .singing
        playback=Task {
            defer {
                if request == id { soundingNote=nil; audio.silence(); playback=nil }
            }
            do {
                try audio.prepare()
                for (index,note) in notes.enumerated() {
                    try Task.checkCancellation()
                    soundingNote=note; audio.noteOn(note)
                    try await Task.sleep(for:noteDuration)
                    try Task.checkCancellation()
                    audio.noteOff(note); soundingNote=nil
                    if index+1 < notes.count { try await Task.sleep(for:gapDuration) }
                }
                try Task.checkCancellation()
                guard request == id else { return }
                if answer {
                    guard let correct=run.grade(notes) else { phase = .waiting; return }
                    if run.failed { phase = .failed }
                    else if run.complete { phase = .completed }
                    else { phase = correct ? .happy : .puzzled }
                    if !correct { inputs=[] }
                } else { heard=true; phase = .waiting }
            } catch is CancellationError { }
            catch {
                if request == id { self.error=error.localizedDescription; phase = .idle }
            }
        }
    }
    private func cancelPlayback() {
        request=UUID(); playback?.cancel(); playback=nil
        audio.silence(); held=nil; soundingNote=nil
    }
    // Cancellation before the second note ends never grades or consumes a heart.
    func suspend() {
        let wasBusy=phase.busy
        cancelPlayback(); audio.stop()
        if wasBusy { heard=false; phase = .idle }
    }
    func resume() { if phase == .idle && error == nil { listen() } }
}
