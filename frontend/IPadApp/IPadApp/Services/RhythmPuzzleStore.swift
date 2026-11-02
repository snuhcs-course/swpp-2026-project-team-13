import Foundation

@MainActor struct RhythmConnection {
    let api: any ExamAPI
    let profileId: UUID
    let demo: Bool
    let generation: UUID
    var scope: String { api.scope+":"+profileId.uuidString }
    var identity: String { scope+":"+generation.uuidString }
}

struct RhythmJournal: Codable {
    var draft: RhythmDraft?
    var records: [RhythmPlayRecord] = []
    var synced: Set<UUID> = []
}

// Lives under the same per-origin/per-user directory as Exam/Practice. Account
// deletion's existing LocalStore.removeAll also removes this journal and outbox.
final class RhythmPuzzleStore {
    let root: URL
    var file: URL { root.appendingPathComponent("rhythm-journal-v1.json") }
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    func load() throws -> RhythmJournal {
        guard FileManager.default.fileExists(atPath:file.path) else { return RhythmJournal() }
        return try ContractJSON.decoder().decode(RhythmJournal.self,from:Data(contentsOf:file))
    }
    func save(_ journal: RhythmJournal) throws {
        try ContractJSON.encoder().encode(journal).write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
    }
    func csv(_ journal: RhythmJournal, catalog: RhythmCatalog) throws -> URL {
        func cell(_ value: String) -> String { "\""+value.replacingOccurrences(of:"\"",with:"\"\"")+"\"" }
        let header = ["play_id","round_id","question_id","source_bars","meter","tempo_quarter_bpm","difficulty","difficulty_version","catalog_sha256","outcome","first_correct","submissions","replays_started","replays_completed","active_ms","interruptions","prior_exposures","prior_pattern_exposures","choice_order","server_synced"]
        let rounds = Dictionary(uniqueKeysWithValues:catalog.rounds.map { ($0.id,$0) })
        var lines = [header.map(cell).joined(separator:",")]
        for p in journal.records {
            let r = rounds[p.roundId]
            let correct: String
            if let sub = p.submissions.first, let r {
                correct = String((try? RhythmBoard(placements:sub.placements,ties:sub.ties).sounds(round:r,tiles:catalog.tileMap)) == r.rhythm)
            } else { correct = "" }
            // Keep each conversion separate so Swift can type-check this export
            // without solving all optional maps and overloaded initializers at once.
            let sourceBars = r.map { "\($0.firstMeasure)-\($0.firstMeasure+1)" } ?? ""
            let meter = r.map { "\($0.meter.numerator)/\($0.meter.denominator)" } ?? ""
            let tempo = r.map { String($0.tempoBpm) } ?? ""
            let difficulty = r.map { String($0.difficulty.score) } ?? ""
            let replays = p.listens.filter { $0.reason == "replay" }
            let completedReplays = replays.filter { $0.completed }.count
            let values: [String] = [
                p.id.uuidString, p.roundId, r?.questionId.uuidString ?? "", sourceBars,
                meter, tempo, difficulty, r?.difficulty.version ?? "",
                p.catalogSha256, p.outcome, correct, String(p.submissions.count),
                String(replays.count), String(completedReplays), String(p.activeMs),
                String(p.interruptions), String(p.priorExposures), String(p.priorPatternExposures),
                p.choiceOrder.joined(separator:";"), String(journal.synced.contains(p.id))
            ]
            lines.append(values.map(cell).joined(separator:","))
        }
        let url = root.appendingPathComponent("rhythm-observations.csv")
        try Data(("\u{FEFF}"+lines.joined(separator:"\r\n")+"\r\n").utf8).write(to:url,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        return url
    }
}
