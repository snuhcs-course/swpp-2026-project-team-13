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
        try load(bank,label:"피아노") {
            try piano.loadSoundBankInstrument(at:bank,program:program,bankMSB:bankMSB,bankLSB:bankLSB)
        }
        if let clickURL {
            try load(clickURL,label:"예비박") { try click.loadAudioFiles(at:[clickURL]) }
        }
        engine.mainMixerNode.outputVolume = gain
        if let offlineFormat {
            try engine.enableManualRenderingMode(.offline,format:offlineFormat,maximumFrameCount:4096)
        }
        engine.prepare()
    }
    private func load(_ file:URL,label:String,operation:() throws -> Void) throws {
        do { try operation() }
        catch {
            let cause=error as NSError
            throw NSError(domain:"SORI.AudioGraph",code:cause.code,userInfo:[
                NSLocalizedDescriptionKey:"\(label) 음원을 불러오지 못했습니다. \(file.lastPathComponent) (\(cause.domain) \(cause.code))",
                NSUnderlyingErrorKey:cause
            ])
        }
    }

}
