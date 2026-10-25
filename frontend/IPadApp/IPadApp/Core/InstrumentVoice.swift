import Foundation

struct InstrumentVoice: Codable, Identifiable, Equatable {
    var id: String; var title: String; var program: UInt8; var gainDb: Float
}
struct InstrumentChoices: Codable {
    var defaultVoice: String; var voices: [InstrumentVoice]
}
