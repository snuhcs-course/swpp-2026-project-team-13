import Foundation
import AVFoundation
import AudioToolbox
import Darwin

struct AudioCheckFailure: LocalizedError {
    let message:String
    var errorDescription:String? { message }
}
func log(_ message:String) { FileHandle.standardOutput.write(Data((message+"\n").utf8)) }
let resources = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).standardizedFileURL
let graph = PianoAudioGraph()
let format = AVAudioFormat(standardFormatWithSampleRate:44100,channels:2)!
let clickURL = resources.appendingPathComponent("sori-click-v1.wav")

func render(_ unit:AVAudioUnitSampler,note:UInt8) throws -> [Float] {
    if !graph.engine.isRunning { try graph.engine.start() }
    let buffer = AVAudioPCMBuffer(pcmFormat:graph.engine.manualRenderingFormat,frameCapacity:4096)!
    unit.startNote(note,withVelocity:100,onChannel:0)
    var samples:[Float]=[]
    var attempts=0
    while samples.count < 22050 && attempts < 200 {
        attempts += 1
        let status=try graph.engine.renderOffline(4096,to:buffer)
        if status == .success {
            samples += Array(UnsafeBufferPointer(start:buffer.floatChannelData![0],count:Int(buffer.frameLength)))
        } else if status == .error { throw AudioCheckFailure(message:"Offline audio rendering failed") }
    }
    unit.stopNote(note,onChannel:0)
    guard samples.count >= 22050, samples.allSatisfy({ $0.isFinite }),
          samples.map({abs($0)}).max()! > 0.0001 else { throw AudioCheckFailure(message:"Audio graph produced silence") }
    return samples
}
func power(_ values:[Float],_ hz:Double)->Double {
    var re=0.0,im=0.0
    for (i,value) in values.enumerated() {
        let phase=2*Double.pi*hz*Double(i)/44100
        re += Double(value)*cos(phase); im += Double(value)*sin(phase)
    }
    return re*re+im*im
}
do {
    for (index,bankName) in ["sori-piano-v2","sori-piano-v2","sori-piano-v1","sori-piano-v2"].enumerated() {
        // The same graph object crosses pause, stop, another instrument and a fresh problem.
        if index % 2 == 0 { graph.engine.stop() } else { graph.engine.pause() }
        log("CHECK rebuild \(index+1): \(bankName), click \(clickURL.lastPathComponent)")
        try graph.rebuild(bank:resources.appendingPathComponent(bankName+".sf2"),program:0,bankMSB:121,bankLSB:0,
                          clickURL:clickURL,gain:0.5,offlineFormat:format)
        let piano=try render(graph.piano,note:69)
        let window=Array(piano[4410..<22050])
        let detected=(435...445).max { power(window,Double($0)) < power(window,Double($1)) }!
        guard abs(detected-440) <= 1 else { throw AudioCheckFailure(message:"Piano tuning changed: \(detected) Hz") }
        graph.engine.pause()
        try graph.rebuild(bank:resources.appendingPathComponent(bankName+".sf2"),program:0,bankMSB:121,bankLSB:0,
                          clickURL:clickURL,gain:0.5,offlineFormat:format)
        _ = try render(graph.click,note:60)
        log("PASS actual app audio graph rebuild \(index+1): \(bankName), A4 \(detected) Hz and audible count-in")
    }
    graph.engine.stop()
} catch {
    graph.engine.stop()
    FileHandle.standardError.write(Data(("FAIL audio-check: "+error.localizedDescription+"\n").utf8))
    exit(1)
}
