import AVFoundation

// A4 pitch and non-zero RMS alone also accept the sampler's default sine wave.
// Inspect the actual rendered production path, including its repeated plays.
final class PianoTimbreProbe: @unchecked Sendable {
    private let lock=NSLock()
    private var samples: [Float]=[]
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel=buffer.floatChannelData?[0] else { return }
        let values=Array(UnsafeBufferPointer(start:channel,count:Int(buffer.frameLength)))
        lock.lock(); defer { lock.unlock() }
        if samples.count<480000 { samples.append(contentsOf:values) }
    }
    func reset() { lock.lock(); defer { lock.unlock() }; samples.removeAll(keepingCapacity:true) }
    func snapshot() -> [Float] { lock.lock(); defer { lock.unlock() }; return samples }
    func waitForNote(rate: Double, timeout: TimeInterval = 8) async throws -> [Float]? {
        let deadline=ProcessInfo.processInfo.systemUptime+timeout
        while ProcessInfo.processInfo.systemUptime<deadline {
            if let window=Self.firstNoteWindow(in:snapshot(),rate:rate) { return window }
            try await Task.sleep(for:.milliseconds(20))
        }
        return nil
    }
    // Inspect the same early sustain on each play, regardless of render latency.
    // A piano's late release loses harmonics and must not be mistaken for a sine.
    // Require silence before onset so a queued buffer from the previous play
    // cannot supply the evidence for a broken replay.
    static func firstNoteWindow(in values: [Float], rate: Double) -> [Float]? {
        guard rate.isFinite, (8000...192000).contains(rate) else { return nil }
        let quietFrames=Int(rate*0.02), offset=Int(rate*0.04), count=8192
        var quiet=0
        for (index,value) in values.enumerated() {
            if abs(value)<0.0001 { quiet+=1; continue }
            if quiet>=quietFrames {
                let start=index+offset
                guard values.count>=start+count else { return nil }
                return Array(values[start..<start+count])
            }
            quiet=0
        }
        return nil
    }
    static func rms(_ values: [Float]) -> Double {
        sqrt(values.reduce(0) { $0+Double($1)*Double($1) }/Double(max(1,values.count)))
    }
    static func power(_ values: [Float], hz: Double, rate: Double) -> Double {
        var real=0.0, imaginary=0.0
        for (index,value) in values.enumerated() {
            let phase=2*Double.pi*hz*Double(index)/rate
            real+=Double(value)*cos(phase); imaginary+=Double(value)*sin(phase)
        }
        return real*real+imaginary*imaginary
    }
    static func harmonicFraction(_ values: [Float], rate: Double) -> Double {
        guard values.count>=2048, rate>0 else { return 0 }
        let input=Array(values.suffix(8192))
        let window=input.enumerated().map { index,value in
            Double(value)*0.5*(1-cos(2*Double.pi*Double(index)/Double(input.count-1)))
        }
        // Small frequency bands allow for sample tuning and stretched piano harmonics.
        func band(_ harmonic: Int) -> Double {
            [-8.0,-4,0,4,8].reduce(0) { sum,offset in
                let coefficient=2*cos(2*Double.pi*(440*Double(harmonic)+offset)/rate)
                var first=0.0, second=0.0
                for value in window {
                    let next=value+coefficient*first-second; second=first; first=next
                }
                return sum+max(0,first*first+second*second-coefficient*first*second)
            }
        }
        let fundamental=band(1), harmonics=(2...6).reduce(0) { $0+band($1) }
        return harmonics/max(1e-20,fundamental+harmonics)
    }
}
