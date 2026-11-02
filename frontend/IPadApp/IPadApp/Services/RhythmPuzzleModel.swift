import SwiftUI

@MainActor final class RhythmPuzzleModel: ObservableObject {
    enum Page { case setup, playing, summary }
    @Published var page = Page.setup
    @Published private(set) var journal = RhythmJournal()
    @Published private(set) var catalog: RhythmCatalog?
    @Published private(set) var tiles: [String:RhythmTile] = [:]
    @Published private(set) var playing = false
    @Published private(set) var syncing = false
    @Published private(set) var storageFailed = false
    @Published var tieMode = false
    @Published var error: String?
    @Published var message = ""
    @Published var syncMessage = ""
    @Published var level = "mixed"
    @Published var exportURL: URL?
    let audio = RhythmPuzzleAudio()
    let connection: RhythmConnection?
    private var store: RhythmPuzzleStore?
    private var catalogHash = ""
    private var runner: Task<Void,Never>?
    private var syncTask: Task<Void,Never>?
    private var anchor: TimeInterval?
    private var anchorMs = 0
    private var listening: (id: UUID, reason: String, start: Int)?
    private var playbackId = UUID()
    var draft: RhythmDraft? { journal.draft }
    var round: RhythmRound? { catalog?.rounds.first { $0.id == draft?.record.roundId } }
    var board: RhythmBoard { draft?.board ?? RhythmBoard() }
    var canSubmit: Bool { !storageFailed && !playing && draft?.finished == false && draft?.hasListened == true && round.map { board.complete(round:$0,tiles:tiles) } == true }
    var pending: Int { journal.records.filter { !journal.synced.contains($0.id) }.count }
    var canResume: Bool { draft != nil && draft?.record.catalogSha256 == catalogHash && round != nil }
    var canEdit: Bool { draft?.finished == false && !storageFailed }
    var hintPositions: [RhythmTime] {
        guard let draft, let round, draft.hintLevel >= 2, draft.record.outcome != "correct",
              let submission = draft.record.submissions.last else { return [] }
        return RhythmBoard(placements:submission.placements,ties:submission.ties).errorPositions(round:round,tiles:tiles)
    }
    var feedback: String {
        guard let draft else { return "" }
        if draft.finished { return draft.record.outcome == "correct" ? "정확해요! 들은 리듬을 완성했어요." : "정답을 공개했어요. 내 답과 비교해 보세요." }
        if draft.hintLevel == 1 { return "리듬이 일치하지 않아요. 다시 들어보세요." }
        if draft.hintLevel == 2, let round, let t = hintPositions.first {
            let bar = (t/round.measureDuration).floor
            let pulse = ((t-round.measureDuration*bar)/round.pulse).floor
            return "힌트 · \(bar+1)마디 \(pulse+1)박 주변에서 새로 소리가 나는지, 앞 음이 이어지는지 들어보세요."
        }
        return "조각을 탭하거나 끌어서 리듬을 완성하세요."
    }
    init(connection: RhythmConnection?) {
        self.connection = connection
        do {
            let data = try Bundled.data("rhythm-puzzle-v1",ext:"json")
            let bank = try ContractJSON.decoder().decode(RhythmCatalog.self,from:data)
            try bank.validate(); catalog = bank; tiles = bank.tileMap; catalogHash = data.sha256
            guard let connection else { return }
            let root = try LocalStore(scope:connection.scope).root
            let local = try RhythmPuzzleStore(root:root)
            store = local; journal = try local.load()
            if let draft, draft.record.catalogSha256 != catalogHash {
                message = "저장된 진행은 이전 문제 버전이에요. 기록은 보관되며 새 세트를 시작할 수 있어요."
            }
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        do {
            guard let store else { throw SORIError.storage("로그인한 학습 공간을 먼저 연결해 주세요.") }
            try store.save(journal); storageFailed = false
        } catch { storageFailed = true; self.error = "기기에 기록을 저장하지 못했어요. \(error.localizedDescription)" }
    }
    func retryStorage() { save() }
    func newSet() {
        guard let catalog, connection != nil, !storageFailed else { return }
        if draft != nil && draft?.finished == false { abandon() }
        var bank = catalog
        if level != "mixed" { bank.rounds = bank.rounds.filter { $0.level == level } }
        let selected = bank.set()
        guard !selected.isEmpty else { error = "이 난이도의 문제가 없어요."; return }
        begin(set:selected.map(\.id),index:0)
    }
    private func begin(set: [String], index: Int) {
        guard let r = catalog?.rounds.first(where: { $0.id == set[index] }) else { return }
        let now = Date()
        var record = RhythmPlayRecord(catalogSha256:catalogHash,roundId:r.id,choiceOrder:r.choices.shuffled(),startedAt:now,finishedAt:now)
        record.priorExposures = journal.records.filter { $0.roundId == r.id }.count
        let related = Set(catalog?.rounds.filter { $0.rhythmKey == r.rhythmKey }.map(\.id) ?? [])
        record.priorPatternExposures = journal.records.filter { related.contains($0.roundId) }.count
        journal.draft = RhythmDraft(setIds:set,index:index,record:record)
        tieMode = false; message = ""; page = .playing; activate(); save()
        listen(reason:"initial")
    }
    func resume() {
        guard canResume else { return }
        page = .playing; activate()
        if draft?.hasListened == false { listen(reason:"initial") }
    }
    func activate() {
        guard page == .playing, draft?.finished == false else { return }
        anchorMs = draft?.record.activeMs ?? 0; anchor = MonotonicTime.now
    }
    private func checkpoint() {
        if let anchor { journal.draft?.record.activeMs = min(86_400_000,anchorMs+max(0,Int((MonotonicTime.now-anchor)*1000))) }
    }
    private func stopListening(completed: Bool) {
        playbackId = UUID(); runner?.cancel(); runner = nil
        checkpoint()
        if let listening, let index = draft?.record.listens.firstIndex(where: { $0.id == listening.id }) {
            let ended = draft?.record.activeMs ?? listening.start
            journal.draft?.record.listens[index].endedMs = ended
            journal.draft?.record.listens[index].completed = completed
        }
        listening = nil; playing = false; audio.stop()
    }
    func listen(reason: String = "replay") {
        guard let round, !storageFailed, !playing, (draft?.record.listens.count ?? 0) < 200 else { return }
        if draft?.finished == true && reason != "reference" { return }
        let recording = draft?.finished == false
        if recording { activate(); checkpoint(); anchor = nil }
        do {
            try audio.play(round,reference:reason == "reference")
            if recording {
                // Bank loading is setup time, not learner response time.
                activate()
                let start = draft?.record.activeMs ?? 0
                let event = RhythmListen(reason:reason,startedMs:start,endedMs:start,completed:false)
                journal.draft?.record.listens.append(event); listening = (event.id,reason,start)
                save()
            }
            playing = true
            let generation = UUID(); playbackId = generation
            let deadline = MonotonicTime.now+Double(audio.endTick)/480*60/round.tempoBpm+3
            runner = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled && generation == playbackId && audio.tick < audio.endTick {
                    if MonotonicTime.now > deadline || !audio.running {
                        stopListening(completed:false); message = "재생이 중단됐어요. 다시 듣기를 눌러 주세요."; save(); return
                    }
                    try? await Task.sleep(for:.milliseconds(25))
                }
                guard !Task.isCancelled, generation == playbackId else { return }
                stopListening(completed:true); save()
            }
        } catch { audio.invalidate(); if recording { activate() }; self.error = error.localizedDescription }
    }
    func pause() {
        guard page == .playing, playing || anchor != nil else { return }
        checkpoint()
        if playing { stopListening(completed:false); message = "재생이 중단됐어요. 다시 듣기로 이어가세요." }
        journal.draft?.record.interruptions += 1
        anchor = nil; audio.invalidate(); save()
    }
    func place(_ id: String, at: RhythmTime? = nil) {
        guard canEdit, let round, var draft else { return }
        let before = draft.board
        let requested = at ?? before.firstGap(tiles:tiles)
        let target = before.placements.first { $0.start <= requested && requested < before.end($0,tiles:tiles) }?.start ?? requested
        guard draft.board.place(id,at:at,round:round,tiles:tiles) else { message = "이 조각이 들어갈 빈 공간을 확인해 주세요."; return }
        if tieMode {
            guard draft.board.toggleTie(target,tiles:tiles) else { message = "바로 앞 음표와 연결할 수 있는 위치에 넣어 주세요."; return }
            tieMode = false
        }
        draft.undo.append(before); draft.undo = Array(draft.undo.suffix(100)); journal.draft = draft
        checkpoint(); message = ""; save()
    }
    func remove(_ p: RhythmPlacement) {
        guard canEdit, var draft else { return }
        draft.undo.append(draft.board); draft.board.remove(p,tiles:tiles)
        journal.draft = draft; checkpoint(); save()
    }
    func toggleTie(_ t: RhythmTime) {
        guard canEdit, var draft else { return }
        let previous = draft.board
        guard draft.board.toggleTie(t,tiles:tiles) else { return }
        draft.undo.append(previous); journal.draft = draft; checkpoint(); save()
    }
    func undo() {
        guard canEdit, let previous = journal.draft?.undo.popLast() else { return }
        journal.draft?.board = previous; checkpoint(); save()
    }
    func submit() {
        guard canSubmit, let round else { return }
        checkpoint()
        do {
            _ = try journal.draft?.submit(round:round,tiles:tiles)
            if draft?.finished == true { anchor = nil; enqueue() }
            save()
            if draft?.finished == true { sync() }
        } catch { self.error = error.localizedDescription }
    }
    private func enqueue() {
        guard let record = draft?.record else { return }
        if !journal.records.contains(where: { $0.id == record.id }) { journal.records.append(record) }
    }
    func next() {
        guard let draft, draft.finished else { return }
        stopListening(completed:false)
        if draft.index+1 < draft.setIds.count { begin(set:draft.setIds,index:draft.index+1) }
        else { journal.draft = nil; page = .summary; anchor = nil; save(); makeExport() }
    }
    private func abandon() {
        stopListening(completed:false); checkpoint()
        if draft?.finished == false {
            journal.draft?.record.finishedAt = Date(); journal.draft?.record.outcome = "abandoned"
            enqueue()
        }
        journal.draft = nil; anchor = nil; save()
    }
    func close() {
        // Keep the unfinished round resumable. Finalized records are immutable.
        checkpoint(); stopListening(completed:false); anchor = nil; audio.shutdown(); save()
        syncTask?.cancel(); syncTask = nil
    }
    func sync() {
        guard !syncing, let connection else { return }
        if connection.demo { syncMessage = "데모 기록은 이 기기에 저장돼요."; return }
        syncing = true; syncMessage = "서버에 기록 저장 중"
        syncTask = Task { [weak self] in
            guard let self else { return }
            defer { syncing = false }
            do {
                for record in journal.records.filter({ !self.journal.synced.contains($0.id) }).prefix(30) {
                    try Task.checkCancellation()
                    let receipt = try await connection.api.saveRhythmPlay(record)
                    guard receipt.clientPlayId == record.id, receipt.roundId == record.roundId, receipt.catalogSha256 == record.catalogSha256 else {
                        throw SORIError.transport("저장 확인 응답이 연습 기록과 다릅니다.")
                    }
                    try Task.checkCancellation(); journal.synced.insert(record.id); save()
                }
                syncMessage = pending == 0 ? "서버 저장 완료" : "\(pending)개 기록이 기기에 보관돼요. 저장 재시도를 눌러 주세요."
            } catch {
                if !(error is CancellationError) { syncMessage = "기기 저장 완료 · 서버 저장 대기 \(pending)개. \(error.localizedDescription)" }
            }
        }
    }
    func makeExport() {
        do { if let catalog, let store { exportURL = try store.csv(journal,catalog:catalog) } }
        catch { self.error = error.localizedDescription }
    }
}
