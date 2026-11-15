// Renders the v5 answer sheets: the same 1330×846 logical canvas and 12-unit staff space as
// v4, but with the S9/S16 clef, key-signature and time-signature engraving, the second staff
// moved up to y = 340, and barlines at identical x positions on both staves.
//
// Built against the app's own Core sources so the glyphs are the ones the intro screens draw:
//   scripts/sheet-v5/build.sh
// Existing templates are immutable: a file that already exists is never re-rendered.
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SheetV5 {
    static let version = 5
    static let logical = CGSize(width: 1330, height: 846)
    static let exportScale = 2
    static let staffLeft = 54.0, staffRight = 1276.0
    static let staffSpace = 12.0
    static let tops = [164.0, 340.0]
    // v4 kept 186 units of writing room below the second staff; v5 keeps the same margin.
    static var displayHeight: Int { Int(tops[1] + 4 * staffSpace + 186) }
    // S9 draws one staff space as 20 units.
    static let k = staffSpace / StaffSignatureLayout.space
    static let lineWidth = StaffSignatureLayout.lineWidth * k
    static let finalThin = 1267.0, finalThickWidth = 4.5
    // Room between the time signature and the first written note.
    static let measurePadding = 16.0
}

struct Meter: Hashable { let n: Int; let d: Int; let fifths: Int
    var id: String { "staff-8bars-\(n)-\(d)-key\(fifths)-v\(SheetV5.version)" }
}

// Heavy serif digits, as EngravedDigits does on the intro screens.
enum Digits {
    static let font: CTFont = {
        let base = NSFont.systemFont(ofSize: 100, weight: .heavy)
        let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        return NSFont(descriptor: descriptor, size: 100)! as CTFont
    }()
    /// Path with its left edge at x = 0 and its cap height centred on y = 0 (y down).
    static func path(_ text: String, height: Double) -> (path: CGPath, width: Double) {
        let chars = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        let scale = height / CTFontGetCapHeight(font)
        let raw = CGMutablePath(); var x = 0.0
        for (glyph, advance) in zip(glyphs, advances) {
            if let outline = CTFontCreatePathForGlyph(font, glyph, nil) {
                raw.addPath(outline, transform: CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: x, ty: height / 2))
            }
            x += advance.width * scale
        }
        let bounds = raw.boundingBoxOfPath
        let shifted = CGMutablePath()
        shifted.addPath(raw, transform: CGAffineTransform(translationX: -bounds.minX, y: 0))
        return (shifted, bounds.width)
    }
}

func cgPath(_ commands: [RhythmVectorCommand]) -> CGPath {
    let p = CGMutablePath()
    for c in commands {
        let v = c.values
        switch c.op {
        case "M" where v.count == 2: p.move(to: CGPoint(x: v[0], y: v[1]))
        case "L" where v.count == 2: p.addLine(to: CGPoint(x: v[0], y: v[1]))
        case "C" where v.count == 6: p.addCurve(to: CGPoint(x: v[4], y: v[5]), control1: CGPoint(x: v[0], y: v[1]), control2: CGPoint(x: v[2], y: v[3]))
        case "Z": p.closeSubpath()
        default: break
        }
    }
    return p
}

func svgData(_ path: CGPath) -> String {
    var parts: [String] = []
    func f(_ v: CGFloat) -> String { String(format: "%.3f", Double(v)) }
    path.applyWithBlock { element in
        let e = element.pointee, pts = e.points
        switch e.type {
        case .moveToPoint: parts.append("M\(f(pts[0].x)) \(f(pts[0].y))")
        case .addLineToPoint: parts.append("L\(f(pts[0].x)) \(f(pts[0].y))")
        case .addQuadCurveToPoint: parts.append("Q\(f(pts[0].x)) \(f(pts[0].y)) \(f(pts[1].x)) \(f(pts[1].y))")
        case .addCurveToPoint: parts.append("C\(f(pts[0].x)) \(f(pts[0].y)) \(f(pts[1].x)) \(f(pts[1].y)) \(f(pts[2].x)) \(f(pts[2].y))")
        case .closeSubpath: parts.append("Z")
        @unknown default: break
        }
    }
    return parts.joined()
}

struct Sheet {
    let meter: Meter
    var fills: [CGPath] = []
    var barlineX: [Double] = []

