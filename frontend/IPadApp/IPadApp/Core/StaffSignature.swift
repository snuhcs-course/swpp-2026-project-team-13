import Foundation

// Opening of a treble staff on the question intro screens (S9 / S16): clef, key signature
// and time signature. Units follow the wireframe: one staff space is 20, the top staff
// line is y = 0 and the bottom line y = 80. Every glyph is anchored to the staff
// position it represents, never to a font's line box.
struct StaffSignatureLayout: Equatable {
    enum Accidental: Equatable { case flat, sharp }
    struct KeyAccidental: Equatable {
        let accidental: Accidental
        let step: String
        let pitchY: Double   // staff line or space the glyph marks
        let left: Double     // left edge of the glyph
    }

    static let space = 20.0
    static let staffWidth = 660.0
    static let lineWidth = 2.5
    static let clefFrame = (x: 18.33, y: -28.96, width: 51.2, height: 142.25)
    static let accidentalStart = 95.22
    static let accidentalStep = 25.0
    static let timeSignatureGap = 20.4
    // Digits fill exactly two spaces, minus the line thickness, so they sit between lines.
    static let timeDigitHeight = 2*space - lineWidth
    static let timeNumeratorY = space
    static let timeDenominatorY = 3*space

    // Standard treble-clef order and placement, in half-spaces below the top line.
    static let sharpSteps: [(String, Int)] = [("F",0),("C",3),("G",-1),("D",2),("A",5),("E",1),("B",4)]
    static let flatSteps: [(String, Int)] = [("B",4),("E",1),("A",5),("D",2),("G",6),("C",3),("F",7)]

    let accidentals: [KeyAccidental]
    let keyEnd: Double

    init(fifths: Int) {
        let count = min(7, abs(fifths))
        let kind: Accidental = fifths < 0 ? .flat : .sharp
        let steps = kind == .flat ? Self.flatSteps : Self.sharpSteps
        accidentals = (0..<count).map { k in
            KeyAccidental(accidental:kind, step:steps[k].0, pitchY:Double(steps[k].1)*Self.space/2,
                          left:Self.accidentalStart+Double(k)*Self.accidentalStep)
        }
        if let last = accidentals.last {
            keyEnd = last.left + (kind == .flat ? StaffGlyph.flat.width : StaffGlyph.sharp.width)
        } else {
            keyEnd = Self.clefFrame.x + Self.clefFrame.width
        }
    }
    var timeSignatureLeft: Double { keyEnd + Self.timeSignatureGap }
}

// Vector outlines taken from the wireframe (Figma file, S9/S16 notation frames), drawn at
// one staff space = 20. `anchorY` is the glyph's musical reference point measured from its top.
struct StaffGlyph {
    let width: Double; let height: Double; let anchorY: Double
    let commands: [RhythmVectorCommand]

    // Treble clef; its spiral centres on the G line (y = 60) when the top sits at y = -28.96.
    static let trebleClef = StaffGlyph(width:51.201, height:142.253, anchorY:88.96, svg:"M33.6007 105.44C32.0006 105.765 30.4881 105.927 28.9631 105.927C17.5254 105.927 7.76266 97.9268 7.76266 85.8391C7.76266 76.0889 14.6378 67.3637 21.688 61.2761C23.038 60.0761 24.3255 58.9636 25.5255 57.7636C26.238 62.0761 26.8005 65.8387 27.363 69.1263C20.0754 71.2888 15.1253 78.964 15.1253 86.4891C15.1253 92.0892 19.5254 99.7644 25.9256 99.7644C26.563 99.7644 27.2881 99.4394 27.2881 98.7269C27.2881 98.0019 26.488 97.6019 25.5255 96.9643C22.4004 95.0393 20.6379 92.9643 20.6379 89.0392C20.6379 84.1641 24.238 80.239 28.9631 79.1265L33.6007 105.44ZM26.563 23.2004C27.2881 20.0003 30.9631 11.6002 35.1257 11.6002C36.3258 11.6002 38.2383 15.5127 38.2383 21.0378C38.2383 29.363 32.0882 35.6006 26.563 41.0382C26.088 37.8381 25.688 34.7256 25.688 31.363C25.688 28.4005 25.9256 25.6754 26.563 23.2004ZM44.9634 90.6392C44.9634 96.3268 42.6384 102.164 36.9632 104.49C35.2882 94.8893 33.1257 82.164 32.5631 78.6389C39.7633 78.6389 44.9634 83.5266 44.9634 90.6392ZM9.76268 130.003C9.76268 135.29 13.8378 142.253 24.638 142.253C28.4006 142.253 31.6882 141.29 34.5632 139.528C38.8883 136.49 40.0008 131.203 40.0008 126.165C40.0008 123.052 39.5258 119.452 38.7258 114.89C38.4883 113.29 38.0008 110.89 37.5258 107.765C45.3634 105.202 51.201 97.0394 51.201 88.8017C51.201 76.7264 42.6384 68.5638 30.9631 68.5638C30.1631 63.7637 29.3631 59.0385 28.6381 54.5635C37.1258 45.6758 42.9633 35.6756 42.9633 22.9629C42.9633 15.6752 40.7259 9.7626 39.4383 6.87534C37.5258 2.80006 35.2007 0 33.7632 0C33.2007 0 30.7257 0.962421 28.0881 4.07528C22.9629 10.1626 21.5255 20.4003 21.5255 27.1129C21.5255 31.438 21.9255 35.3631 23.288 44.3258C23.2005 44.4008 19.0379 48.6383 17.3628 50.0009C10.0752 56.8011 0 66.4762 0 82.489C0 97.4394 13.0378 109.202 27.9256 109.202C30.2381 109.202 32.4007 108.965 34.2382 108.64C35.7632 116.327 36.6383 121.927 36.6383 126.165C36.6383 134.49 32.4006 138.89 24.3255 138.89C22.4004 138.89 20.7255 138.49 20.5629 138.49C20.4879 138.403 20.3254 138.328 20.3254 138.253C20.3254 138.09 20.4879 138.003 20.7255 137.928C24.488 137.365 28.2381 134.165 28.2381 129.052C28.2381 124.727 24.963 120.165 18.9629 120.165C13.3627 120.165 9.76268 124.727 9.76268 130.003Z")

