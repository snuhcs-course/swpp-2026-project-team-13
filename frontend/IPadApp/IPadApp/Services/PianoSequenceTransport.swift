import AVFoundation

// One sequence for the lifetime of one prepared sampler graph. Replacing an
// AVAudioSequencer requires stopping its engine before MusicSequence disposal;
// restarting that engine without restoring the samples can lose the piano.
// Editing stopped tracks avoids both that lifecycle race and implicit MIDI
// import destinations. Only full shutdown/recovery releases this object.
@MainActor final class PianoSequenceTransport {
    private let engine: AVAudioEngine
    let sequencer: AVAudioSequencer
    let pianoTrack: AVMusicTrack
    private let clickTrack: AVMusicTrack
    private var previousEnd = 0.0
    init(graph: PianoAudioGraph) {
        engine=graph.engine
        let player=AVAudioSequencer(audioEngine:graph.engine)
        sequencer=player
        pianoTrack=player.createAndAppendTrack()
        clickTrack=player.createAndAppendTrack()
        pianoTrack.destinationAudioUnit=graph.piano
        clickTrack.destinationAudioUnit=graph.click
        pianoTrack.isLoopingEnabled=false; clickTrack.isLoopingEnabled=false
    }
    func configure(piano: [MusicEvent], clicks: [MusicEvent], totalTicks: Int, bpm: Double,
                   pianoVelocity: UInt8, clickVelocity: UInt8 = 75, accentVelocity: UInt8 = 105) throws {
        guard totalTicks>0, bpm.isFinite, bpm>0,
              (piano+clicks).allSatisfy({ e in
                  e.onset>=0 && e.duration>0 && e.onset<=totalTicks && e.duration<=totalTicks-e.onset &&
                  (e.midi.map { (0...127).contains($0) } ?? true)
              }) else { throw SolfegeError.invalidScore("재생할 음표의 길이와 템포를 확인해 주세요.") }
        sequencer.stop()
        // Remove through the documented iterator flag, including empty tracks.
        // The third pointer means removeEvent, NOT stop enumeration. Do not
        // subsequently MusicTrackClear an already-empty track (Core Audio -50).
        let previousRange=AVBeatRange(start:0,length:max(1,previousEnd+1))
        for track in [pianoTrack,clickTrack,sequencer.tempoTrack] {
            track.enumerateEvents(in:previousRange) { _,_,removeEvent in removeEvent.pointee=true }
        }
        sequencer.tempoTrack.addEvent(AVExtendedTempoEvent(tempo:bpm),at:0)
        append(piano,to:pianoTrack,velocity:pianoVelocity)
        let first=clicks.filter { $0.midi != nil }.map(\.onset).min()
        for event in clicks {
            append([event],to:clickTrack,velocity:event.onset == first ? accentVelocity : clickVelocity)
        }
        let beats=Double(totalTicks)/480
        for track in [pianoTrack,clickTrack] { track.lengthInBeats=beats }
        previousEnd=beats
        sequencer.rate=1; sequencer.currentPositionInBeats=0
        sequencer.prepareToPlay()
    }
    private func append(_ events: [MusicEvent], to track: AVMusicTrack, velocity: UInt8) {
        for event in events {
            guard let midi=event.midi else { continue }
            let note=AVMIDINoteEvent(channel:0,key:UInt32(midi),velocity:UInt32(velocity),duration:Double(event.duration)/480)
            track.addEvent(note,at:Double(event.onset)/480)
        }
    }
    func start() throws { try sequencer.start() }
    // A view/model can disappear after pause without calling full shutdown.
    // Stop this exact engine before stored properties release MusicSequence;
    // its render callback must never outlive the sequence it references.
    deinit { engine.stop() }
}
