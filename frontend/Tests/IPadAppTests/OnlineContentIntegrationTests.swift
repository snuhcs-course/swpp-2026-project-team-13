import XCTest
import Foundation
@testable import IPadApp

final class DeliveryAppProtocol: URLProtocol {
    static var respond: ((URLRequest) throws -> (String,Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (mime,data) = try Self.respond!(request)
            let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":mime])!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() { }
}

@MainActor final class OnlineContentIntegrationTests: XCTestCase {
    func testTheTestHostUsesTheSameSlimPolicyAsDeviceInstallation() throws {
        struct Marker: Decodable { var mode: String }
        let marker: Marker = try Bundled.decode("bundled-content")
        XCTAssertEqual(marker.mode,"online")
        XCTAssertFalse(DemoContent.hasFullBank)
        XCTAssertNil(Bundle.main.url(forResource:"practice-layout-v2",withExtension:"json"))
        XCTAssertNil(Bundle.main.url(forResource:"memory-run-v3",withExtension:"json"))
        _ = try ClassicalPiano.load()
    }
    func testSmallDemoPreparesEveryQuestionAndAllMinigameLevels() async throws {
        let api = try DemoExamAPI(outcome:"completed",storageScope:UUID().uuidString,smallContent:true)
        defer { try? FileManager.default.removeItem(at:api.store.root) }
        let page = try await api.questions(page:1)
        XCTAssertEqual(page.results.count,3)
        let offer = try await api.examRecommendations()
        let ids = page.results.map(\.id) + offer.choices.compactMap(\.questionId)
        XCTAssertEqual(Set(ids).count,6)
        for id in ids {
            let q = try await api.question(id); try q.validate()
            for asset in [q.scoreAssets.main,q.scoreAssets.scale] {
                let bytes = try await api.asset(asset.url,authenticated:true,limit:1_048_576)
                XCTAssertEqual(bytes.sha256,asset.sha256)
                _ = try MusicXMLParser.parseMXL(bytes,asset:asset)
            }
            let template = try await api.asset(q.sheetLayout.templatePngUrl,authenticated:false,limit:10_485_760)
            _ = try AnswerExporter.validateTemplate(template,layout:q.sheetLayout)
            let image = try XCTUnwrap(q.correctScore)
            let bytes = try await api.asset(image.url,authenticated:true,limit:2_097_152)
            XCTAssertEqual(bytes.sha256,image.sha256)
        }
        let data = try DemoContent.data("memory-run-v3",forceSmall:true)
        var memory = try JSONDecoder().decode(MemoryCatalog.self,from:data)
        let groove: MemoryGroovePolicy = try DemoContent.decode("memory-groove-v2",forceSmall:true)
        try memory.applyGroovePolicy(groove,catalogSha256:data.sha256); try memory.validate()
        var rng = SystemRandomNumberGenerator()
        for level in MemoryDifficulty.allCases {
            for mode in [MelodyMode.memory,.groove] {
                let set = try memory.makeSet(level:level,mode:mode,using:&rng)
                XCTAssertEqual(set.map(\.bars),level.barPlan)
            }
        }
        let rhythm: RhythmCatalog = try DemoContent.decode("rhythm-puzzle-v4",forceSmall:true)
        try rhythm.validate()
        let ink: RhythmEngraving = try DemoContent.decode("rhythm-engraving-v4",forceSmall:true)
        XCTAssertEqual(ink.catalogSha256,try DemoContent.data("rhythm-puzzle-v4",forceSmall:true).sha256)
    }

    func testLiveModelsDownloadTheirCatalogsAndReuseVerifiedFiles() async throws {
        let base = URL(string:"https://content-\(UUID().uuidString.lowercased()).example/api/v1/")!
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DeliveryAppProtocol.self]
        let session = URLSession(configuration:config)
        let api = try HTTPExamAPI(base:base,token:"learner",session:session)
        let connection = RhythmConnection(api:api,profileId:UUID(),demo:false,generation:UUID())
        let storage = try LocalStore(scope:connection.scope)
        let cache = try ImmutableContentCache(scope:api.scope)
        defer {
            DeliveryAppProtocol.respond = nil; session.invalidateAndCancel()
            try? FileManager.default.removeItem(at:storage.root)
            try? FileManager.default.removeItem(at:cache.root)
        }
        var files: [String:Data] = [:]
        for name in ["memory-run-v3","memory-groove-v2","rhythm-puzzle-v4","rhythm-engraving-v4"] {
            files[name+".json"] = try DemoContent.data(name,forceSmall:true)
        }
        // Legacy versions remain downloadable for journals from an older app.
        files["rhythm-puzzle-v1.json"] = files["rhythm-puzzle-v4.json"]
        files["rhythm-puzzle-v2.json"] = files["rhythm-puzzle-v4.json"]
        files["rhythm-puzzle-v3.json"] = try DemoContent.data("rhythm-puzzle-v3",forceSmall:true)
        let memory = try JSONDecoder().decode(MemoryCatalog.self,from:try XCTUnwrap(files["memory-run-v3.json"]))
        let source = try XCTUnwrap(memory.sources.first)
        files[source.file] = try Data(contentsOf:XCTUnwrap(Bundle.main.url(forResource:source.file,withExtension:nil)))
        let assets = files.mapValues { bytes in ContentAsset(url:base.appendingPathComponent("content/assets/\(bytes.sha256)/"),sha256:bytes.sha256,sizeBytes:bytes.count,contentType:"application/json") }
        var descriptions = assets; descriptions[source.file]?.contentType = "application/xml"
        let manifest = try ContractJSON.encoder().encode(ContentManifest(version:1,assets:descriptions))
        var requests = 0
        var downloadedHashes = Set<String>()
        DeliveryAppProtocol.respond = { request in
            requests += 1
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer learner")
            if request.url?.lastPathComponent == "manifest" { return ("application/json",manifest) }
            downloadedHashes.insert(request.url!.lastPathComponent)
            let data = try XCTUnwrap(files.values.first { $0.sha256 == request.url?.lastPathComponent })
            return (request.value(forHTTPHeaderField:"Accept")!,data)
        }
        let melody = MelodyRunModel(connection:connection)
        XCTAssertNil(melody.catalog,"Live mode must not silently use the bundled bank")
        await melody.prepareContent(); XCTAssertNil(melody.error); XCTAssertNotNil(melody.catalog)
        let rhythm = RhythmPuzzleModel(connection:connection)
        XCTAssertNil(rhythm.catalog)
        await rhythm.prepareContent(); XCTAssertNil(rhythm.error); XCTAssertNotNil(rhythm.engraving)
        let oldData=try XCTUnwrap(files["rhythm-puzzle-v3.json"])
        XCTAssertFalse(downloadedHashes.contains(oldData.sha256),"A fresh player should not download historical banks")
        let oldBank=try ContractJSON.decoder().decode(RhythmCatalog.self,from:oldData)
        let oldRound=try XCTUnwrap(oldBank.rounds.first)
        var oldRecord=RhythmPlayRecord(catalogSha256:oldData.sha256,roundId:oldRound.id,choiceOrder:oldRound.choices,startedAt:Date(),finishedAt:Date())
        oldRecord.gameVersion=oldBank.version
        let store=try RhythmPuzzleStore(root:storage.root)
        try store.save(RhythmJournal(draft:RhythmDraft(setIds:[oldRound.id],index:0,record:oldRecord)))
        let recovered=RhythmPuzzleModel(connection:connection)
        await recovered.prepareContent(); XCTAssertNil(recovered.error)
        XCTAssertTrue(recovered.canResume,"An old unfinished answer must still load its own immutable bank")
        XCTAssertTrue(downloadedHashes.contains(oldData.sha256))
        let provider = try TrainingContentProvider(connection:connection)
        let xml = try await provider.data(source.file); XCTAssertEqual(xml.sha256,source.sha256)
        _ = try MelodyXMLParser.parse(xml)
        let count = requests
        let next = try TrainingContentProvider(connection:connection)
        _ = try await next.data(source.file); _ = try await next.data("memory-run-v3.json")
        XCTAssertEqual(requests,count,"Verified content should survive reopening a game without new requests")
    }

    func testReleasingCompletedAssetsPreservesTheStudentsWork() throws {
        let storage = try LocalStore(scope:"release-content-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:storage.root) }
        let id = UUID(), bytes = Data("preserve".utf8)
        for name in ["drawing.pkdrawing","submitted.png","answer.png","main.mxl","scale.mxl","template.png","correct-score.png"] {
            try storage.write(bytes,name:name,id:id)
        }
        try storage.releaseReproducibleAssets(id)
        for name in ["drawing.pkdrawing","submitted.png","answer.png"] { XCTAssertEqual(try storage.read(name,id:id),bytes) }
        XCTAssertFalse(storage.exists("main.mxl",id:id)); XCTAssertFalse(storage.exists("correct-score.png",id:id))
    }
}
