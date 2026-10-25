import Foundation
import AVFoundation

// Shared by iPad playback and the macOS offline audio regression check.
final class PianoAudioGraph {
    private(set) var engine = AVAudioEngine()
    private(set) var piano = AVAudioUnitSampler()
    private(set) var click = AVAudioUnitSampler()

    func rebuild(bank: URL, program: UInt8, bankMSB: UInt8, bankLSB: UInt8,
                 clickURL: URL?, gain: Float, offlineFormat: AVAudioFormat? = nil) throws {
        engine.stop()
        engine = AVAudioEngine()
        piano = AVAudioUnitSampler()
        click = AVAudioUnitSampler()
        engine.attach(piano)
        engine.attach(click)
        engine.connect(piano,to:engine.mainMixerNode,format:nil)
        engine.connect(click,to:engine.mainMixerNode,format:nil)
        try piano.loadSoundBankInstrument(at:bank,program:program,bankMSB:bankMSB,bankLSB:bankLSB)
        if let clickURL { try click.loadAudioFiles(at:[clickURL]) }
        engine.mainMixerNode.outputVolume = gain
        if let offlineFormat {
            try engine.enableManualRenderingMode(.offline,format:offlineFormat,maximumFrameCount:4096)
        }
        engine.prepare()
    }
}
