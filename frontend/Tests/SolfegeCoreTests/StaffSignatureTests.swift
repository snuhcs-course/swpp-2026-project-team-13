import XCTest
@testable import SolfegeCore

final class StaffSignatureTests: XCTestCase {
    // Top line F5 = 0, each half-space 10 down: E5 10, D5 20, C5 30, B4 40, A4 50, G4 60, F4 70.
    func testFlatsFollowTrebleOrderAndPositions() {
        let layout = StaffSignatureLayout(fifths:-7)
        XCTAssertEqual(layout.accidentals.map(\.step), ["B","E","A","D","G","C","F"])
        XCTAssertEqual(layout.accidentals.map(\.pitchY), [40,10,50,20,60,30,70])
        XCTAssertTrue(layout.accidentals.allSatisfy { $0.accidental == .flat })
    }

    func testSharpsFollowTrebleOrderAndPositions() {
        let layout = StaffSignatureLayout(fifths:7)
        XCTAssertEqual(layout.accidentals.map(\.step), ["F","C","G","D","A","E","B"])
        XCTAssertEqual(layout.accidentals.map(\.pitchY), [0,30,-10,20,50,10,40])
        XCTAssertTrue(layout.accidentals.allSatisfy { $0.accidental == .sharp })
    }

    // Matches the wireframe: B♭ major flats at x 95.22 and 120.22, and the time signature
    // numerals start one staff space after the last flat.
    func testWireframeSpacing() {
        let bFlat = StaffSignatureLayout(fifths:-2)
        XCTAssertEqual(bFlat.accidentals.map(\.left), [95.22,120.22])
        XCTAssertEqual(bFlat.timeSignatureLeft, 120.22+StaffGlyph.flat.width+20.4, accuracy:0.001)
        let dMinor = StaffSignatureLayout(fifths:-1)
        XCTAssertEqual(dMinor.accidentals.map(\.step), ["B"])
        XCTAssertLessThan(dMinor.timeSignatureLeft, bFlat.timeSignatureLeft)
    }

    func testNoKeySignatureStartsTimeAfterClef() {
        let layout = StaffSignatureLayout(fifths:0)
        XCTAssertTrue(layout.accidentals.isEmpty)
        XCTAssertEqual(layout.keyEnd, StaffSignatureLayout.clefFrame.x+StaffSignatureLayout.clefFrame.width, accuracy:0.001)
    }

    // The glyph's reference point lands on the staff position it marks.
    func testGlyphAnchors() {
        // Clef spiral on the G line.
        XCTAssertEqual(StaffSignatureLayout.clefFrame.y+StaffGlyph.trebleClef.anchorY, 60, accuracy:0.01)
        // Wireframe flat for B4 sits at y = 3.76 with its bowl on the middle line.
        XCTAssertEqual(3.76+StaffGlyph.flat.anchorY, 40, accuracy:0.01)
        // Sharp beams straddle its line/space symmetrically.
        XCTAssertEqual(StaffGlyph.sharp.anchorY, StaffGlyph.sharp.height/2, accuracy:0.001)
    }

    func testGlyphPathsParseCompletely() {
        for glyph in [StaffGlyph.trebleClef, .flat, .sharp, .quarterNote] {
            XCTAssertEqual(glyph.commands.first?.op, "M")
            XCTAssertTrue(glyph.commands.allSatisfy { ["M","L","C","Z"].contains($0.op) })
            let points = glyph.commands.flatMap { c in stride(from:0, to:c.values.count, by:2).map { (c.values[$0], c.values[$0+1]) } }
            XCTAssertTrue(points.allSatisfy { (-0.01...glyph.width+0.01).contains($0.0) && (-0.01...glyph.height+0.01).contains($0.1) })
        }
        XCTAssertEqual(SVGPathData.commands("M1 2H5V7L-1 -2Z").map(\.values), [[1,2],[5,2],[5,7],[-1,-2],[]])
    }

    func testIntroPlaybackOrderMatchesPlan() throws {
        let plan = PlaybackPlan.exam(meter:TimeSignature(numerator:3,denominator:4))
        try plan.validate()
        XCTAssertEqual(plan.steps.map { [$0.fromMeasure,$0.toMeasure] }, PlaybackPlan.examMeasureRanges.map { [$0.from,$0.to] })
        XCTAssertEqual(PlaybackPlan.examMeasureRanges.count, 11)
        XCTAssertEqual(plan.countIn?.beforeStepOrders, [1,11])
    }
}
