import Foundation

struct CoachFeedback: Codable, Equatable {
    var headline: String
    var detail: String
    var kind: String
    var promptVersion: String
    var historyUsed: Bool
}

struct ReferenceGlyphCommand: Codable, Equatable {
    var op: String
    var values: [Double]
    var isValid: Bool {
        guard let count = ["M":2,"L":2,"C":6,"Q":4,"Z":0][op], values.count == count else { return false }
        return values.allSatisfy { $0.isFinite && (-0.1...1.1).contains($0) }
    }
}
struct ReferenceGlyph: Codable, Equatable {
    var bbox: BBox
    var commands: [ReferenceGlyphCommand]
    var isValid: Bool { bbox.isValid && commands.count <= 1024 && !commands.isEmpty && commands.allSatisfy(\.isValid) }
}
struct ReferenceAnnotation: Codable, Equatable, Identifiable {
    var id: String
    var measure: Int
    var style: String
    var message: String
    var bbox: BBox
    var glyphs: [ReferenceGlyph]
    var isValid: Bool {
        (1...8).contains(measure) && ["measure","glyph","underline"].contains(style) && bbox.isValid &&
        glyphs.count <= 128 && glyphs.allSatisfy(\.isValid) && (style == "measure" || !glyphs.isEmpty)
    }
}
