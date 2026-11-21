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
