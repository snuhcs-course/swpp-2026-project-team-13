import SwiftUI

// Literal two-note imitation. The displayed piano and audible MIDI numbers are
// shared with Memory run; the given first note is a cue, never an automatic answer.
@MainActor final class EchoFollowModel: ObservableObject {
    @Published private(set) var inputs: [Int] = []
    @Published private(set) var playing = false
    @Published private(set) var heard = false
    @Published private(set) var result: DrillRoundResult?
    @Published private(set) var attempts = 0
    @Published private(set) var message = ""
    @Published var error: String?
    let notes: [Int]
    let audio: MelodyRunAudio
    private var task: Task<Void,Never>?
    private var request = UUID()
    private var sounding = false
    init(question: DrillStageQuestion, audio: MelodyRunAudio) { notes=question.notes ?? []; self.audio=audio }
    var range: ClosedRange<Int> {
        let low=max(21,((notes.min() ?? 60)/12)*12)
        return low...min(108,max(low+12,(((notes.max() ?? 72)+11)/12)*12))
    }
    var canEnter: Bool { heard && !playing && result == nil }
    func listen() {
        stop(); let id=request; playing=true; sounding=true
        task=Task {
            defer { if request==id { playing=false; task=nil; audio.releaseKeys(); sounding=false } }
            do {
                guard notes.count==2 else { throw SolfegeError.invalidScore("두 음 문제를 확인해 주세요.") }
                if !audio.ready || !audio.isRunning { try audio.prepare() }
                for note in notes {
                    try Task.checkCancellation()
                    audio.noteOn(note)
                    try await Task.sleep(for:.milliseconds(500))
                    audio.noteOff(note)
                    try await Task.sleep(for:.milliseconds(180))
                }
                try Task.checkCancellation(); if request==id { heard=true }
            } catch is CancellationError { }
            catch { self.error=error.localizedDescription }
        }
    }
    func keyDown(_ midi: Int) {
        guard canEnter, inputs.count<2, range.contains(midi) else { return }
        do { if !audio.ready || !audio.isRunning { try audio.prepare() } }
        catch { self.error=error.localizedDescription; return }
        audio.noteOn(midi); sounding=true; inputs.append(midi); message=""
    }
    func keyUp(_ midi: Int) { audio.noteOff(midi) }
    func undo() { guard canEnter else { return }; audio.releaseKeys(); if !inputs.isEmpty { inputs.removeLast() }; message="" }
    func submit() {
        guard canEnter, inputs.count==2 else { return }
        attempts+=1; audio.releaseKeys(); sounding=false
        if inputs==notes { result=DrillRoundResult(accuracy:100,revealed:false,elapsedMs:0); message="정확해요!" }
        else if attempts>=3 { reveal() }
        else {
            message=attempts==1 ? "들은 두 음과 달라요. 다시 들어보세요." : "두 번째 음이 첫 음보다 " + (notes[1]>notes[0] ? "높은지 들어보세요." : notes[1]<notes[0] ? "낮은지 들어보세요." : "같은지 들어보세요.")
            inputs=[]
        }
    }
    func reveal() {
        guard result == nil else { return }
        result=DrillRoundResult(accuracy:zip(inputs,notes).filter { $0.0 == $0.1 }.count*50,revealed:true,elapsedMs:0)
        message="정답을 듣고 두 음을 비교해 보세요."
        listen()
    }
    func stop() {
        request=UUID(); task?.cancel(); task=nil; playing=false
        if sounding { audio.releaseKeys(); audio.stopClock(); sounding=false }
    }
    func suspend() { stop(); heard=false }
}
