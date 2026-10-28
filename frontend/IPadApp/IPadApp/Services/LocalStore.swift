import Foundation
import PencilKit
import Security

struct PlaybackCursor: Codable, Equatable {
    var index = 0 // 0 = scale, 1...11 = main, 12 = finished
    var phase = "initial" // initial, segment, gap; legacy saved phases still decode
    var remainingWaitMs: Int? = nil
}
struct SessionRecord: Codable, Identifiable {
    var id: UUID { attempt.id }
    var attempt: Attempt
    var cursor = PlaybackCursor()
    var frozen = false
    var clientAnswerId: UUID?
    var uploadKey: UUID?
    var submitKey: UUID?
    var uploaded: Answer?
    var gradingRetryKey: UUID?
    var grading: Grading?
    var hasDrawing = false
    var parserVersion = MusicXMLParser.version
}
struct PendingCreation: Codable { var question: Question; var key: UUID }

final class LocalStore {
    let root: URL
    init(scope: String) throws {
        let app = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        root = app.appendingPathComponent("SORI", isDirectory: true).appendingPathComponent(Data(scope.utf8).sha256, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var r = root; try r.setResourceValues(values)
    }
    func folder(_ id: UUID) throws -> URL {
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    func save(_ record: SessionRecord) throws { try ContractJSON.encoder().encode(record).write(to: folder(record.id).appendingPathComponent("session.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    func load(_ id: UUID) throws -> SessionRecord { try ContractJSON.decoder().decode(SessionRecord.self, from: Data(contentsOf: folder(id).appendingPathComponent("session.json"))) }
    func all() throws -> [SessionRecord] {
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return try urls.filter { UUID(uuidString: $0.lastPathComponent) != nil }.map { try load(UUID(uuidString: $0.lastPathComponent)!) }.sorted { $0.attempt.createdAt > $1.attempt.createdAt }
    }
    func pending() throws -> PendingCreation? {
        let file = root.appendingPathComponent("pending-create.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try ContractJSON.decoder().decode(PendingCreation.self, from: Data(contentsOf: file))
    }
    func savePending(_ value: PendingCreation?) throws {
        let file = root.appendingPathComponent("pending-create.json")
        if let value { try ContractJSON.encoder().encode(value).write(to: file, options: .atomic) }
        else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    func write(_ data: Data, name: String, id: UUID) throws { try data.write(to: folder(id).appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    func read(_ name: String, id: UUID) throws -> Data { try Data(contentsOf: folder(id).appendingPathComponent(name)) }
    func exists(_ name: String, id: UUID) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString).appendingPathComponent(name).path) }
}

enum TokenVault {
    static let service = "org.snuhcs.team13.sori.development-token"
    static func account(_ server: String) throws -> String {
        guard let url = URL(string: server), let origin = Origin(url) else { throw SORIError.configuration("API 주소를 확인해 주세요.") }
        return origin.key
    }
    static func read(server: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: try account(server), kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw SORIError.storage("Keychain에서 토큰을 읽을 수 없습니다.") }; return value
    }
    static func save(_ value: String, server: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: try account(server)]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw SORIError.storage("Keychain에 토큰을 저장하지 못했습니다.") }
        } else if result != errSecSuccess { throw SORIError.storage("Keychain의 토큰을 갱신하지 못했습니다. (\(result))") }
    }
    static func delete(server: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: try account(server)]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SORIError.storage("Keychain의 토큰을 삭제하지 못했습니다.") }
    }
}

enum Bundled {
    static func data(_ name: String, ext: String) throws -> Data {
        // Raw PNG extension prevents Xcode pngcrush from changing contract-pinned bytes.
        let raw = ext == "png" ? Bundle.main.url(forResource: name, withExtension: "pngdata") : nil
        guard let url = raw ?? Bundle.main.url(forResource: name, withExtension: ext) else { throw SORIError.storage("번들 리소스가 없습니다: \(name).\(ext)") }; return try Data(contentsOf: url)
    }
    static func decode<T: Decodable>(_ name: String) throws -> T { try ContractJSON.decoder().decode(T.self, from: data(name, ext: "json")) }
}
