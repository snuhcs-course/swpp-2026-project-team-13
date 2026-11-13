import SwiftUI
import CoreText
import UIKit

// S9 Question intro (Practice) and S16 Exam intro. Laid out at the wireframe's 1100pt
// content width and scaled down uniformly on narrower windows.
struct QuestionIntroView: View {
    @ObservedObject var model: AppModel
    private static let designWidth: CGFloat = 1100
    // Card, playback order and start row with their minimum gaps.
    private static let minimumHeight: CGFloat = 676

    var body: some View {
        if let question = model.selectedQuestion {
            GeometryReader { proxy in
                // Shrink to fit both the window's width and its height; never enlarge.
                let scale = min(1, (proxy.size.width-48)/Self.designWidth, proxy.size.height/Self.minimumHeight)
                let height = proxy.size.height/scale
                content(question)
                    .frame(width:Self.designWidth, height:height)
                    .scaleEffect(scale, anchor:.topLeading)
                    .frame(width:Self.designWidth*scale, height:height*scale, alignment:.topLeading)
                    .frame(maxWidth:.infinity)
            }
            // The title sits in the bar's centre; no large-title row above the card.
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var exam: Bool { model.selectedMode == .exam }
    private var cardInk: Color { exam ? .white : SolfegeTheme.ink }

    private func content(_ q: Question) -> some View {
        VStack(spacing:0) {
            scoreCover(q).padding(.top,22)
            Spacer(minLength:32)
            MeasurePlaybackOrder()
            Spacer(minLength:32)
            HStack(spacing:16) {
                Label { Text("이어폰과 음량을 확인해 주세요") } icon: { Image(systemName:"headphones") }
                    .font(.system(size:18,weight:.bold)).foregroundStyle(SolfegeTheme.ink)
                Spacer()
                if model.demo { DemoBadge() }
                Button { Task { await model.begin() } } label: {
                    Text("시작하기").font(.system(size:19,weight:.bold)).foregroundStyle(.white)
                        .frame(width:340,height:64)
                        .background(model.busy ? SolfegeTheme.disabledText : SolfegeTheme.violet, in:RoundedRectangle(cornerRadius:12))
                }.buttonStyle(.plain).disabled(model.busy).accessibilityIdentifier("question-intro-start")
            }.padding(.bottom,32)
        }
    }

    // Raised card in the Home key style: lavender for Practice, Exam violet for Exam.
    private func scoreCover(_ q: Question) -> some View {
        let shape = RoundedRectangle(cornerRadius:28)
        let tempo = q.tempo ?? TempoDefaults.setting(for:q.timeSignature)
        return ZStack(alignment:.topLeading) {
            shape.fill(exam ? SolfegeTheme.deepViolet : SolfegeTheme.keyEdge).offset(y:6)
            shape.fill(exam ? SolfegeTheme.violet : SolfegeTheme.soft)
            StaffSignatureView(key:q.keySignature, meter:q.timeSignature, ink:cardInk)
                .offset(x:220-StaffSignatureView.inset.width, y:84-StaffSignatureView.inset.height)
            HStack(spacing:0) {
                KeyNameText(key:q.keySignature).frame(width:380)
                Text("\(q.timeSignature.numerator)/\(q.timeSignature.denominator)박자").frame(width:340)
                    .accessibilityLabel("\(q.timeSignature.numerator)분의 \(q.timeSignature.denominator)박자")
                TempoMark(bpm:tempo.bpm).frame(width:380)
            }
            .font(.system(size:72,weight:.bold)).lineLimit(1).minimumScaleFactor(0.5)
            .foregroundStyle(cardInk).frame(height:106)
            .overlay(alignment:.leading) {
                ZStack(alignment:.leading) {
                    ForEach([380.0,720.0], id:\.self) { x in
                        Capsule().fill(exam ? Color.white.opacity(0.45) : SolfegeTheme.keyEdge).frame(width:1.5,height:106).offset(x:x)
                    }
                }.accessibilityHidden(true)
            }
            .offset(y:250)
        }
        .frame(width:1100, height:400)
        .padding(.bottom,6)
        .accessibilityElement(children:.contain)
    }
}

// Clef, key signature and time signature on one empty bar, drawn as vectors on the staff.
struct StaffSignatureView: View {
    let key: KeySignature; let meter: TimeSignature; let ink: Color
    // Room around the 660×80 staff for the clef's ascender/descender and the barline width.
    static let inset = CGSize(width:2, height:40)

    var body: some View {
        Canvas { context, _ in
            context.translateBy(x:Self.inset.width, y:Self.inset.height)
            let layout = StaffSignatureLayout(fifths:key.fifths)
            let width = StaffSignatureLayout.staffWidth, space = StaffSignatureLayout.space
            var lines = Path()
            for i in 0..<5 { lines.move(to:CGPoint(x:0,y:Double(i)*space)); lines.addLine(to:CGPoint(x:width,y:Double(i)*space)) }
            for x in [0, width] { lines.move(to:CGPoint(x:x,y:0)); lines.addLine(to:CGPoint(x:x,y:4*space)) }
            context.stroke(lines, with:.color(ink), lineWidth:StaffSignatureLayout.lineWidth)

            let clef = StaffSignatureLayout.clefFrame
            draw(.trebleClef, at:CGPoint(x:clef.x, y:clef.y), in:context)
            for accidental in layout.accidentals {
                let glyph: StaffGlyph = accidental.accidental == .flat ? .flat : .sharp
                draw(glyph, at:CGPoint(x:accidental.left, y:accidental.pitchY-glyph.anchorY), in:context)
            }
            let top = EngravedDigits.path(String(meter.numerator)), bottom = EngravedDigits.path(String(meter.denominator))
            let center = layout.timeSignatureLeft + max(top.width, bottom.width)/2
            context.fill(top.centered(x:center, y:StaffSignatureLayout.timeNumeratorY), with:.color(ink))
            context.fill(bottom.centered(x:center, y:StaffSignatureLayout.timeDenominatorY), with:.color(ink))
        }
        .frame(width:StaffSignatureLayout.staffWidth+2*Self.inset.width, height:80+2*Self.inset.height)
        .accessibilityElement().accessibilityLabel(accessibilityText)
    }

    private func draw(_ glyph: StaffGlyph, at origin: CGPoint, in context: GraphicsContext) {
        context.fill(RhythmInk.path(glyph.commands).applying(CGAffineTransform(translationX:origin.x, y:origin.y)), with:.color(ink))
    }

    private var accessibilityText: String {
        let count = abs(key.fifths)
        let signature = count == 0 ? "조표 없음" : "\(key.fifths < 0 ? "플랫" : "샤프") \(count)개"
        return "높은음자리표, \(signature), \(meter.numerator)분의 \(meter.denominator)박자"
    }
}

// Time-signature numerals: heavy serif outlines scaled so each number fills exactly the
// two spaces it occupies, centred on the second or fourth line.
enum EngravedDigits {
    struct Outline {
        let path: Path; let width: Double
        func centered(x: Double, y: Double) -> Path {
            path.applying(CGAffineTransform(translationX:x-width/2, y:y))
        }
    }
    private static let font: CTFont = {
        let base = UIFont.systemFont(ofSize:100, weight:.heavy)
        return UIFont(descriptor:base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size:100) as CTFont
    }()

    // Path centred vertically on y = 0, with its left edge at x = 0.
    static func path(_ text: String) -> Outline {
        let characters = Array(text.utf16)
        var glyphs = [CGGlyph](repeating:0, count:characters.count)
        CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        var advances = [CGSize](repeating:.zero, count:glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        let scale = StaffSignatureLayout.timeDigitHeight/CTFontGetCapHeight(font)
        var raw = Path(), x = 0.0
        for (glyph, advance) in zip(glyphs, advances) {
            if let outline = CTFontCreatePathForGlyph(font, glyph, nil) {
                // Core Text is y-up from the baseline; flip and lift so cap height is centred.
                raw.addPath(Path(outline), transform:CGAffineTransform(a:scale, b:0, c:0, d:-scale, tx:x, ty:StaffSignatureLayout.timeDigitHeight/2))
            }
            x += advance.width*scale
        }
        let bounds = raw.boundingRect
        return Outline(path:raw.applying(CGAffineTransform(translationX:-bounds.minX, y:0)), width:bounds.width)
    }
}

// Draws a wireframe glyph stretched to the frame it is given.
struct StaffGlyphShape: Shape {
    let glyph: StaffGlyph
    func path(in rect: CGRect) -> Path {
        RhythmInk.path(glyph.commands).applying(
            CGAffineTransform(scaleX:rect.width/glyph.width, y:rect.height/glyph.height)
                .concatenating(CGAffineTransform(translationX:rect.minX, y:rect.minY)))
    }
}

// "B♭장조" with the accidental drawn as the same vector glyph as on the staff.
private struct KeyNameText: View {
    let key: KeySignature
    var body: some View {
        if key.mode == "unspecified" { Text(key.label) }
        else {
            let accidental = key.tonic.dropFirst()
            HStack(alignment:.firstTextBaseline, spacing:3) {
                Text(String(key.tonic.prefix(1)))
                if accidental == "b" {
                    // Stroked as on the wireframe so the flat matches the 72pt bold letters' weight.
                    StaffGlyphShape(glyph:.flat)
                        .overlay { StaffGlyphShape(glyph:.flat).stroke(style:StrokeStyle(lineWidth:2.5, lineJoin:.round)) }
                        .frame(width:18.56, height:57.5)
                        .alignmentGuide(.firstTextBaseline) { $0.height-1 }
                } else if accidental == "#" {
                    StaffGlyphShape(glyph:.sharp).frame(width:21, height:60)
                        .alignmentGuide(.firstTextBaseline) { $0.height-8 }
                }
                Text(key.mode == "minor" ? "단조" : "장조")
            }
            .accessibilityElement(children:.ignore).accessibilityLabel(key.label.replacingOccurrences(of:"♭", with:" 플랫 ").replacingOccurrences(of:"♯", with:" 샤프 "))
        }
    }
}

// Tempo is always written against a quarter note, as on the wireframe.
private struct TempoMark: View {
    let bpm: Int
    var body: some View {
        HStack(alignment:.firstTextBaseline, spacing:14) {
            StaffGlyphShape(glyph:.quarterNote).frame(width:24.531, height:71.7965)
                .alignmentGuide(.firstTextBaseline) { $0.height-9 }
            Text("= \(bpm)")
        }
        .accessibilityElement(children:.ignore).accessibilityLabel("4분음표 기준 템포 \(bpm)")
    }
}

// The fixed 11 listening segments. Highlighted segments are the full plays that follow a count-in.
private struct MeasurePlaybackOrder: View {
    private let ranges = PlaybackPlan.examMeasureRanges
    var body: some View {
        HStack(spacing:0) {
            Text("마디 재생 순서").font(.system(size:19,weight:.bold)).foregroundStyle(SolfegeTheme.ink).frame(width:152, alignment:.leading)
            HStack(spacing:0) {
                ForEach(Array(ranges.enumerated()), id:\.offset) { index, range in
                    let highlighted = index == 0 || index == ranges.count-1
                    Text("\(range.from)–\(range.to)").font(.system(size:20,weight:.bold))
                        .foregroundStyle(highlighted ? SolfegeTheme.deepViolet : SolfegeTheme.ink)
                        .frame(maxWidth:.infinity, maxHeight:.infinity)
                        .background {
                            if highlighted {
                                UnevenRoundedRectangle(topLeadingRadius:index == 0 ? 27 : 0, bottomLeadingRadius:index == 0 ? 27 : 0,
                                                       bottomTrailingRadius:index == 0 ? 0 : 27, topTrailingRadius:index == 0 ? 0 : 27)
                                    .fill(SolfegeTheme.keyUnavailable)
                            }
                        }
                        .overlay(alignment:.leading) {
                            if index > 0 { Rectangle().fill(SolfegeTheme.keyEdge).frame(width:1.5, height:36).offset(x:-0.75) }
                        }
                }
            }
            .padding(1)
            .background(.white, in:Capsule())
            .overlay(Capsule().stroke(SolfegeTheme.keyEdge, lineWidth:1.5))
            .frame(height:56)
        }
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("마디 재생 순서: " + ranges.map { "\($0.from)에서 \($0.to)마디" }.joined(separator:", "))
    }
}
