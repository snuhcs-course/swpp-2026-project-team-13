import AVFoundation

@MainActor protocol EchoDragonPlaying: AnyObject {
    func prepare() throws
    func note(_ midi: Int) async throws
    func pair(_ first: Int, _ second: Int) async throws
    func silence()
    func stop()
    func needsRecovery(_ notification: Notification) -> Bool
}

@MainActor final class EchoDragonAudio: EchoDragonPlaying {
    private let graph = PianoAudioGraph()
    private var ready = false
    private var velocity: UInt8 = 76

    func prepare() throws {
        if ready && graph.engine.isRunning { return }
        let profile = try ClassicalPiano.load()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback,mode:.default,options:[])
        try session.setActive(true)
        try graph.rebuild(bank:profile.url,program:profile.program,bankMSB:profile.bankMsb,
                          bankLSB:profile.bankLsb,clickURL:nil,gain:pow(10,profile.gainDb/20))
        velocity = profile.noteVelocity
        try graph.engine.start()
        ready = true
    }
    func note(_ midi: Int) async throws {
        try Task.checkCancellation()
        graph.piano.startNote(UInt8(midi),withVelocity:velocity,onChannel:0)
        try await Task.sleep(for:.milliseconds(450))
        try Task.checkCancellation()
        graph.piano.stopNote(UInt8(midi),onChannel:0)
        try await Task.sleep(for:.milliseconds(180))
    }
    func pair(_ first: Int, _ second: Int) async throws {
        try await note(first)
        try await note(second)
    }
    func silence() {
        graph.piano.sendController(120,withValue:0,onChannel:0)
        graph.piano.sendController(123,withValue:0,onChannel:0)
    }
    func stop() { silence(); graph.engine.stop(); ready = false }
    func needsRecovery(_ notification: Notification) -> Bool {
        (notification.object as? AVAudioEngine) === graph.engine && !graph.engine.isRunning
    }
}