    // Flat; the bowl's centre (anchorY) sits on the flattened note's line or space.
    static let flat = StaffGlyph(width:16.2378, height:50.3136, anchorY:36.24, svg:"M10.5627 33.0382C10.5627 39.3633 7.27515 42.7134 2.63756 46.4009L2.87506 30.8006C3.03756 30.0756 4.23759 27.763 7.43765 27.763C10.3252 27.763 10.5627 30.4756 10.5627 32.1632V33.0382ZM9.60019 23.838C5.60011 23.838 3.27507 26.313 2.87506 26.8005L3.20006 1.1125C3.20006 0.475051 2.72505 0 2.07504 0H1.12502C0.47501 0 0 0.475051 0 1.1125L0.400008 49.201C0.400008 49.8385 0.875017 50.3136 1.52503 50.3136C1.67503 50.3136 2.00004 50.2385 2.16255 50.1636C9.0377 46.7135 16.2378 40.1633 16.2378 31.9132C16.2378 27.763 14.3253 23.838 9.60019 23.838Z")

    // Sharp drawn to the flat's weight: two thin stems and two heavy beams rising to the
    // right, one space apart, centred (anchorY) on the sharpened note's line or space.
    static let sharp = StaffGlyph(width:19.6, height:56, anchorY:28, svg:
        // left stem (lower) and right stem (higher) follow the beams' slope
        "M4.8 2.6H7.6V56H4.8Z" +
        "M12.0 0H14.8V53.4H12.0Z" +
        // upper and lower beams: 5.6 thick, rising 4.4 across the glyph, centred at
        // y = 18 and 38 so the note's line or space (y = 28) lies between them
        "M0 17.4L19.6 13.0V18.6L0 23.0Z" +
        "M0 37.4L19.6 33.0V38.6L0 43.0Z")

    // Quarter note for the tempo mark (♩ = n), 72pt text scale.
    static let quarterNote = StaffGlyph(width:24.531, height:71.7965, anchorY:71.7965, svg:"M0 64.9325C0 68.1758 2.33516 71.7965 8.4561 71.7965C16.299 71.7965 24.531 65.3807 24.531 58.7408C24.531 54.2827 20.757 51.7943 16.0749 51.7943C8.751 51.7943 0 57.986 0 64.9325ZM24.52 0H21.32V59.5H24.52V0Z")

    init(width: Double, height: Double, anchorY: Double, svg: String) {
        self.width = width; self.height = height; self.anchorY = anchorY
        commands = SVGPathData.commands(svg)
    }
}

// Minimal parser for the absolute SVG path commands the wireframe export uses (M L H V C Z).
enum SVGPathData {
    static func commands(_ data: String) -> [RhythmVectorCommand] {
        var tokens: [String] = [], number = ""
        func flush() { if !number.isEmpty { tokens.append(number); number = "" } }
        for ch in data {
            if "MLHVCZ".contains(ch) { flush(); tokens.append(String(ch)) }
            else if ch == " " || ch == "," { flush() }
            else if ch == "-" && !number.isEmpty && !number.hasSuffix("e") { flush(); number = "-" }
            else { number.append(ch) }
        }
        flush()
        var result: [RhythmVectorCommand] = [], op = "", values: [Double] = [], current = (x:0.0, y:0.0)
        func emit() {
            let arity = ["M":2,"L":2,"H":1,"V":1,"C":6][op] ?? 0
            guard arity > 0 else { return }
            var index = 0, first = true
            while index+arity <= values.count {
                let v = Array(values[index..<index+arity]); index += arity
                switch op {
                case "H": current.x = v[0]; result.append(RhythmVectorCommand(op:"L", values:[current.x,current.y]))
                case "V": current.y = v[0]; result.append(RhythmVectorCommand(op:"L", values:[current.x,current.y]))
                default:
                    // Extra pairs after a moveto are implicit linetos.
                    result.append(RhythmVectorCommand(op:op == "M" && !first ? "L" : op, values:v))
                    current = (v[arity-2], v[arity-1])
                }
                first = false
            }
            values = []
        }
        for token in tokens {
            if token.count == 1, "MLHVCZ".contains(token) {
                emit(); op = token
                if token == "Z" { result.append(RhythmVectorCommand(op:"Z", values:[])) }
            } else if let value = Double(token) { values.append(value) }
        }
        emit()
        return result
    }
}
