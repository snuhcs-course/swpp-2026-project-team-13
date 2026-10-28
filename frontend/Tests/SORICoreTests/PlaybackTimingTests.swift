import XCTest
@testable import SORICore

final class PlaybackTimingTests: XCTestCase {
    // Read the actual MIDI event times, rather than reusing the count-in generator.
    func notes(_ data:Data) throws -> [[(tick:Int, midi:Int, velocity:Int)]] {
        let bytes = [UInt8](data)
        guard bytes.count >= 14, Array(bytes[0..<4]) == [0x4d,0x54,0x68,0x64] else { throw SORIError.invalidScore("MIDI header") }
        XCTAssertTrue([0,1].contains(bytes[9]))
        var offset = 14
        var tracks: [[(tick:Int,midi:Int,velocity:Int)]] = []
        while offset < bytes.count {
            guard offset+8 <= bytes.count, Array(bytes[offset..<offset+4]) == [0x4d,0x54,0x72,0x6b] else { throw SORIError.invalidScore("MIDI track") }
            let count = bytes[offset+4..<offset+8].reduce(0) { ($0 << 8) | Int($1) }
            let end = offset+8+count
            guard end <= bytes.count else { throw SORIError.invalidScore("MIDI track length") }
            offset += 8
            var tick = 0
            var result: [(tick:Int,midi:Int,velocity:Int)] = []
            func variable() throws -> Int {
                var value = 0
                for _ in 0..<4 {
                    guard offset < end else { throw SORIError.invalidScore("MIDI delta") }
                    let byte = bytes[offset]; offset += 1; value = (value << 7) | Int(byte & 127)
                    if byte & 128 == 0 { return value }
                }
                throw SORIError.invalidScore("MIDI delta overflow")
            }
            while offset < end {
                tick += try variable()
                let status = bytes[offset]; offset += 1
                if status == 0xff {
                    offset += 1
                    let length = try variable(); offset += length
                } else if status & 0xf0 == 0xc0 {
                    XCTFail("MIDI must not replace the sampler instrument"); offset += 1
                } else if status & 0xf0 == 0x90 || status & 0xf0 == 0x80 {
                    guard offset+2 <= end else { throw SORIError.invalidScore("MIDI note") }
                    if status & 0xf0 == 0x90, bytes[offset+1] > 0 {
                        result.append((tick,Int(bytes[offset]),Int(bytes[offset+1])))
                    }
                    offset += 2
                } else { throw SORIError.invalidScore("Unexpected MIDI event") }
            }
            tracks.append(result)
        }
        XCTAssertEqual(tracks.count,Int(bytes[10])*256+Int(bytes[11]))
        return tracks
    }
    func testMelodyPreparationMIDIMatchesEveryMeterAndRetainsFirstClickAfterWarmStart() throws {
        let resources = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("IPadApp/IPadApp/Resources")
        let catalog = try JSONDecoder().decode([MelodyQuestion].self,from:Data(contentsOf:resources.appendingPathComponent("melody-catalog.json")))
        let meters = Dictionary(grouping:catalog,by:{"\($0.beats)/\($0.beatType)"})
        for questions in meters.values {
            let q = try XCTUnwrap(questions.first)
            let source = try MelodyXMLParser.parse(Data(contentsOf:resources.appendingPathComponent(q.file)))
            let round = try MelodyRound(source:source,start:1,bars:2)
            for mode in MelodyMode.allCases {
                for gap in [1,2] {
                    var settings = MelodySettings(); settings.mode = mode; settings.gapMeasures = gap
                    let timeline = MelodyTimeline(round:round,settings:settings)
                    let lead = MelodyTimeline.ticks(milliseconds:150,bpm:settings.bpm)
                    let tracks = try notes(timeline.midi(tempo:settings.bpm,leadTicks:lead))
                    let clicks = try XCTUnwrap(tracks.first)
                    XCTAssertEqual(clicks.first?.tick,lead); XCTAssertEqual(clicks.first?.velocity,105)
                    for window in timeline.windows where window.phase == .countIn || window.phase == .beat {
                        let inside = clicks.filter { $0.tick >= window.start+lead && $0.tick < window.end+lead }
                        let measures = (window.end-window.start)/round.score.ticksPerMeasure
                        XCTAssertEqual(inside.count,measures*q.beats,q.id)
                        XCTAssertEqual(inside.first?.tick,window.start+lead,q.id)
                        XCTAssertEqual(inside.last?.tick,window.end+lead-1920/q.beatType,q.id)
                    }
                }
            }
        }
    }
    func testCountInMatchesAllThreeMetersAndJoinsFirstScoreBeat() throws {
        for (n,d) in [(4,4),(3,4),(6,8)] {
            let meter = TimeSignature(numerator:n,denominator:d)
            let plan = PlaybackPlan.exam(meter:meter)
            try plan.validate()
            let count = try XCTUnwrap(plan.countIn)
            let data = MIDIFile.withCountIn(events:[MusicEvent(midi:64,onset:0,duration:480)],
                totalTicks:8*meter.ticksPerMeasure,tempo:plan.tempoBpm,countIn:count)
            let tracks = try notes(data)
            XCTAssertEqual(tracks.count,2)
            XCTAssertEqual(tracks[1].count,n)
            XCTAssertEqual(tracks[1].map { $0.tick },(0..<n).map { $0*1920/d })
            XCTAssertEqual(tracks[1].first?.velocity,110)
            XCTAssertTrue(tracks[1].dropFirst().allSatisfy { $0.velocity == 70 })
            XCTAssertEqual(tracks[0].first?.tick,meter.ticksPerMeasure)
            XCTAssertEqual(try XCTUnwrap(tracks[1].last).tick+1920/d,tracks[0].first?.tick)
        }
    }
    func testFullScheduleIncludesBothCountInsAndLastTwoMinutes() throws {
        for (meter,seconds) in [(TimeSignature(numerator:4,denominator:4),456.0),
                                (TimeSignature(numerator:3,denominator:4),425.25),
                                (TimeSignature(numerator:6,denominator:8),422.1818181818182)] {
            let plan = PlaybackPlan.exam(meter:meter)
            XCTAssertEqual(plan.initialDelayMs,2000)
            XCTAssertEqual(plan.pauseAfterScaleMs,2000)
            XCTAssertEqual(plan.countIn?.beforeStepOrders,[1,11])
            XCTAssertEqual(plan.steps.map(\.pauseAfterMs),Array(repeating:20000,count:10)+[120000])
            XCTAssertEqual(plan.nominalDurationSeconds(meter:meter),seconds,accuracy:0.0001)
        }
    }
    func testNewServerFixtureAndLegacyFixturesRemainReadable() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/sori-api/examples")
        for (name,version) in [("attempt-ready-v4",4),("attempt-ready-v3",3),("attempt-ready",2)] {
            let value = try ContractJSON.decoder().decode(Attempt.self,from:Data(contentsOf:root.appendingPathComponent(name+".json")))
            try value.playbackPlan.validate()
            XCTAssertEqual(value.playbackPlan.version,version)
        }
        var plan = PlaybackPlan.exam(meter:TimeSignature(numerator:6,denominator:8))
        plan.countIn?.beatsPerMeasure = 2
        XCTAssertThrowsError(try plan.validate())
    }
    func testDottedQuarterTempoUsesFractionalQuarterBPMInTheActualMIDI() throws {
        let meter=TimeSignature(numerator:6,denominator:8)
        let plan=PlaybackPlan.exam(meter:meter)
        try plan.validate()
        XCTAssertEqual(plan.tempo?.beatUnit,"dotted_quarter"); XCTAssertEqual(plan.tempo?.bpm,55)
        XCTAssertEqual(plan.tempoBpm,82.5,accuracy:0.000001)
        let data=[UInt8](MIDIFile.make(events:[],totalTicks:1440,tempo:plan.tempoBpm))
        let micros=Int(data[26])<<16 | Int(data[27])<<8 | Int(data[28])
        XCTAssertEqual(60_000_000/Double(micros),82.5,accuracy:0.0001)
        XCTAssertEqual(plan.nominalDurationSeconds(meter:meter),422.1818181818182,accuracy:0.0001)
        var invalid=plan; invalid.tempoBpm=83; XCTAssertThrowsError(try invalid.validate())
    }
    func testScoreTempoIsIndependentOfTheSelectedPlaybackTempo() throws {
        let resources=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("IPadApp/IPadApp/Resources")
        let questions=try ContractJSON.decoder().decode([Question].self,from:Data(contentsOf:resources.appendingPathComponent("practice-catalog.json")))
        for (index,q) in questions.enumerated() {
            let score=try MusicXMLParser.parseMXL(Data(contentsOf:resources.appendingPathComponent("excerpt-\(index+1)-v2-main.mxl")),asset:q.scoreAssets.main)
            XCTAssertEqual(score.tempo,96)
            var chosen=TempoDefaults.setting(for:q.timeSignature); chosen.bpm=chosen.maximumBpm
            let plan=PlaybackPlan.exam(meter:q.timeSignature,setting:chosen)
            try plan.validate()
            XCTAssertEqual(plan.tempoBpm,chosen.quarterBpm)
        }
    }

}
