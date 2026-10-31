import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import zlib

struct MusicEvent: Codable, Equatable {
    var midi: Int?; var onset: Int; var duration: Int
}
struct ScoreSymbol: Equatable {
    var measure: Int; var onset: Int; var duration: Int; var midi: Int?
    var step: String?; var octave: Int; var alter: Int; var type: String; var dots: Int
    var tieStart: Bool; var tieStop: Bool
    var beams: [Int:String] = [:]
    var tupletActual = 1; var tupletNormal = 1
    var tupletStart = false; var tupletStop = false
}
struct MusicScore: Equatable {
    var tempo: Double; var measures: Int; var events: [MusicEvent]; var symbols: [ScoreSymbol]
    var timeSignature = TimeSignature(numerator: 4, denominator: 4)
    var keySignature = KeySignature(tonic:"C",mode:"major",fifths:0)
    var ticksPerMeasure: Int { timeSignature.ticksPerMeasure }
    var totalTicks: Int { measures * ticksPerMeasure }
    func segment(from: Int, through: Int) throws -> [MusicEvent] {
        guard from >= 1, through <= measures, from <= through else { throw SORIError.invalidScore("잘못된 재생 구간입니다.") }
        let start = (from - 1) * ticksPerMeasure, end = through * ticksPerMeasure
        return events.compactMap { event in
            let a = max(event.onset, start), b = min(event.onset + event.duration, end)
            return a < b ? MusicEvent(midi: event.midi, onset: a - start, duration: b - a) : nil
        }
    }
}

// Only the three in-memory MXL entries are accepted. No file paths are extracted to disk.
enum MXLContainer {
    static func entries(_ data: Data) throws -> [String: Data] {
        let b = [UInt8](data)
        func bad() -> SORIError { .invalidScore("SCORE_PARSE_FAILED: MXL 압축 구조가 올바르지 않습니다.") }
        func u16(_ p: Int) throws -> Int { guard p >= 0, p + 2 <= b.count else { throw bad() }; return Int(b[p]) | Int(b[p+1]) << 8 }
        func u32(_ p: Int) throws -> Int { try u16(p) | (u16(p+2) << 16) }
        guard b.count >= 22, b.count <= 1_048_576 else { throw bad() }
        guard let end = stride(from: b.count - 22, through: max(0, b.count - 65557), by: -1).first(where: { i in b[i...i+3].elementsEqual([0x50,0x4b,0x05,0x06]) }) else { throw bad() }
        guard try u16(end+4) == 0, try u16(end+6) == 0, try u16(end+8) == 3, try u16(end+10) == 3,
              end + 22 + (try u16(end+20)) == b.count else { throw bad() }
        let centralSize = try u32(end+12), centralStart = try u32(end+16)
        guard centralStart + centralSize == end else { throw bad() }
        var position = centralStart, result: [String: Data] = [:], total = 0
        var ranges: [Range<Int>] = []
        for _ in 0..<3 {
            guard try u32(position) == 0x02014b50 else { throw bad() }
            let flags = try u16(position+8), method = try u16(position+10), crc = try u32(position+16)
            let compressed = try u32(position+20), expanded = try u32(position+24)
            let nameLength = try u16(position+28), extraLength = try u16(position+30), commentLength = try u16(position+32), offset = try u32(position+42)
            let next = position + 46 + nameLength + extraLength + commentLength
            guard next <= end, expanded > 0, compressed > 0, expanded <= 4_194_304,
                  flags & ~0x0808 == 0, [0,8].contains(method), try u16(position+34) == 0 else { throw bad() }
            total += expanded; guard total <= 4_194_304 else { throw bad() }
            guard let name = String(bytes: b[(position+46)..<(position+46+nameLength)], encoding: .utf8),
                  ["mimetype", "META-INF/container.xml", "score.xml"].contains(name), result[name] == nil,
                  try u32(offset) == 0x04034b50, try u16(offset+6) == flags, try u16(offset+8) == method else { throw bad() }
            let localName = try u16(offset+26), localExtra = try u16(offset+28)
            let start = offset + 30 + localName + localExtra
            guard start <= centralStart, start + compressed <= centralStart,
                  localName == nameLength,
                  b[(offset+30)..<(offset+30+localName)].elementsEqual(name.utf8),
                  ranges.allSatisfy({ !$0.overlaps(offset..<(start+compressed)) }) else { throw bad() }
            if flags & 8 == 0 {
                guard try u32(offset+14) == crc, try u32(offset+18) == compressed, try u32(offset+22) == expanded else { throw bad() }
            }
            ranges.append(offset..<(start+compressed))
            let input = Array(b[start..<(start+compressed)])
            let output: Data
            if method == 0 {
                guard compressed == expanded else { throw bad() }; output = Data(input)
            } else {
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw bad() }
                defer { inflateEnd(&stream) }
                var out = [UInt8](repeating: 0, count: expanded)
                let status = input.withUnsafeBytes { src in out.withUnsafeMutableBytes { dst -> Int32 in
                    stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(compressed); stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(expanded)
                    return inflate(&stream, Z_FINISH)
                } }
                guard status == Z_STREAM_END, stream.total_out == expanded, stream.total_in == compressed else { throw bad() }
                output = Data(out)
            }
            let checksum = output.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(output.count)) }
            guard Int(checksum) == crc else { throw bad() }
            result[name] = output; position = next
        }
        guard position == end, result["mimetype"] == Data("application/vnd.recordare.musicxml".utf8),
              let container = result["META-INF/container.xml"] else { throw bad() }
        let root = try SafeXML.parse(container)
        let files = root.children(named: "rootfiles").flatMap { $0.children(named: "rootfile") }
        guard root.name == "container", files.count == 1, files[0].attributes["full-path"] == "score.xml",
              files[0].attributes["media-type"] == "application/vnd.recordare.musicxml+xml" else { throw bad() }
        return result
    }
}

