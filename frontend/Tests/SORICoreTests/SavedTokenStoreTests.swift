import XCTest
@testable import SORICore

final class SavedTokenStoreTests: XCTestCase {
    private func store(_ directory: URL, legacy: String = "") -> SavedTokenStore {
        SavedTokenStore(directory:directory,secureRead:{ _ in legacy },secureSave:{ _,_ in throw SORIError.storage("Keychain unavailable after re-signing") },secureDelete:{ _ in })
    }
    func testOptedInTokenSurvivesRecreatedStoreAndUnavailableKeychain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        try store(directory).save("sample-development-token",server:"https://API.example:443/api/v1/")
        let updatedApp = SavedTokenStore(directory:directory,secureRead:{ _ in throw SORIError.storage("Changed signing group") },secureSave:{ _,_ in },secureDelete:{ _ in })
        XCTAssertEqual(try updatedApp.read(server:"https://api.example/api/v1"),"sample-development-token")
        XCTAssertEqual(try updatedApp.read(server:"https://another.example/api/v1/"),"")
        let files = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
        XCTAssertEqual(files.count,1)
        let attributes = try FileManager.default.attributesOfItem(atPath:files[0].path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o600)
        XCTAssertEqual(try directory.resourceValues(forKeys:[.isExcludedFromBackupKey]).isExcludedFromBackup,true)
    }
    func testLegacyKeychainTokenCanBeMigratedAfterSuccessfulConnection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let old = store(directory,legacy:"legacy-token")
        let value = try old.read(server:"http://192.168.0.10:8000/api/v1/")
        XCTAssertEqual(value,"legacy-token")
        try old.save(value,server:"http://192.168.0.10:8000/api/v1/")
        XCTAssertEqual(try store(directory).read(server:"http://192.168.0.10:8000/api/v1/"),value)
    }
    func testTurningStorageOffRemovesOnlyTheSelectedServersToken() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let vault = store(directory)
        try vault.save("first-token",server:"https://first.example/api/v1/")
        try vault.save("second-token",server:"https://second.example/api/v1/")
        try vault.delete(server:"https://first.example/api/v1/")
        XCTAssertEqual(try store(directory).read(server:"https://first.example/api/v1/"),"")
        XCTAssertEqual(try store(directory).read(server:"https://second.example/api/v1/"),"second-token")
    }
    func testAccountNormalizationDoesNotMergeDifferentPortsOrServers() {
        XCTAssertEqual(SavedTokenStore.account(" https://API.example:443/api/v1/ "),SavedTokenStore.account("https://api.example/api/v1"))
        XCTAssertNotEqual(SavedTokenStore.account("http://api.example:8000/api/v1/"),SavedTokenStore.account("http://api.example:8001/api/v1/"))
        XCTAssertNotEqual(SavedTokenStore.account("https://api.example/api/v1/"),SavedTokenStore.account("http://api.example/api/v1/"))
    }
}
