import Foundation

// Broader local-practice reader. The versioned exam parser and asset contract stay strict.
enum MelodyXMLParser {
    static func parse(_ data: Data) throws -> MelodySource {
        func fail(_ message: String) -> SORIError { .invalidScore("멜로디 런: "+message) }
        guard data.count <= 1_048_576, var text = String(data:data,encoding:.utf8),
              !text.uppercased().contains("<!ENTITY"), !text.contains("<![INCLUDE") else { throw fail("1 MB 이하 MusicXML 파일이 필요해요.") }
        // MusicXML exporters often include a public DTD declaration. Discard the declaration,
        // never load it. Internal subsets/entities remain prohibited by SafeXML.
        if let range = text.range(of:"<!DOCTYPE[^>]*>",options:.regularExpression) {
            guard !text[range].contains("[") else { throw fail("외부 정의가 없는 MusicXML을 사용해 주세요.") }
            text.removeSubrange(range)
        }
        let root = try SafeXML.parse(Data(text.utf8))
        guard root.name == "score-partwise", root.children(named:"part").count == 1,
              let part = root.one("part") else { throw fail("단선율 한 파트만 지원해요.") }
        let bars = part.children(named:"measure")
        guard bars.count == 8, let attrs = bars.first?.one("attributes"),
              let beats = Int(attrs.one("time")?.value("beats") ?? ""),
              let unit = Int(attrs.one("time")?.value("beat-type") ?? ""),
              (2...12).contains(beats), [2,4,8].contains(unit),
              let fifths = Int(attrs.one("key")?.value("fifths") ?? "0"), (-7...7).contains(fifths) else {
            throw fail("온전한 8마디와 고정된 조성·박자가 필요해요. 못갖춘마디는 아직 지원하지 않아요.")
        }
        let mode = attrs.one("key")?.value("mode") ?? "major"
        let clef = attrs.one("clef")?.value("sign") ?? "G"
        guard (clef == "G" && (attrs.one("clef")?.value("line") ?? "2") == "2") ||
              (clef == "F" && attrs.one("clef")?.value("line") == "4"),
              attrs.one("clef")?.one("clef-octave-change") == nil,
              attrs.value("staves") == nil || attrs.value("staves") == "1" else { throw fail("높은/낮은음자리 단일 보표만 지원해요.") }
        let meter = TimeSignature(numerator:beats,denominator:unit), ticks = meter.ticksPerMeasure
        var divisions = 0, events: [MusicEvent] = [], symbols: [ScoreSymbol] = [], openTie: Int?
        var voices: Set<String> = [], tempo = 96.0
        for (barIndex,bar) in bars.enumerated() {
            guard bar.one("backup") == nil, bar.children(named:"backup").isEmpty,
                  bar.children(named:"forward").isEmpty,
                  !bar.children(named:"barline").contains(where: { !$0.children(named:"repeat").isEmpty || !$0.children(named:"ending").isEmpty }) else { throw fail("다성부·반복 구간은 아직 지원하지 않아요.") }
            if let a = bar.one("attributes") {
                if let d = Int(a.value("divisions") ?? "") { divisions = d }
                if barIndex > 0 {
                    if let key = a.one("key"), Int(key.value("fifths") ?? "0") != fifths { throw fail("중간 조성 변경") }
                    if let time = a.one("time"), time.value("beats") != String(beats) || time.value("beat-type") != String(unit) { throw fail("중간 박자 변경") }
                    if let c = a.one("clef"), c.value("sign") != clef { throw fail("중간 음자리표 변경") }
                }
            }
            guard divisions > 0, divisions <= 1_000_000 else { throw fail("divisions가 올바르지 않아요.") }
            for direction in bar.children(named:"direction") {
                if let value = direction.one("sound")?.attributes["tempo"], let bpm = Double(value) {
                    if barIndex == 0 { tempo = min(180,max(40,bpm)) }
                    else if bpm != tempo { throw fail("중간 템포 변경") }
                }
            }
            var offset = 0
            for note in bar.children(named:"note") {
                guard note.one("chord") == nil, note.one("grace") == nil,
                      let rawDuration = Int(note.value("duration") ?? ""), rawDuration > 0,
                      rawDuration <= divisions*48, (rawDuration*480)%divisions == 0 else { throw fail("화음·꾸밈음 또는 지원하지 않는 음가") }
                let duration = rawDuration*480/divisions
                guard offset+duration <= ticks else { throw fail("못갖춘마디 또는 마디 길이 불일치") }
                voices.insert(note.value("voice") ?? "1")
                guard voices.count == 1, note.value("staff") == nil || note.value("staff") == "1" else { throw fail("단선율 한 성부만 지원해요.") }
                let rest = note.one("rest") != nil, pitch = note.one("pitch")
                var midi: Int?, step: String?, octave = 4, alter = 0
                if !rest {
                    step = pitch?.value("step")
                    guard let s = step, let semitone = ["C":0,"D":2,"E":4,"F":5,"G":7,"A":9,"B":11][s],
                          let o = Int(pitch?.value("octave") ?? ""), (1...7).contains(o),
                          let a = Int(pitch?.value("alter") ?? "0"), (-2...2).contains(a) else { throw fail("지원하지 않는 음높이") }
                    octave = o; alter = a; midi = (o+1)*12+semitone+a
                    guard (24...108).contains(midi!) else { throw fail("지원 음역은 C1–C8이에요.") }
                } else if pitch != nil { throw fail("음표와 쉼표가 중복되었어요.") }
                let dots = note.children(named:"dot").count
                let modification = note.one("time-modification")
                let actual = Int(modification?.value("actual-notes") ?? "1") ?? 0
                let normal = Int(modification?.value("normal-notes") ?? "1") ?? 0
                guard (1...16).contains(actual), (1...16).contains(normal), dots <= 2 else { throw fail("잇단음표 또는 점음표 형식") }
                var type = note.value("type") ?? ""
                if type.isEmpty, rest { type = [1920:"whole",960:"half",480:"quarter",240:"eighth",120:"16th",60:"32nd"][duration] ?? "whole" }
                let bases = ["whole":1920,"half":960,"quarter":480,"eighth":240,"16th":120,"32nd":60]
                guard let base = bases[type], (rest && note.one("rest")?.attributes["measure"] == "yes") ||
                        duration*actual*(dots == 0 ? 1 : dots == 1 ? 2 : 4) == base*normal*(dots == 0 ? 1 : dots == 1 ? 3 : 7) else { throw fail("표시 음가와 재생 길이가 다릅니다.") }
                let ties = note.children(named:"tie").compactMap { $0.attributes["type"] }
                let start = ties.contains("start"), stop = ties.contains("stop"), onset = barIndex*ticks+offset
                if let index = openTie {
                    guard stop, events[index].midi == midi, events[index].onset+events[index].duration == onset else { throw fail("연결되지 않은 붙임줄") }
                    events[index].duration += duration; openTie = start ? index : nil
                } else {
                    guard !stop else { throw fail("붙임줄 시작 누락") }
                    events.append(MusicEvent(midi:midi,onset:onset,duration:duration)); if start { openTie = events.count-1 }
                }
                var beams: [Int:String] = [:]
                for beam in note.children(named:"beam") {
                    if let level = Int(beam.attributes["number"] ?? "1"), (1...3).contains(level) {
                        beams[level] = beam.text.trimmingCharacters(in:.whitespacesAndNewlines)
                    }
                }
                let tuplets = note.one("notations")?.children(named:"tuplet") ?? []
                symbols.append(ScoreSymbol(measure:barIndex+1,onset:onset,duration:duration,midi:midi,
                    step:step,octave:octave,alter:alter,type:type,dots:dots,tieStart:start,tieStop:stop,beams:beams,
                    tupletActual:actual,tupletNormal:normal,tupletStart:tuplets.contains { $0.attributes["type"] == "start" },
                    tupletStop:tuplets.contains { $0.attributes["type"] == "stop" }))
                offset += duration
            }
            guard offset == ticks else { throw fail("못갖춘마디 또는 마디 길이 불일치") }
        }
        let pitches = symbols.compactMap(\.midi)
        guard openTie == nil, let low = pitches.min(), let high = pitches.max(), high-low <= 36 else { throw fail("3옥타브 이하의 완결된 선율이 필요해요.") }
        return MelodySource(score:MusicScore(tempo:tempo,measures:8,events:events,symbols:symbols,timeSignature:meter),fifths:fifths,mode:mode,clef:clef)
    }
}
