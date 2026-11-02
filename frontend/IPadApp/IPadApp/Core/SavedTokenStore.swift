import Foundation

// Explicitly opted-in development credentials, stored in the existing app data
// container so re-signing an update cannot strand them in another Keychain group.
struct SavedTokenStore {
    let directory: URL
    let secureRead: (String) throws -> String
    let secureSave: (String, String) throws -> Void
    let secureDelete: (String) throws -> Void
    private struct Record: Codable { var server: String; var token: String }

    static func account(_ server: String) -> String {
        let text = server.trimmingCharacters(in:.whitespacesAndNewlines)
        guard var url = URLComponents(string:text), let scheme = url.scheme, let host = url.host else { return text }
        url.scheme = scheme.lowercased(); url.host = host.lowercased()
        if (url.scheme == "https" && url.port == 443) || (url.scheme == "http" && url.port == 80) { url.port = nil }
        url.path = url.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        url.path = "/" + url.path + "/"
        return url.string ?? text
    }
    private func file(_ server: String) -> URL {
        directory.appendingPathComponent(Data(Self.account(server).utf8).sha256+".json")
    }
    func read(server: String) throws -> String {
        let account = Self.account(server), path = file(server)
        if FileManager.default.fileExists(atPath:path.path) {
            let record = try JSONDecoder().decode(Record.self,from:Data(contentsOf:path))
            guard record.server == account else { throw SORIError.storage("저장된 서버 주소가 일치하지 않습니다.") }
            return record.token
        }
        // Migrate the previous exact-string Keychain account after a successful
        // connection. Read errors also cover changed signing access groups.
        if let value = try? secureRead(account), !value.isEmpty { return value }
        if account != server, let value = try? secureRead(server), !value.isEmpty { return value }
        return ""
    }
    func save(_ token: String, server: String) throws {
        let value = token.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty else { throw SORIError.configuration("저장할 개발 토큰을 입력해 주세요.") }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var root = directory, resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try root.setResourceValues(resources)
        let data = try JSONEncoder().encode(Record(server:Self.account(server),token:value))
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        let path = file(server)
        try data.write(to:path,options:options)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        // A protected local copy remains usable if re-signing changed access to
        // the old Keychain group. No token is written to UserDefaults or logs.
        try? secureSave(value,Self.account(server))
    }
    func delete(server: String) throws {
        let path = file(server)
        if FileManager.default.fileExists(atPath:path.path) { try FileManager.default.removeItem(at:path) }
        try? secureDelete(Self.account(server))
        if Self.account(server) != server { try? secureDelete(server) }
    }
}
