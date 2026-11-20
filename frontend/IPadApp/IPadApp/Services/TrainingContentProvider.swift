import Foundation

enum DemoContent {
    static var hasFullBank: Bool { Bundle.main.url(forResource:"practice-bank-catalog",withExtension:"json") != nil }
    static func data(_ name: String, forceSmall: Bool = false) throws -> Data {
        if hasFullBank && !forceSmall { return try Bundled.data(name,ext:"json") }
        struct Index: Decodable { var files: [String:String] }
        let index: Index = try Bundled.decode("small-demo-index")
        guard let file = index.files[name] else { throw SolfegeError.configuration("데모에 포함되지 않은 문제 자료입니다.") }
        guard let url = Bundle.main.url(forResource:file,withExtension:nil) else { throw SolfegeError.storage("데모 문제 파일이 없습니다.") }
        return try Data(contentsOf:url)
    }
    static func decode<T: Decodable>(_ name: String, forceSmall: Bool = false) throws -> T {
        try ContractJSON.decoder().decode(T.self,from:data(name,forceSmall:forceSmall))
    }
}

@MainActor final class TrainingContentProvider {
    private let api: any ExamAPI
    private let cache: ImmutableContentCache
    private let pinned: URL
    private var manifest: ContentManifest?
    init(connection: RhythmConnection) throws {
        api = connection.api; cache = try ImmutableContentCache(scope:api.scope)
        pinned = try LocalStore(scope:connection.scope).root.appendingPathComponent("training-content",isDirectory:true)
        try FileManager.default.createDirectory(at:pinned,withIntermediateDirectories:true)
    }
    private func catalog() async throws -> ContentManifest {
        if let manifest { return manifest }
        let url = pinned.appendingPathComponent("manifest.json")
        let previous = (try? Data(contentsOf:url)).flatMap { try? ContractJSON.decoder().decode(ContentManifest.self,from:$0) }
        let modified = (try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let previous, (Date().timeIntervalSince(modified)<900 || !NetworkStatus.shared.online) {
            try previous.validate(); manifest = previous; return previous
        }
        do {
            let fresh = try await api.contentManifest(); try fresh.validate(); try Task.checkCancellation()
            try ContractJSON.encoder().encode(fresh).write(to:url,options:.atomic); manifest = fresh; return fresh
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if case SolfegeError.server(let code,_,_) = error, code == 401 { throw error }
            if let previous { try previous.validate(); manifest = previous; return previous }
            throw error
        }
    }
    func data(_ name: String) async throws -> Data {
        let catalog = try await catalog()
        guard let asset = catalog.assets[name] else { throw SolfegeError.configuration("서버에 문제 자료가 없습니다: \(name)") }
        let isCatalog = ["memory-run-v2.json","memory-groove-v1.json","rhythm-puzzle-v1.json",
                         "rhythm-puzzle-v2.json","rhythm-puzzle-v3.json","rhythm-engraving-v3.json"].contains(name)
        // A resumed Rhythm draft needs its catalog even after the LRU cache is trimmed.
        let pin = pinned.appendingPathComponent(name)
        if isCatalog, let data = try? Data(contentsOf:pin), data.sha256 == asset.sha256, data.count == asset.sizeBytes { return data }
        let bytes: Data
        if let cached = try cache.read(sha:asset.sha256,limit:asset.sizeBytes), cached.count == asset.sizeBytes { bytes = cached }
        else {
            bytes = try await api.contentAsset(asset); try Task.checkCancellation()
            try cache.store(bytes,sha:asset.sha256)
        }
        if isCatalog { try bytes.write(to:pin,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication]) }
        return bytes
    }
}
