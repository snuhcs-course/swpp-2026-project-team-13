import SwiftUI

@MainActor final class RhythmPuzzleModel: ObservableObject {
    enum Page { case setup, playing, summary }
    @Published var page = Page.setup
    @Published private(set) var journal = RhythmJournal()
    @Published private(set) var catalog: RhythmCatalog?
    @Published private(set) var tiles: [String:RhythmTile] = [:]
    @Published private(set) var playing = false
    @Published private(set) var waitingToPlay = false
    @Published private(set) var syncing = false
    @Published private(set) var storageFailed = false
    @Published var tieMode = false
    @Published var error: String?
    @Published var message = ""
    @Published private(set) var missingPosition: RhythmTime?
    @Published var syncMessage = ""
    @Published var level = "beginner"
    @Published private(set) var selectedTiePiece: RhythmPlacement?
    @Published private(set) var completedSetCount = 5
    @Published private(set) var engraving: RhythmEngraving?
    @Published private(set) var contentLoading = false
    private var contentProvider: TrainingContentProvider?
    @Published var exportURL: URL?
    let audio = RhythmPuzzleAudio()
    let connection: RhythmConnection?
    private var store: RhythmPuzzleStore?
    private var catalogHash = ""
    private var runner: Task<Void,Never>?
    private var startTask: Task<Void,Never>?
    private var syncTask: Task<Void,Never>?
    private var anchor: TimeInterval?
    private var anchorMs = 0
    private var listening: (id: UUID, reason: String, start: Int)?
    private var playbackId = UUID()
    private var catalogVersions: [String:String] = [:]
    private var currentRoundIds: Set<String> = []
    private var closed = false
    private let stageMode: Bool
    private var stageCommitted = false
    private var preservedDraft: RhythmDraft?
    private var committedJournal = RhythmJournal()
    @Published private(set) var awaitingStart = false
    @Published private(set) var tutorialPaused = false
    private var manualStartRequired = false
    private var tutorialSuspended = false
    func requireManualStart() { manualStartRequired = true }
    var draft: RhythmDraft? { journal.draft }
    var round: RhythmRound? { catalog?.rounds.first { $0.id == draft?.record.roundId } }
    var board: RhythmBoard { draft?.board ?? RhythmBoard() }
    var canSubmit: Bool { !awaitingStart && !tutorialSuspended && !tutorialPaused && !storageFailed && !playing && !waitingToPlay && draft?.finished == false && draft?.hasListened == true }
    var pending: Int { journal.records.filter { !journal.synced.contains($0.id) }.count }
    var canResume: Bool { draft.map { catalogVersions[$0.record.catalogSha256] != nil } == true && round != nil }
    var canEdit: Bool { !awaitingStart && !tutorialSuspended && !tutorialPaused && draft?.finished == false && !storageFailed }
    var setCount: Int { draft?.setIds.count ?? completedSetCount }
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
        return ""
    }
    init(connection: RhythmConnection?, stageMode: Bool = false) {
        self.stageMode = stageMode
        self.connection = connection
        do {
            if let connection, !connection.demo { contentProvider = try TrainingContentProvider(connection:connection) }
            else {
                let data = try DemoContent.data("rhythm-puzzle-v4")
                let ink = try DemoContent.data("rhythm-engraving-v4")
                let legacy: [Data]
                if !stageMode && DemoContent.hasFullBank { legacy = try ["rhythm-puzzle-v1","rhythm-puzzle-v2","rhythm-puzzle-v3"].map { try Bundled.data($0,ext:"json") } }
                else { legacy = [] }
                try installCatalog(data,ink:ink,legacy:legacy)
            }
            guard let connection else { return }
            let root = try LocalStore(scope:connection.scope).root
            let local = try RhythmPuzzleStore(root:root)
            store = local; journal = try local.load()
            if stageMode { preservedDraft=journal.draft; journal.draft=nil }
            committedJournal=journal
        } catch { self.error = error.localizedDescription }
    }
    private func installCatalog(_ data: Data, ink: Data, legacy: [Data]) throws {
            var bank = try ContractJSON.decoder().decode(RhythmCatalog.self,from:data)
            try bank.validate(); catalogHash = data.sha256
            currentRoundIds = Set(bank.rounds.map(\.id)); catalogVersions[catalogHash] = bank.version
            let drawing = try ContractJSON.decoder().decode(RhythmEngraving.self,from:ink)
            guard drawing.catalogSha256 == catalogHash, bank.tiles.allSatisfy({ drawing.tiles[$0.id]?.symbolXs.count == $0.symbols.count }) else {
                throw SolfegeError.invalidScore("리듬 악보와 문제 버전이 다릅니다.")
            }
            engraving = drawing
            for legacyData in legacy {
                let legacy = try ContractJSON.decoder().decode(RhythmCatalog.self,from:legacyData)
                catalogVersions[legacyData.sha256] = legacy.version
                bank.rounds += legacy.rounds
            }
            catalog = bank; tiles = bank.tileMap
            if let draft, catalogVersions[draft.record.catalogSha256] == nil {
                message = "저장된 진행은 이전 문제 버전이에요. 기록은 보관되며 새 세트를 시작할 수 있어요."
            }
    }
    func prepareContent() async {
        guard catalog == nil, !contentLoading, let contentProvider else { return }
        contentLoading = true; defer { contentLoading = false }
        do {
            let data = try await contentProvider.data("rhythm-puzzle-v4.json")
            let ink = try await contentProvider.data("rhythm-engraving-v4.json")
            var legacy: [Data] = []
            // A new stage never needs three entire historical banks. Retain
            // old data only when a standalone draft/history references it.
            let needed = stageMode ? Set<String>() : Set(journal.records.map(\.gameVersion) + [journal.draft?.record.gameVersion].compactMap { $0 })
            for version in ["rhythm-puzzle-v1","rhythm-puzzle-v2","rhythm-puzzle-v3"] where needed.contains(version) {
                legacy.append(try await contentProvider.data(version+".json"))
            }
            try Task.checkCancellation(); try installCatalog(data,ink:ink,legacy:legacy)
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func prepareStage(_ questions: [DrillStageQuestion]) async throws {
        await prepareContent()
        guard let catalog, questions.allSatisfy({ q in catalog.rounds.contains { $0.id==q.catalogId && $0.sourceXmlSha256==q.sourceSha256 } }) else {
            throw SolfegeError.invalidScore(error ?? "스테이지 문제를 준비하지 못했어요.")
        }
        try audio.prepare()
    }
    private func save() {
        guard !stageMode || stageCommitted else { return }
        do {
            guard let store else { throw SolfegeError.storage("로그인한 학습 공간을 먼저 연결해 주세요.") }
            var saved = journal
            if stageMode { saved.draft=preservedDraft }
            try store.save(saved); storageFailed = false
        } catch { storageFailed = true; self.error = "기기에 기록을 저장하지 못했어요. \(error.localizedDescription)" }
    }
    func retryStorage() { save() }
    func commitStage() throws {
        guard stageMode, let store else { return }
        var completed = journal; completed.draft = preservedDraft
        try store.save(completed)
        committedJournal=journal; committedJournal.draft=nil
        stageCommitted=true
        sync()
    }
    func discardStage() {
        close(); journal=committedJournal; stageCommitted=false
        selectedTiePiece=nil; tieMode=false; message=""; missingPosition=nil; page = .setup
    }
    // Daily Training plays the first round of a regular set.
    func newDailyRound(difficulty: MemoryDifficulty) {
        level = difficulty.rawValue
        newSet(limit:1)
    }
    func newStageRound(_ q: DrillStageQuestion) {
        stageCommitted=false
        guard let catalog, connection != nil, !storageFailed,
              let round=catalog.rounds.first(where:{ $0.id==q.catalogId }),
              round.sourceXmlSha256==q.sourceSha256, round.firstMeasure==q.firstMeasure,
              abs(round.tempoBpm-q.bpm)<0.001, currentRoundIds.contains(round.id) else {
            error="고정된 스테이지 문제를 확인하지 못했어요."; return
        }
        if draft?.finished == false { abandon() }
        begin(set:[round.id],index:0)
    }
    func newSet(limit: Int? = nil) {
        stageCommitted=false
        guard let catalog, connection != nil, !storageFailed else { return }
        if draft != nil && draft?.finished == false { abandon() }
        var bank = catalog; bank.rounds = bank.rounds.filter { currentRoundIds.contains($0.id) }
        if level != "mixed" { bank.rounds = bank.rounds.filter { $0.level == level } }
        var history = journal.records
        if let draft, !history.contains(where: { $0.id == draft.record.id }) { history.append(draft.record) }
        let heard = history.filter { $0.listens.contains(where: { $0.reason != "reference" }) }
        let byId = Dictionary(uniqueKeysWithValues:catalog.rounds.map { ($0.id,$0) })
        let selected = bank.set(recentSourceIds:heard.suffix(20).compactMap { byId[$0.roundId]?.questionId },
            recentRhythmKeys:Set(heard.suffix(40).compactMap { byId[$0.roundId]?.rhythmKey }))
        guard !selected.isEmpty else { error = "이 난이도의 문제가 없어요."; return }
        let ids = selected.map(\.id)
        begin(set:limit.map { Array(ids.prefix($0)) } ?? ids,index:0)
    }
    private func begin(set: [String], index: Int, hash: String? = nil) {
        guard let r = catalog?.rounds.first(where: { $0.id == set[index] }) else { return }
        closed=false
        let now = Date()
        let hash = hash ?? catalogHash
        var record = RhythmPlayRecord(catalogSha256:hash,roundId:r.id,choiceOrder:r.choices.shuffled(),startedAt:now,finishedAt:now)
        record.visibleChoiceOrder = RhythmChoiceDisplay.order(round:r,tiles:tiles,shuffled:record.choiceOrder)
        record.gameVersion = catalogVersions[hash] ?? "rhythm-puzzle-v3"
        let equivalent = Set(catalog?.rounds.filter { $0.questionId == r.questionId && $0.questionVersion == r.questionVersion && $0.firstMeasure == r.firstMeasure }.map(\.id) ?? [])
        record.priorExposures = journal.records.filter { equivalent.contains($0.roundId) }.count
        let related = Set(catalog?.rounds.filter { $0.rhythmKey == r.rhythmKey }.map(\.id) ?? [])
        record.priorPatternExposures = journal.records.filter { related.contains($0.roundId) }.count
        journal.draft = RhythmDraft(setIds:set,index:index,record:record)
        tieMode = false; selectedTiePiece = nil; missingPosition = nil; message = ""; page = .playing
        awaitingStart = manualStartRequired; tutorialPaused = false
        if !awaitingStart { activate(); save(); listen(reason:"initial") }
    }
    func startPreparedRound() {
        guard awaitingStart, !tutorialSuspended else { return }
        awaitingStart = false; manualStartRequired = false
        journal.draft?.record.startedAt = Date()
        activate(); save(); listen(reason: "initial")
    }
    func suspendForTutorial() {
        pause(); tutorialSuspended = true
        tutorialPaused = !awaitingStart && draft?.finished == false
    }
    func finishTutorial() { tutorialSuspended = false }
    func continueAfterTutorial() {
        guard !tutorialSuspended, tutorialPaused else { return }
        tutorialPaused = false; activate()
        if draft?.hasListened == false { listen(reason: "initial") }
    }
    func resume() {
        guard canResume else { return }
        page = .playing; activate()
        if draft?.hasListened == false { listen(reason:"initial") }
    }
    func activate() {
        guard !awaitingStart, !tutorialSuspended, !tutorialPaused, page == .playing, draft?.finished == false else { return }
        anchorMs = draft?.record.activeMs ?? 0; anchor = MonotonicTime.now
    }
    private func checkpoint() {
        if let anchor { journal.draft?.record.activeMs = min(86_400_000,anchorMs+max(0,Int((MonotonicTime.now-anchor)*1000))) }
    }
    private func stopListening(completed: Bool) {
        startTask?.cancel(); startTask = nil; waitingToPlay = false
        playbackId = UUID(); runner?.cancel(); runner = nil
        checkpoint()
        if let listening, let index = draft?.record.listens.firstIndex(where: { $0.id == listening.id }) {
            let ended = draft?.record.activeMs ?? listening.start
            journal.draft?.record.listens[index].endedMs = ended
            journal.draft?.record.listens[index].completed = completed
        }
        listening = nil; playing = false; audio.stop()
    }
    func listen(reason: String = "replay", includeCountIn: Bool = true) {
        guard !awaitingStart, !tutorialSuspended, !tutorialPaused, round != nil, !storageFailed, !playing, !waitingToPlay, (draft?.record.listens.count ?? 0) < 200 else { return }
        if draft?.finished == true && reason != "reference" { return }
        if reason == "reference" || (stageMode && reason == "initial") {
            startListening(reason:reason,includeCountIn:reason != "reference" && includeCountIn); return
        }
        checkpoint(); anchor = nil; waitingToPlay = true
        startTask = Task { [weak self] in
            do { try await Task.sleep(for:.seconds(1)) } catch { return }
            guard let self, !Task.isCancelled, self.page == .playing else { return }
            self.waitingToPlay = false; self.startTask = nil; self.startListening(reason:reason,includeCountIn:includeCountIn)
        }
    }
    private func startListening(reason: String, includeCountIn: Bool) {
        guard let round, !storageFailed else { return }
        let recording = draft?.finished == false
        if recording { activate(); checkpoint(); anchor = nil }
        do {
            try audio.play(round,reference:reason == "reference",includeCountIn:includeCountIn)
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
        guard page == .playing, playing || waitingToPlay || anchor != nil else { return }
        checkpoint()
        if playing || waitingToPlay { stopListening(completed:false); message = "재생이 중단됐어요. 다시 듣기로 이어가세요." }
        journal.draft?.record.interruptions += 1
        anchor = nil; audio.invalidate(); save()
    }
    func place(_ id: String, at: RhythmTime? = nil) {
        guard canEdit, let round, var draft else { return }
        let before = draft.board
        let requested = at ?? before.firstGap(tiles:tiles)
        let target = before.placements.first { $0.start <= requested && requested < before.end($0,tiles:tiles) }?.start ?? requested
        if let issue = draft.board.placementIssue(id,at:at,round:round,tiles:tiles) { message = issue; return }
        guard draft.board.place(id,at:at,round:round,tiles:tiles) else { message = "다른 조각과 겹치지 않는 빈칸에 놓아 주세요."; return }
        if tieMode {
            guard draft.board.toggleTie(target,tiles:tiles) else { message = "바로 앞 음표와 연결할 수 있는 위치에 넣어 주세요."; return }
            tieMode = false; selectedTiePiece = nil
        }
        draft.undo.append(before); draft.undo = Array(draft.undo.suffix(100)); journal.draft = draft
        checkpoint(); message = ""; missingPosition = nil; save()
    }
    func remove(_ p: RhythmPlacement) {
        guard canEdit, var draft else { return }
        draft.undo.append(draft.board); draft.board.remove(p,tiles:tiles)
        journal.draft = draft; selectedTiePiece=nil; message=""; checkpoint(); save()
    }
    func move(_ p: RhythmPlacement, to time: RhythmTime) {
        guard canEdit, var draft, let round else { return }
        let before = draft.board
        guard draft.board.move(p,to:time,round:round,tiles:tiles) else {
            message = "조각이 겹치거나 마디를 넘어요. 들어갈 수 있는 빈칸에 놓아 주세요."; return
        }
        guard before != draft.board else { return }
        draft.undo.append(before); journal.draft = draft
        missingPosition = nil; message = ""; selectedTiePiece = nil; checkpoint(); save()
    }
    func toggleTie(_ t: RhythmTime) {
        guard canEdit, var draft else { return }
        let previous = draft.board
        guard draft.board.toggleTie(t,tiles:tiles) else { return }
        draft.undo.append(previous); journal.draft = draft; checkpoint(); save()
    }
    func toggleTieMode() { tieMode.toggle(); selectedTiePiece = nil }
    func connect(_ first: RhythmPlacement, _ second: RhythmPlacement) {
        guard canEdit, var draft else { return }
        let before = draft.board
        if let issue = draft.board.connectionIssue(first,second,tiles:tiles) { message = issue; return }
        guard draft.board.connect(first,second,tiles:tiles) else { return }
        if before != draft.board { draft.undo.append(before); journal.draft = draft; checkpoint(); save() }
        selectedTiePiece = nil; tieMode = false; message = ""
    }
    func tapPiece(_ p: RhythmPlacement) {
        guard canEdit else { return }
        guard tieMode else { remove(p); return }
        guard let first = selectedTiePiece else { selectedTiePiece = p; return }
        if first == p { selectedTiePiece = nil; return }
        let a = min(first.start,p.start), b = max(first.start,p.start)
        guard let left = board.placements.first(where: { $0.start == a }), board.end(left,tiles:tiles) == b,
              board.validBoundaries(tiles:tiles).contains(b) else {
            selectedTiePiece = p; message = board.connectionIssue(first,p,tiles:tiles) ?? "연결할 두 음을 다시 선택해 주세요."; return
        }
        if let right = board.placements.first(where: { $0.start == b }) { connect(left,right) }
        selectedTiePiece = nil; tieMode = false
    }
    func undo() {
        guard canEdit, let previous = journal.draft?.undo.popLast() else { return }
        journal.draft?.board = previous; checkpoint(); save()
    }
    func submit() {
        guard canSubmit, let round else { return }
        guard board.complete(round:round,tiles:tiles) else {
            let time = board.firstGap(tiles:tiles), bar = (time/round.measureDuration).floor
            let beat = ((time-round.measureDuration*bar)/round.pulse).floor
            missingPosition = time; message = "\(bar+1)마디 \(beat+1)박에 빈칸이 남아 있어요."
            return
        }
        checkpoint()
        do {
            message = ""; missingPosition = nil
            _ = try journal.draft?.submit(round:round,tiles:tiles)
            if draft?.finished == true { anchor = nil; enqueue() }
            save()
            if draft?.finished == true { sync() }
        } catch { self.error = error.localizedDescription }
    }
    func revealAndSkip() {
        guard canEdit else { return }
        stopListening(completed:false); checkpoint()
        journal.draft?.revealAndSkip(); anchor = nil; missingPosition = nil; message = ""; tieMode = false; selectedTiePiece = nil
        enqueue(); save(); sync()
    }
    private func enqueue() {
        guard let record = draft?.record else { return }
        if !journal.records.contains(where: { $0.id == record.id }) { journal.records.append(record) }
    }
    func next() {
        guard let draft, draft.finished else { return }
        stopListening(completed:false)
        if draft.index+1 < draft.setIds.count { begin(set:draft.setIds,index:draft.index+1,hash:draft.record.catalogSha256) }
        else { completedSetCount = draft.setIds.count; journal.draft = nil; page = .summary; anchor = nil; save(); makeExport() }
    }
    func setup() {
        checkpoint(); stopListening(completed:false); anchor = nil; audio.invalidate()
        message = ""; missingPosition = nil; tieMode = false; selectedTiePiece = nil
        page = .setup; save()
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
        guard !closed else { return }; closed=true
        // Keep the unfinished round resumable. Finalized records are immutable.
        checkpoint(); stopListening(completed:false); anchor = nil; audio.shutdown(); save()
        if !stageCommitted { syncTask?.cancel(); syncTask = nil }
    }
    func sync() {
        guard (!stageMode || stageCommitted), !syncing, let connection else { return }
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
                        throw SolfegeError.transport("저장 확인 응답이 연습 기록과 다릅니다.")
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
        guard !stageMode else { return }
        do { if let catalog, let store { exportURL = try store.csv(journal,catalog:catalog) } }
        catch { self.error = error.localizedDescription }
    }
}
