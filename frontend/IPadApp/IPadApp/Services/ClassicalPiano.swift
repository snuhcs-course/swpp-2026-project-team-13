import Foundation

// One pinned bank, velocity layer and gain for exams, scales and Melody Run.
struct ClassicalPiano: Decodable {
    var resource: String
    var program: UInt8
    var bankMsb: UInt8
    var bankLsb: UInt8
    var noteVelocity: UInt8
    var gainDb: Float
    var url: URL {
        Bundle.main.url(forResource:resource,withExtension:nil)!
    }
    static func load() throws -> ClassicalPiano {
        struct Bank: Decodable { var sha256: String; var sizeBytes: Int }
        let profile: ClassicalPiano = try Bundled.decode("melody-piano-profile")
        guard let url = Bundle.main.url(forResource:profile.resource,withExtension:nil) else {
            throw SORIError.invalidScore("클래식 피아노 음원이 포함된 최신 앱으로 설치해 주세요.")
        }
        let descriptor: Bank = try Bundled.decode("melody-piano-bank")
        let bytes = try Data(contentsOf:url,options:.mappedIfSafe)
        guard bytes.count == descriptor.sizeBytes, bytes.sha256 == descriptor.sha256 else {
            throw SORIError.invalidScore("클래식 피아노 음원 검증에 실패했어요.")
        }
        return profile
    }
}
