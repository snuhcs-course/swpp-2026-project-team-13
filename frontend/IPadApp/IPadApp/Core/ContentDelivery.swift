import Foundation

struct ContentAsset: Codable, Equatable {
    var url: URL
    var sha256: String
    var sizeBytes: Int
    var contentType: String
    var isValid: Bool {
        ImmutableContentCache.validHash(sha256) && (1...8_388_608).contains(sizeBytes) &&
        ["application/json","application/xml"].contains(contentType)
    }
}
struct ContentManifest: Codable {
    var version: Int
    var assets: [String:ContentAsset]
    func validate() throws {
        guard version == 1, assets.count <= 5000,
              assets.allSatisfy({ name,asset in !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 240 && !name.contains("/") && !name.contains("\\") && asset.isValid }) else {
            throw SolfegeError.configuration("서버의 문제 자료 목록을 확인해 주세요.")
        }
    }
}

// Only reproducible server content belongs here. Student answers and active
// attempt files live separately in LocalStore's Application Support directory.
final class ImmutableContentCache {
    let root: URL
    let maximumBytes: Int
    init(root: URL, maximumBytes: Int = 100*1024*1024) throws {
        self.root = root; self.maximumBytes = maximumBytes
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    convenience init(scope: String) throws {
        let caches = try FileManager.default.url(for:.cachesDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
        try self.init(root:caches.appendingPathComponent("SolfegeContent",isDirectory:true).appendingPathComponent(Data(scope.utf8).sha256,isDirectory:true))
    }
    static func validHash(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func file(_ sha: String) throws -> URL {
        guard Self.validHash(sha) else { throw SolfegeError.configuration("문제 파일 식별자가 올바르지 않습니다.") }
        return root.appendingPathComponent(sha+".blob")
    }
    func read(sha: String, limit: Int) throws -> Data? {
        let url = try file(sha)
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= limit else { try? FileManager.default.removeItem(at:url); return nil }
        let data = try Data(contentsOf:url)
        guard data.sha256 == sha else { try? FileManager.default.removeItem(at:url); return nil }
        try? FileManager.default.setAttributes([.modificationDate:Date()],ofItemAtPath:url.path)
        return data
    }
    func store(_ data: Data, sha: String) throws {
        guard data.sha256 == sha, data.count <= maximumBytes else { throw SolfegeError.invalidScore("문제 파일의 해시나 크기가 다릅니다.") }
        try data.write(to:file(sha),options:.atomic)
        try trim()
    }
    func trim() throws {
        let urls = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey])
        let files = try urls.filter { $0.pathExtension == "blob" }.map { url -> (URL,Int,Date) in
            let values = try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
            return (url,values.fileSize ?? 0,values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = files.reduce(0) { $0+$1.1 }
        for (url,size,_) in files where total > maximumBytes { try FileManager.default.removeItem(at:url); total -= size }
    }
}
