import Foundation

final class MemoryRunStore {
    let root: URL
    private var file: URL { root.appendingPathComponent("memory-observations-v2.json") }
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    func load() throws -> [MemoryPlayRecord] {
        guard FileManager.default.fileExists(atPath:file.path) else { return [] }
        return try ContractJSON.decoder().decode([MemoryPlayRecord].self,from:Data(contentsOf:file))
    }
    func save(_ records: [MemoryPlayRecord]) throws {
        try ContractJSON.encoder().encode(records).write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
    }
    func csv(_ records: [MemoryPlayRecord]) throws -> URL {
        func cell(_ value: String) -> String { "\""+value.replacingOccurrences(of:"\"",with:"\"\"")+"\"" }
        var lines = [["play_id","set_id","set_index","excerpt_id","source_id","source_sha256","catalog_sha256","analysis_key","difficulty_version","level","mode","first_bar","bars","quarter_bpm","difficulty","prior_exposures","prior_pattern_exposures","outcome","accuracy","listen_starts","listen_completed","input_ms","interruptions","expected","actual","given_indices","input_policy","replay_with_count_in","replay_direct","retry_of"].map(cell).joined(separator:",")]
        for p in records {
            let expected = p.expected.map { String($0) }.joined(separator:";")
            let actual = p.actual.map { $0.map { String($0) } ?? "" }.joined(separator:";")
            let accuracy = p.accuracy.map { String($0) } ?? ""
            let values: [String] = [p.id.uuidString,p.setId.uuidString,String(p.setIndex),p.excerptId,p.sourceId,
                p.sourceSha256,p.catalogSha256,p.analysisKey,p.difficultyVersion,p.level.rawValue,p.mode,
                String(p.first),String(p.bars),String(p.bpm),String(p.score),String(p.priorExposures),String(p.priorPatternExposures),
                p.outcome,accuracy,String(p.listenStarts),String(p.listenCompleted),String(p.inputMs),String(p.interruptions),
                expected,actual,p.givenIndices.map { String($0) }.joined(separator:";"),p.inputPolicy ?? "prefilled-first-v2",
                p.replayWithCountIn.map(String.init) ?? "",p.replayDirect.map(String.init) ?? "",p.retryOf?.uuidString ?? ""]
            lines.append(values.map(cell).joined(separator:","))
        }
        let url = root.appendingPathComponent("memory-observations.csv")
        try Data(("\u{FEFF}"+lines.joined(separator:"\r\n")+"\r\n").utf8).write(to:url,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        return url
    }
}