final class XMLNode {
    let name: String; let attributes: [String: String]; var text = ""; var children: [XMLNode] = []
    init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
    func children(named name: String) -> [XMLNode] { children.filter { $0.name == name } }
    func one(_ name: String) -> XMLNode? { let matches = children(named: name); return matches.count == 1 ? matches[0] : nil }
    func value(_ name: String) -> String? { one(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines) }
}
final class SafeXML: NSObject, XMLParserDelegate {
    var stack: [XMLNode] = []; var root: XMLNode?; var count = 0; var failure = false
    static func parse(_ data: Data) throws -> XMLNode {
        guard let text = String(data: data, encoding: .utf8), data.count <= 4_194_304,
              !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY"), !text.contains("<?xml-stylesheet") else { throw SORIError.invalidScore("외부 리소스와 DTD가 있는 XML은 지원하지 않습니다.") }
        let delegate = SafeXML(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.failure, let root = delegate.root, delegate.stack.isEmpty else { throw SORIError.invalidScore("MusicXML을 해석하지 못했습니다.") }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        count += 1
        guard count <= 20_000, stack.count < 64, !attributeDict.keys.contains(where: { $0 == "href" || $0 == "xlink:href" }) else { failure = true; parser.abortParsing(); return }
        let node = XMLNode(elementName, attributeDict)
        if let parent = stack.last { parent.children.append(node) } else if root == nil { root = node } else { failure = true; parser.abortParsing(); return }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { failure = true; parser.abortParsing(); return nil }
}

enum MusicXMLParser {
    static let version = "sori-parser-5"
    static func parseMXL(_ data: Data, asset: ScoreAsset, tempo: Double? = nil) throws -> MusicScore {
        guard data.count == asset.sizeBytes, data.sha256 == asset.sha256 else { throw SORIError.invalidScore("SCORE_HASH_MISMATCH: 악보의 해시 또는 크기가 다릅니다.") }
        guard ["sori-monophonic-v1", "sori-monophonic-v2", "sori-monophonic-v3", "sori-monophonic-v4"].contains(asset.profile), asset.musicxmlVersion == "4.0", asset.partId == "P1", asset.contentType == "application/vnd.recordare.musicxml" else { throw SORIError.unsupported("UNSUPPORTED_SCORE_PROFILE: 악보 형식을 확인해 주세요.") }
        let files = try MXLContainer.entries(data)
        let score = try parseXML(files["score.xml"]!, measures: asset.measureCount, tempo: tempo ?? asset.sourceTempoBpm ?? 96)
        if asset.profile != "sori-monophonic-v4" {
            guard score.keySignature.fifths == 0, ["major","unspecified"].contains(score.keySignature.mode) else { throw SORIError.invalidScore("구버전 악보 프로필의 조표가 다릅니다.") }
        }
        return score
    }
    static func parseXML(_ data: Data, measures: Int, tempo: Double) throws -> MusicScore {
        let root = try SafeXML.parse(data)
        func fail(_ message: String) -> SORIError { .invalidScore("UNSUPPORTED_SCORE_PROFILE: " + message) }
        let allowed: Set<String> = ["score-partwise","work","work-title","movement-title","identification","creator","rights","encoding","software","encoding-date","part-list","score-part","part-name","part-abbreviation","score-instrument","instrument-name","instrument-abbreviation","midi-instrument","midi-channel","midi-program","part","measure","attributes","divisions","key","fifths","mode","time","beats","beat-type","clef","sign","line","staves","direction","direction-type","metronome","beat-unit","per-minute","sound","note","pitch","step","alter","octave","rest","duration","voice","staff","type","dot","accidental","tie","notations","tied","barline","bar-style","stem","beam","time-modification","actual-notes","normal-notes","normal-type","tuplet"]
        func validate(_ node: XMLNode) throws {
            guard allowed.contains(node.name) else { throw fail("지원하지 않는 기호: \(node.name)") }
            let childrenByParent: [String: Set<String>] = [
                "score-partwise": ["work","movement-title","identification","part-list","part"],
                "part-list": ["score-part"], "score-part": ["part-name","part-abbreviation","score-instrument","midi-instrument"],
                "part": ["measure"], "measure": ["attributes","direction","note","barline"],
                "attributes": ["divisions","key","time","clef","staves"],
                "key": ["fifths","mode"], "time": ["beats","beat-type"], "clef": ["sign","line"],
                "direction": ["direction-type","sound"], "direction-type": ["metronome"], "metronome": ["beat-unit","per-minute"],
                "note": ["pitch","rest","duration","voice","type","dot","accidental","tie","notations","staff","stem","beam","time-modification"],
                "time-modification": ["actual-notes","normal-notes","normal-type"],
                "pitch": ["step","alter","octave"], "notations": ["tied","tuplet"], "barline": ["bar-style"],
                "work": ["work-title"], "identification": ["creator","rights","encoding"], "encoding": ["software","encoding-date"],
                "score-instrument": ["instrument-name","instrument-abbreviation"], "midi-instrument": ["midi-channel","midi-program"]
            ]
            if let permitted = childrenByParent[node.name] {
                guard node.children.allSatisfy({ permitted.contains($0.name) }) else { throw fail("잘못된 기호 위치: " + node.name) }
            } else if !node.children.isEmpty { throw fail("예상하지 못한 하위 기호: " + node.name) }
            let repeatable: Set<String> = ["part","measure","note","direction","dot","tie","tied","creator","rights","software","score-instrument","midi-instrument","beam","tuplet"]
            for group in Dictionary(grouping: node.children, by: \.name).values {
                guard group.count == 1 || repeatable.contains(group[0].name) else { throw fail("중복 기호: " + group[0].name) }
            }
            if node.name == "sound" { guard Set(node.attributes.keys) == ["tempo"] else { throw fail("고정 템포 외의 재생 지시") } }
            if node.name == "bar-style" { guard ["regular","light-heavy","light-light"].contains(node.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw fail("반복 마디") } }
            for child in node.children { try validate(child) }
        }
        try validate(root)
        guard root.name == "score-partwise", root.attributes["version"] == "4.0", [1,2,3,4,5,8].contains(measures),
              root.children(named: "part").count == 1, let part = root.one("part"), part.attributes["id"] == "P1",
              let partList = root.one("part-list"), partList.children(named: "score-part").count == 1,
              partList.one("score-part")?.attributes["id"] == "P1", (40...200).contains(tempo) else { throw fail("파트·버전·마디 수를 확인해 주세요.") }
        if let instrument = partList.one("score-part")?.one("midi-instrument") {
            guard instrument.value("midi-program") == "1", instrument.value("midi-channel") == "1" else { throw fail("피아노 MIDI 매핑") }
        }
        let bars = part.children(named: "measure")
        guard bars.count == measures else { throw fail("마디 수 불일치") }
        guard let time = bars.first?.one("attributes")?.one("time"), let beats = Int(time.value("beats") ?? ""), let beatType = Int(time.value("beat-type") ?? "") else { throw fail("박자표 누락") }
        let meter = TimeSignature(numerator: beats, denominator: beatType)
        guard meter.supported else { throw fail("지원하지 않는 박자표입니다.") }
        guard let key = bars.first?.one("attributes")?.one("key"), let fifths = Int(key.value("fifths") ?? ""), (-7...7).contains(fifths),
              let mode = key.value("mode"), ["major","minor","none"].contains(mode), mode != "none" || fifths == 0 else { throw fail("조표·장단조 정보") }
        let tonics = mode == "minor" ? ["Ab","Eb","Bb","F","C","G","D","A","E","B","F#","C#","G#","D#","A#"] : ["Cb","Gb","Db","Ab","Eb","Bb","F","C","G","D","A","E","B","F#","C#"]
        let signature = KeySignature(tonic:tonics[fifths+7],mode:mode == "none" ? "unspecified" : mode,fifths:fifths)
        let barTicks = meter.ticksPerMeasure
        var events: [MusicEvent] = [], symbols: [ScoreSymbol] = [], openTie: Int?, sawTempo = false
        for (barIndex, bar) in bars.enumerated() {
            guard bar.attributes["number"] == String(barIndex+1), bar.attributes["implicit"] != "yes" else { throw fail("마디 번호·못갖춘마디") }
            let attrs = bar.children(named: "attributes")
            if barIndex == 0 {
                guard attrs.count == 1, let a = attrs.first, a.value("divisions") == "480", a.one("key")?.value("fifths") == String(fifths),
                      a.one("key")?.value("mode") == mode, a.one("time")?.value("beats") == String(beats), a.one("time")?.value("beat-type") == String(beatType),
                      a.one("clef")?.value("sign") == "G", a.one("clef")?.value("line") == "2",
                      a.value("staves") == nil || a.value("staves") == "1" else { throw fail("고정 조표·지원 박자·높은음자리표·divisions 480 필요") }
            } else if !attrs.isEmpty { throw fail("중간 속성 변경") }
            for direction in bar.children(named: "direction") {
                let sounds = direction.children(named: "sound")
                guard barIndex == 0, !sawTempo, sounds.count == 1,
                      Double(sounds[0].attributes["tempo"] ?? "") == Double(tempo),
                      direction.one("direction-type")?.one("metronome")?.value("beat-unit") == "quarter",
                      Double(direction.one("direction-type")?.one("metronome")?.value("per-minute") ?? "") == Double(tempo) else { throw fail("템포 불일치 또는 템포 변경") }
                sawTempo = true
            }
            var offset = 0
            for note in bar.children(named: "note") {
                let duration = Int(note.value("duration") ?? "") ?? 0
                let type = note.value("type") ?? "", dots = note.children(named: "dot").count
                let bases = ["whole":1920,"half":960,"quarter":480,"eighth":240,"16th":120,"32nd":60]
                let modification = note.one("time-modification")
                let actual = modification.flatMap { Int($0.value("actual-notes") ?? "") } ?? (modification == nil ? 1 : 0)
                let normal = modification.flatMap { Int($0.value("normal-notes") ?? "") } ?? (modification == nil ? 1 : 0)
                guard (actual == 1 && normal == 1) || (actual == 3 && normal == 2) else { throw fail("지원하지 않는 잇단음표") }
                guard let base = bases[type], dots <= 2, duration > 0, duration * actual * (dots == 0 ? 1 : (dots == 1 ? 2 : 4)) == base * normal * (dots == 0 ? 1 : (dots == 1 ? 3 : 7)),
                      note.value("voice") == nil || note.value("voice") == "1",
                      note.value("staff") == nil || note.value("staff") == "1", offset + duration <= barTicks else { throw fail("지원하지 않는 리듬·성부") }
                let rest = note.children(named: "rest").count == 1
                let pitch = note.one("pitch"), step = pitch?.value("step"), octave = Int(pitch?.value("octave") ?? "") ?? -1
                let alter = Int(pitch?.value("alter") ?? "0") ?? 99
                var midi: Int?
                if rest { guard pitch == nil else { throw fail("쉼표와 음표 중복") } }
                else {
                    let pitches = ["C":0,"D":2,"E":4,"F":5,"G":7,"A":9,"B":11]
                    guard let step, let semitone = pitches[step], (-2...2).contains(alter), (3...6).contains(octave) else { throw fail("음높이") }
                    let value = (octave+1)*12 + semitone + alter
                    guard (48...95).contains(value) else { throw fail("MIDI 음역 48~95") }; midi = value
                }
                let ties = note.children(named: "tie").compactMap { $0.attributes["type"] }
                guard ties.count == note.children(named: "tie").count, ties.allSatisfy({ ["start","stop"].contains($0) }), Set(ties).count == ties.count,
                      !rest || ties.isEmpty else { throw fail("붙임줄") }
                let notationTies = note.one("notations")?.children(named: "tied").compactMap { $0.attributes["type"] } ?? []
                guard notationTies.isEmpty || notationTies.sorted() == ties.sorted() else { throw fail("재생 붙임줄과 표시 붙임줄 불일치") }
                let start = ties.contains("start"), stop = ties.contains("stop"), onset = barIndex * barTicks + offset
                if let open = openTie {
                    guard stop, events[open].midi == midi, events[open].onset + events[open].duration == onset else { throw fail("연결되지 않은 붙임줄") }
                    events[open].duration += duration; openTie = start ? open : nil
                } else {
                    guard !stop else { throw fail("붙임줄 시작 누락") }
                    events.append(MusicEvent(midi: midi, onset: onset, duration: duration)); if start { openTie = events.count-1 }
                }
                var beams: [Int:String] = [:]
                for beam in note.children(named: "beam") {
                    guard let level = Int(beam.attributes["number"] ?? "1"), (1...3).contains(level), beams[level] == nil, ["begin","continue","end","forward hook","backward hook"].contains(beam.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw fail("빔 형식") }
                    beams[level] = beam.text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let tuplets = note.one("notations")?.children(named: "tuplet") ?? []
                symbols.append(ScoreSymbol(measure: barIndex+1, onset: onset, duration: duration, midi: midi, step: step, octave: octave, alter: alter, type: type, dots: dots, tieStart: start, tieStop: stop, beams: beams, tupletActual: actual, tupletNormal: normal, tupletStart: tuplets.contains { $0.attributes["type"] == "start" }, tupletStop: tuplets.contains { $0.attributes["type"] == "stop" }))
                offset += duration
            }
            guard offset == barTicks else { throw fail("마디 길이와 박자표가 다릅니다.") }
        }
        guard sawTempo, openTie == nil else { throw fail("템포 또는 붙임줄 끝 누락") }
        return MusicScore(tempo: tempo, measures: measures, events: events, symbols: symbols, timeSignature: meter, keySignature: signature)
    }
}

// Standard MIDI File format 0, 480 PPQ. Explicit tempo and a full-length end-of-track preserve rests.
enum MIDIFile {
    static func variable(_ value: Int) -> [UInt8] {
        var n = value, bytes = [UInt8(n & 127)]; n >>= 7
        while n > 0 { bytes.insert(UInt8(n & 127) | 128, at: 0); n >>= 7 }; return bytes
    }
    static func make(events: [MusicEvent], totalTicks: Int, tempo: Double, velocity: Int = 80, firstNoteVelocity: Int? = nil) -> Data {
        let firstOnset = events.filter { $0.midi != nil }.map(\.onset).min()
        let micros = Int((60_000_000 / tempo).rounded())
        var track: [UInt8] = [0,0xff,0x51,3, UInt8((micros >> 16) & 255), UInt8((micros >> 8) & 255), UInt8(micros & 255)]
        var messages: [(Int,Int,[UInt8])] = []
        for e in events { if let midi = e.midi {
            messages.append((e.onset,1,[0x90,UInt8(midi),UInt8((e.onset == firstOnset ? firstNoteVelocity : nil) ?? velocity)]))
            messages.append((e.onset+e.duration,0,[0x80,UInt8(midi),0]))
        } }
        messages.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        var previous = 0
        for m in messages { track += variable(m.0 - previous) + m.2; previous = m.0 }
        track += variable(max(0,totalTicks-previous)) + [0xff,0x2f,0]
        let length = UInt32(track.count)
        var result = Data([0x4d,0x54,0x68,0x64,0,0,0,6,0,0,0,1,1,0xe0,0x4d,0x54,0x72,0x6b])
        result.append(contentsOf: [UInt8((length >> 24) & 255), UInt8((length >> 16) & 255),UInt8((length >> 8) & 255),UInt8(length & 255)])
        result.append(contentsOf: track); return result
    }

    // A single tempo clock schedules the count-in and first score onset; no separate audio starts.
    // Track 0 is piano, track 1 is the short click sample. No clicks continue into the score.
    static func withCountIn(events: [MusicEvent], totalTicks: Int, tempo: Double, countIn: CountInPlayback, velocity: Int = 80) -> Data {
        let prefix = countIn.totalTicks
        let piano = make(events:events.map { MusicEvent(midi:$0.midi,onset:$0.onset+prefix,duration:$0.duration) },
                         totalTicks:totalTicks+prefix,tempo:tempo,velocity:velocity)
        let clicks = (0..<(countIn.measures*countIn.beatsPerMeasure)).map {
            MusicEvent(midi:60,onset:$0*countIn.ticksPerBeat,duration:min(40,countIn.ticksPerBeat))
        }
        let click = make(events:clicks,totalTicks:totalTicks+prefix,tempo:tempo,
                         velocity:countIn.velocity,firstNoteVelocity:countIn.accentVelocity)
        var result = Data([0x4d,0x54,0x68,0x64,0,0,0,6,0,1,0,2,1,0xe0])
        result.append(contentsOf:piano.dropFirst(14))
        result.append(contentsOf:click.dropFirst(14))
        return result
    }
}
