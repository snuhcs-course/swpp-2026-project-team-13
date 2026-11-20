import XCTest
import Foundation
@testable import SolfegeCore

final class ContentDeliveryTests: XCTestCase {
    func testCacheEvictsOnlyOldReproducibleFilesAndRejectsCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let cache = try ImmutableContentCache(root:root,maximumBytes:8)
        let student = root.appendingPathComponent("drawing.pkdrawing")
        try Data("student".utf8).write(to:student)
        let a = Data("aaaa".utf8), b = Data("bbbb".utf8), c = Data("cccc".utf8)
        try cache.store(a,sha:a.sha256); try cache.store(b,sha:b.sha256)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1)],ofItemAtPath:root.appendingPathComponent(a.sha256+".blob").path)
        try cache.store(c,sha:c.sha256)
        XCTAssertNil(try cache.read(sha:a.sha256,limit:4))
        XCTAssertEqual(try cache.read(sha:b.sha256,limit:4),b)
        XCTAssertEqual(try Data(contentsOf:student),Data("student".utf8))
        try a.write(to:root.appendingPathComponent(b.sha256+".blob"))
        XCTAssertNil(try cache.read(sha:b.sha256,limit:4))
        XCTAssertThrowsError(try cache.read(sha:"../drawing",limit:4))
        XCTAssertThrowsError(try cache.store(a,sha:c.sha256))
    }
    func testManifestRejectsPathsAndUnsupportedFiles() throws {
        let asset = ContentAsset(url:URL(string:"https://api.example/content/a")!,sha256:String(repeating:"a",count:64),sizeBytes:4,contentType:"application/xml")
        try ContentManifest(version:1,assets:["melody.xml":asset]).validate()
        for name in ["../melody.xml","..","a/b","a\\b"] {
            XCTAssertThrowsError(try ContentManifest(version:1,assets:[name:asset]).validate())
        }
        var bad = asset; bad.sizeBytes = 8_388_609
        XCTAssertThrowsError(try ContentManifest(version:1,assets:["a.xml":bad]).validate())
    }
}

@MainActor final class ContentDeliveryHTTPTests: XCTestCase {
    func testAuthenticatedJSONAndXMLWithSameOriginAndIntegrityValidation() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let api = try HTTPExamAPI(base:URL(string:"https://api.example/api/v1/")!,token:"test-token",session:URLSession(configuration:config))
        let xml = Data("<score-partwise/>".utf8)
        var asset = ContentAsset(url:URL(string:"https://api.example/api/v1/content/assets/\(xml.sha256)/")!,sha256:xml.sha256,sizeBytes:xml.count,contentType:"application/xml")
        let manifest = try ContractJSON.encoder().encode(ContentManifest(version:1,assets:["score.xml":asset]))
        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer test-token")
            if request.url?.lastPathComponent == "manifest" { return (200,"application/json",manifest) }
            XCTAssertEqual(request.value(forHTTPHeaderField:"Accept"),"application/xml")
            return (200,"application/xml",xml)
        }
        defer { StubProtocol.handler = nil }
        let response = try await api.contentManifest()
        XCTAssertEqual(response.assets["score.xml"],asset)
        let bytes = try await api.contentAsset(asset); XCTAssertEqual(bytes,xml)
        asset.url = URL(string:"https://other.example/score.xml")!
        do { _ = try await api.contentAsset(asset); XCTFail("Cross-origin content must be rejected") } catch { }
    }
}