    init(_ meter: Meter) {
        self.meter = meter
        let k = SheetV5.k, left = SheetV5.staffLeft
        let signature = StaffSignatureLayout(fifths: meter.fifths)
        let numerator = Digits.path(String(meter.n), height: StaffSignatureLayout.timeDigitHeight * k)
        let denominator = Digits.path(String(meter.d), height: StaffSignatureLayout.timeDigitHeight * k)
        let timeLeft = left + signature.timeSignatureLeft * k
        let timeWidth = max(numerator.width, denominator.width)
        // Measures start after the first staff's full signature, on both staves, so all
        // four music areas have the same width and every barline lines up vertically.
        let start = timeLeft + timeWidth + SheetV5.measurePadding
        let width = (SheetV5.staffRight - start) / 4
        barlineX = [left] + (1...3).map { (start + Double($0) * width).rounded() } + [SheetV5.staffRight]

        for (system, top) in SheetV5.tops.enumerated() {
            let place = { (glyph: StaffGlyph, x: Double, y: Double) -> CGPath in
                let t = CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: x, ty: y)
                return cgPath(glyph.commands).copy(using: [t])!
            }
            let clef = StaffSignatureLayout.clefFrame
            fills.append(place(.trebleClef, left + clef.x * k, top + clef.y * k))
            for a in signature.accidentals {
                let glyph: StaffGlyph = a.accidental == .flat ? .flat : .sharp
                fills.append(place(glyph, left + a.left * k, top + (a.pitchY - glyph.anchorY) * k))
            }
            if system == 0 {
                let centre = timeLeft + timeWidth / 2
                for (digit, y) in [(numerator, StaffSignatureLayout.timeNumeratorY), (denominator, StaffSignatureLayout.timeDenominatorY)] {
                    let t = CGAffineTransform(translationX: centre - digit.width / 2, y: top + y * k)
                    fills.append(digit.path.copy(using: [t])!)
                }
            }
        }
    }

    var staffLineY: [[Double]] { SheetV5.tops.map { top in (0..<5).map { top + Double($0) * SheetV5.staffSpace } } }

    // Strokes as (from, to, width) in logical units.
    var strokes: [(CGPoint, CGPoint, Double)] {
        var result: [(CGPoint, CGPoint, Double)] = []
        for (system, lines) in staffLineY.enumerated() {
            for y in lines { result.append((CGPoint(x: SheetV5.staffLeft, y: y), CGPoint(x: SheetV5.staffRight, y: y), SheetV5.lineWidth)) }
            let top = lines[0], bottom = lines[4]
            for (index, x) in barlineX.enumerated() {
                if system == 1 && index == 4 { continue }
                result.append((CGPoint(x: x, y: top), CGPoint(x: x, y: bottom), SheetV5.lineWidth))
            }
            if system == 1 {
                result.append((CGPoint(x: SheetV5.finalThin, y: top), CGPoint(x: SheetV5.finalThin, y: bottom), SheetV5.lineWidth))
                result.append((CGPoint(x: SheetV5.staffRight, y: top), CGPoint(x: SheetV5.staffRight, y: bottom), SheetV5.finalThickWidth))
            }
        }
        return result
    }

    func png() throws -> Data {
        let w = Int(SheetV5.logical.width) * SheetV5.exportScale, h = Int(SheetV5.logical.height) * SheetV5.exportScale
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Flip to y-down logical units.
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: CGFloat(SheetV5.exportScale), y: -CGFloat(SheetV5.exportScale))
        ctx.setShouldAntialias(true)
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.setStrokeColor(black); ctx.setFillColor(black); ctx.setLineCap(.butt)
        for (a, b, width) in strokes { ctx.setLineWidth(width); ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath() }
        for path in fills { ctx.addPath(path); ctx.fillPath(using: .winding) }
        guard let image = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return out as Data
    }

    func svg() -> String {
        var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"2660\" height=\"1692\" viewBox=\"0 0 1330 846\"><rect width=\"1330\" height=\"846\" fill=\"white\"/>"
        for (a, b, width) in strokes {
            s += "<path d=\"M\(a.x) \(a.y)L\(b.x) \(b.y)\" stroke=\"black\" stroke-width=\"\(width)\"/>"
        }
        for path in fills { s += "<path d=\"\(svgData(path))\" fill=\"black\"/>" }
        return s + "</svg>"
    }
}

struct LayoutFile: Encodable {
    struct System: Encodable { let index, first_measure, last_measure: Int; let staff_line_y, barline_x: [Double] }
    let id: String
    var logical_width = 1330, logical_height = 846, export_scale = 2, pixel_width = 2660, pixel_height = 1692
    let template_png_url: String; let template_sha256: String
    let systems: [System]; let display_height: Int
}

// Every key/meter combination that currently has a v4 sheet gets a v5 sheet.
func meters(in sheets: URL) throws -> [Meter] {
    let pattern = try NSRegularExpression(pattern: #"^staff-8bars-(\d+)-(\d+)-key(-?\d+)-v4\.layout\.json$"#)
    return try FileManager.default.contentsOfDirectory(atPath: sheets.path).compactMap { name in
        guard let m = pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { return nil }
        let g = (1...3).map { Int(name[Range(m.range(at: $0), in: name)!])! }
        return Meter(n: g[0], d: g[1], fifths: g[2])
    }.sorted { ($0.n, $0.d, $0.fifths) < ($1.n, $1.d, $1.fifths) }
}

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let sheets = root.appendingPathComponent("backend/content/sheets")
var written = 0, kept = 0
for meter in try meters(in: sheets) {
    let png = sheets.appendingPathComponent(meter.id + ".png")
    let layoutURL = sheets.appendingPathComponent(meter.id + ".layout.json")
    if FileManager.default.fileExists(atPath: png.path) { kept += 1; continue }
    let sheet = Sheet(meter)
    let data = try sheet.png()
    try data.write(to: png)
    try sheet.svg().write(to: sheets.appendingPathComponent(meter.id + ".svg"), atomically: true, encoding: .utf8)
    let systems: [LayoutFile.System] = (0..<2).map { i in
        LayoutFile.System(index: i + 1, first_measure: i * 4 + 1, last_measure: i * 4 + 4,
                          staff_line_y: sheet.staffLineY[i], barline_x: sheet.barlineX)
    }
    let layout = LayoutFile(id: meter.id, template_png_url: "https://api.sori.example/assets/sheets/\(meter.id).png",
                            template_sha256: data.sha256, systems: systems, display_height: SheetV5.displayHeight)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var json = try encoder.encode(layout)
    json.append(0x0A)
    try json.write(to: layoutURL)
    written += 1
}
print("v5 sheets: \(written) rendered, \(kept) already present (left unchanged)")
