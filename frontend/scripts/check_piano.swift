import Foundation
import AVFoundation
import AudioToolbox

let path = CommandLine.arguments[1]
let engine = AVAudioEngine(), sampler = AVAudioUnitSampler()
engine.attach(sampler); engine.connect(sampler,to:engine.mainMixerNode,format:nil)
let format = AVAudioFormat(standardFormatWithSampleRate:44100,channels:2)!
try sampler.loadSoundBankInstrument(at:URL(fileURLWithPath:path),program:0,bankMSB:121,bankLSB:0)
try engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:4096)
try engine.start()
let buffer = AVAudioPCMBuffer(pcmFormat:engine.manualRenderingFormat,frameCapacity:4096)!
sampler.startNote(69,withVelocity:80,onChannel:0)
var frames:[Float]=[]
while frames.count < 44100 {
    let status=try engine.renderOffline(4096,to:buffer)
    if status == .success { frames += Array(UnsafeBufferPointer(start:buffer.floatChannelData![0],count:Int(buffer.frameLength))) }
}
sampler.stopNote(69,onChannel:0);engine.stop()
let peak=frames.map{abs($0)}.max()!
let samples=Array(frames[4410..<22050])
func power(_ hz:Double)->Double {
    var re=0.0,im=0.0
    for (i,sample) in samples.enumerated() { let phase=2*Double.pi*hz*Double(i)/44100;re+=Double(sample)*cos(phase);im+=Double(sample)*sin(phase) }
    return re*re+im*im
}
let detected=(420...460).max{power(Double($0))<power(Double($1))}!
guard peak > 0.0001, abs(detected-440)<=1 else { fatalError("Sound bank silent or mistuned: peak=\(peak), hz=\(detected)") }
print("PASS: SF2 loaded, non-silent MIDI 69, dominant fundamental \(detected) Hz, peak \(peak)")
