import SwiftUI

@MainActor final class MelodyRunModel: ObservableObject {
    enum Page { case setup, playing, result, summary }
    @Published var difficulty: MemoryDifficulty = .beginner
    @Published private(set) var setIndex = 0
    @Published private(set) var setExcerpts: [MemoryExcerpt] = []
    @Published private(set) var setScores: [Int?] = Array(repeating:nil,count:4)
    @Published private(set) var exportURL: URL?
    @Published private(set) var storageFailed = false
    @Published private(set) var catalog: MemoryCatalog?
    @Published private(set) var contentLoading = false
    private var contentProvider: TrainingContentProvider?
    private var catalogHash = ""
    private var fixedStageBpm: Double?
    private let stageMode: Bool
    private var stagedSources: [String:MelodySource] = [:]
    private var setId = UUID()
    private var records: [MemoryPlayRecord] = []
    private var committedRecords: [MemoryPlayRecord] = []
    private var currentRecordId: UUID?
    private var store: MemoryRunStore?
    private var transition: Task<Void,Never>?
    private var transitionPending = false
    private var inputStarted: TimeInterval?
    var excerpt: MemoryExcerpt? { setExcerpts.indices.contains(setIndex) ? setExcerpts[setIndex] : nil }
    var setCount: Int { setExcerpts.isEmpty ? difficulty.barPlan.count : setExcerpts.count }
    var isLastRound: Bool { setIndex+1 >= setCount }
    var tempoLabel: String {
        if let q=question, q.collection == "classical", let bpm=q.tempoDisplayBpm, let unit=q.tempoBeatUnit {
            let symbol=unit == "dotted_half" ? "𝅗𝅥." : unit == "dotted_quarter" ? "♩." : unit == "half" ? "𝅗𝅥" : "♩"
            return "\(symbol) = \(Int(bpm))"
        }
        let meter = round?.score.timeSignature ?? TimeSignature(numerator:4,denominator:4)
        if meter.denominator == 8 && [6,9,12].contains(meter.numerator) { return "♩. = \(Int((settings.bpm/1.5).rounded()))" }
        if meter.denominator == 2 { return "𝅗𝅥 = \(Int((settings.bpm/2).rounded()))" }
        return "♩ = \(Int(settings.bpm.rounded()))"
    }
    var keyboardRange: ClosedRange<Int> { fixedStageBpm == nil && difficulty == .beginner && excerpt != nil ? 60...72 : round?.keyboardRange ?? 60...84 }
    @Published var settings = MelodySettings()
    @Published private(set) var questions: [MelodyQuestion] = []
    @Published var selection = ""
    @Published private(set) var page: Page = .setup
    @Published private(set) var round: MelodyRound?
    @Published private(set) var answers: MelodyAnswers?
    @Published private(set) var phase: MelodyPhase = .countIn
    @Published private(set) var measure = 1
    @Published private(set) var progress = 0.0
    @Published private(set) var pulse = 0
    @Published private(set) var remainingSeconds = 0.0
    @Published private(set) var inputReady = false
    @Published private(set) var paused = false
    @Published private(set) var working = false
    @Published private(set) var replaying: String?
    @Published var error: String?
    @Published var importMessage: String?
    @Published private(set) var message = ""
    @Published private(set) var replacementMeasure: Int?
    @Published private(set) var submissionCount = 0
    @Published private(set) var answerRevealed = false
    @Published private(set) var awaitingStart = false
    private var manualStartRequired = false
    private var tutorialSuspended = false
    func requireManualStart() { manualStartRequired = true }
    var classicalCredit: String? {
        guard let question, question.collection == "classical" else { return nil }
        let title = question.sourceLabel?.isEmpty == false ? question.sourceLabel! : question.title
        return title.hasSuffix("中") ? title : title+" 中"
    }
    var guidedPitch: Int? {
        guard let answers, answers.guideFirst, (answers.pitches.first ?? nil) == nil else { return nil }
        return round?.targets.first?.midi
    }
    let audio = MelodyRunAudio()
    private var timeline: MelodyTimeline?
    private var runner: Task<Void,Never>?
    private var scheduled: Set<Int> = []
    private var localURLs: [String:URL] = [:]
    private var freeRecall = false
    private var lastWindow: Int?
    var question: MelodyQuestion? { questions.first { $0.id == selection } }
    var canEnter: Bool { page == .playing && !awaitingStart && !tutorialSuspended && !paused && !working && !transitionPending && (freeRecall || inputReady) }
    var allEntered: Bool { answers?.pitches.allSatisfy { $0 != nil } == true }
    var currentCount: Int {
        guard let round, let answers else { return 0 }
        return round.targetIndices(measure:measure).filter { answers.pitches[$0] != nil }.count
    }
    var currentTotal: Int { round?.targetIndices(measure:measure).count ?? 0 }
    var beatsPerBar: Int {
        guard let round else { return 4 }
        let meter = round.score.timeSignature
        return meter.numerator
    }
    var completedBars: Int {
        guard let round, let answers else { return 0 }
        return (1...round.score.measures).filter { answers.complete($0) }.count
    }
    var label: String {
        if awaitingStart { return "시작을 눌러주세요" }
        if paused { return "잠시 쉬는 중" }
        if inputReady, phase == .beat { return "미리 입력해도 좋아요" }
        switch phase {
        case .countIn: return "예비박 듣는 중"
        case .listen: return "선율 재생 중"
        case .beat: return "입력 준비"
        case .input: return currentCount == currentTotal ? "마디 입력 완료" : "건반으로 입력하세요"
        }
    }

    init(connection: RhythmConnection? = nil, stageMode: Bool = false) {
        self.stageMode = stageMode
        do {
            if let connection, !connection.demo { contentProvider = try TrainingContentProvider(connection:connection) }
            else { try installCatalog(DemoContent.data("memory-run-v3"),groove:DemoContent.data("memory-groove-v2")) }
            let root = try LocalStore(scope:connection?.scope ?? "memory-run-guest").root
            let storage = try MemoryRunStore(root:root)
            records = try storage.load(); store = storage
            committedRecords=records
            // A prior app termination is an interrupted observation, not an incorrect answer.
            for i in records.indices where records[i].outcome == "in_progress" { records[i].outcome = "interrupted" }
            if !stageMode { try storage.save(records); exportURL = try storage.csv(records) }
            try loadLocalQuestions()
            selection = questions.first?.id ?? ""
        } catch { self.error = error.localizedDescription }
    }
    private func installCatalog(_ data: Data, groove: Data) throws {
        var value = try JSONDecoder().decode(MemoryCatalog.self,from:data)
        let policy = try ContractJSON.decoder().decode(MemoryGroovePolicy.self,from:groove)
        try value.applyGroovePolicy(policy,catalogSha256:data.sha256); try value.validate()
        catalog = value; catalogHash = data.sha256
        questions = questions.filter { localURLs[$0.id] != nil } + value.sources
        selection = questions.first?.id ?? ""
    }
    func prepareContent() async {
        guard catalog == nil, !contentLoading, let contentProvider else { return }
        contentLoading = true; defer { contentLoading = false }
        do {
            let data = try await contentProvider.data("memory-run-v3.json")
            let groove = try await contentProvider.data("memory-groove-v2.json")
            try Task.checkCancellation(); try installCatalog(data,groove:groove)
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func prepareStage(_ questions: [DrillStageQuestion]) async throws {
        await prepareContent()
        guard let catalog else { throw SolfegeError.invalidScore(error ?? "스테이지 문제를 준비하지 못했어요.") }
        for question in questions {
            guard let e = catalog.excerpts.first(where:{ $0.id == question.catalogId }),
                  let s = catalog.sources.first(where:{ $0.id == e.sourceId }), s.sha256 == question.sourceSha256 else {
                throw SolfegeError.invalidScore("스테이지 악보 버전을 확인해 주세요.")
            }
            let parsed = try await source(s)
            if let fifths=question.keyFifths, parsed.fifths != fifths {
                throw SolfegeError.invalidScore("스테이지의 조표를 확인해 주세요.")
            }
            if s.collection == "classical", let bpm=s.quarterBpm, abs(bpm-question.bpm)>0.001 {
                throw SolfegeError.invalidScore("클래식의 지정 템포가 일치하지 않아요.")
            }
        }
        try audio.prepare()
    }
    private func source(_ question: MelodyQuestion) async throws -> MelodySource {
        if let cached = stagedSources[question.id] { return cached }
        let data: Data
        if let url = localURLs[question.id] { data = try Data(contentsOf:url) }
        else if let contentProvider { data = try await contentProvider.data(question.file) }
        else if let url = Bundle.main.url(forResource:question.file,withExtension:nil) { data = try Data(contentsOf:url) }
        else { throw SolfegeError.invalidScore("문제 XML을 찾지 못했어요.") }
        try Task.checkCancellation()
        if let expected = question.sha256, data.sha256 != expected { throw SolfegeError.invalidScore("선율 파일이 변경됐어요.") }
        let result = try MelodyXMLParser.parse(data)
        if stageMode { stagedSources[question.id] = result }
        return result
    }
    func commitStage() throws {
        if stageMode, let store { try store.save(records); committedRecords=records }
    }
    func discardStage() {
        stop(); records=committedRecords; currentRecordId=nil
        setExcerpts=[]; setScores=[]; setIndex=0; page = .setup
    }
    private func localDirectory() throws -> URL {
        let documents = try FileManager.default.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
        let url = documents.appendingPathComponent("MusicXML",isDirectory:true)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        return url
    }
    private func loadLocalQuestions() throws {
        let urls = try FileManager.default.contentsOfDirectory(at:localDirectory(),includingPropertiesForKeys:nil)
        for url in urls where ["xml","musicxml"].contains(url.pathExtension.lowercased()) {
            do {
                let source = try MelodyXMLParser.parse(Data(contentsOf:url))
                addLocal(url,source:source)
            } catch { importMessage = "일부 로컬 XML은 지원 형식이 아니어서 제외했어요: \(url.lastPathComponent)" }
        }
    }
    private func addLocal(_ url: URL, source: MelodySource) {
        let id = "local:"+url.lastPathComponent
        let pitches = source.score.symbols.compactMap(\.midi)
        questions.removeAll { $0.id == id }
        questions.insert(MelodyQuestion(id:id,title:url.deletingPathExtension().lastPathComponent,file:url.lastPathComponent,
            key:source.keyLabel,beats:source.score.timeSignature.numerator,beatType:source.score.timeSignature.denominator,
            noteCount:source.score.symbols.filter { $0.midi != nil && !$0.tieStop }.count,
            lowestMidi:pitches.min() ?? 60,highestMidi:pitches.max() ?? 72,sourceURL:"",fifths:source.fifths,mode:source.mode),at:0)
        localURLs[id] = url
    }
    func importFiles(_ urls: [URL]) {
        var imported = 0, failures: [String] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf:url,options:.mappedIfSafe)
                let source = try MelodyXMLParser.parse(data)
                let destination = try localDirectory().appendingPathComponent(String(data.sha256.prefix(12))+"-"+url.lastPathComponent)
                try data.write(to:destination,options:.atomic)
                addLocal(destination,source:source); selection = "local:"+destination.lastPathComponent; imported += 1
            } catch { failures.append(url.lastPathComponent+": "+error.localizedDescription) }
        }
        importMessage = "\(imported)개 추가했어요"+(failures.isEmpty ? "" : "\n"+failures.joined(separator:"\n"))
    }
    func randomize() {
        let candidates = questions.filter { $0.id != selection }
        if let next = (candidates.isEmpty ? questions : candidates).randomElement() { selection = next.id }
    }
    func newSet() {
        fixedStageBpm = nil
        guard let catalog, !working, !transitionPending else { return }
        do {
            endObservation(outcome:"abandoned")
            var rng = SystemRandomNumberGenerator()
            let heard = records.filter { $0.listenStarts > 0 }
            setExcerpts = try catalog.makeSet(level:difficulty,mode:settings.mode,
                recentSourceIds:heard.suffix(20).map(\.sourceId),recentFingerprints:Set(heard.suffix(40).map(\.fingerprint)),using:&rng)
            setIndex = 0; setScores = Array(repeating:nil,count:setExcerpts.count); setId = UUID()
            queueStart()
        } catch { self.error = error.localizedDescription }
    }
    // Daily Training plays one question of a regular set.
    func newDailyRound(difficulty: MemoryDifficulty) {
        settings.mode = .memory; self.difficulty = difficulty
        newSet()
        guard setExcerpts.count > 1 else { return }
        setExcerpts = [setExcerpts[0]]; setScores = [nil]
    }
    func newStageRound(_ q: DrillStageQuestion) {
        guard !working, !transitionPending else { return }
        guard let catalog,
              let excerpt=catalog.excerpts.first(where:{ $0.id==q.catalogId }), excerpt.bars==2,
              let source=catalog.sources.first(where:{ $0.id==excerpt.sourceId }), source.sha256==q.sourceSha256 else {
            error="고정된 스테이지 문제를 확인하지 못했어요."; return
        }
        endObservation(outcome:"abandoned"); fixedStageBpm=q.bpm
        settings.mode = .memory; setExcerpts=[excerpt]; setIndex=0; setScores=[nil]; setId=UUID()
        queueStart(afterDelay:false)
    }
    private func queueStart(afterDelay: Bool = true) {
        transition?.cancel()
        stopReplay()
        transitionPending = true
        transition = Task { [weak self] in
            await self?.start(afterDelay:afterDelay)
            self?.transitionPending = false
        }
    }
    func next() {
        guard page == .result, !working, !transitionPending else { return }
        if setIndex+1 >= setExcerpts.count { stopReplay(); page = .summary; return }
        setIndex += 1; queueStart()
    }
    func retry() { guard page == .result, !working, !transitionPending else { return }; queueStart() }
    func start(afterDelay: Bool = false) async {
        if let excerpt {
            selection = excerpt.sourceId; settings.startBar = excerpt.first; settings.bars = excerpt.bars
            settings.bpm = fixedStageBpm ?? difficulty.quarterBpm
            settings.inputBars = 2; settings.advanceEarly = true
        }
        if let q=question, q.collection == "classical", let bpm=q.quarterBpm { settings.bpm=bpm }
        guard !working, let question else { return }
        working = true; defer { working = false }
        if afterDelay {
            do { try await Task.sleep(for:.seconds(1)) } catch { return }
            guard !Task.isCancelled else { return }
        }
        await Task.yield()
        guard !Task.isCancelled else { return }
        do {
            try settings.validate()
            let source = try await self.source(question)
            guard settings.mode != .groove || source.supportsGroove(start:settings.startBar,bars:settings.bars) else {
                throw SolfegeError.invalidScore("이 선율은 마디를 잇는 붙임줄이 있어 Groove에서 사용할 수 없어요.")
            }
            let value = try MelodyRound(source:source,start:settings.startBar,bars:settings.bars)
            runner?.cancel()
            if stageMode { audio.stopClock(); audio.releaseKeys() } else { audio.stop() }
            round = value; answers = MelodyAnswers(round:value,guideFirst:true); measure = 1; freeRecall = false
            replacementMeasure = nil; message = ""; submissionCount=0; answerRevealed=false
            try audio.prepare()
            page = .playing; paused = false; awaitingStart = manualStartRequired
            if !awaitingStart { beginObservation(); try beginClock(from:1) }
        } catch { audio.stop(); endObservation(outcome:"technical_error"); page = .setup; self.error = error.localizedDescription }
    }
    func startPreparedRound() {
        guard awaitingStart, !tutorialSuspended, !working, !transitionPending, round != nil else { return }
        do {
            try audio.prepare()
            awaitingStart = false; manualStartRequired = false; paused = false
            beginObservation(); try beginClock(from: 1)
        } catch { audio.stop(); paused = true; self.error = error.localizedDescription }
    }
    func suspendForTutorial() {
        tutorialSuspended = true
        if !awaitingStart { pause() }
    }
    func finishTutorial() { tutorialSuspended = false }
    private func beginClock(from measure: Int, includeCountIn: Bool = true) throws {
        guard let round else { return }
        let value = MelodyTimeline(round:round,settings:settings,fromMeasure:measure,includeCountIn:includeCountIn)
        timeline = value; phase = value.windows.first?.phase ?? .listen; lastWindow = nil; inputReady = false; pulse = -1
        scheduled = settings.mode == .memory ? Set(measure...round.score.measures) : [measure]
        try audio.start(value,round:round,settings:settings)
        runner?.cancel()
        runner = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.page == .playing, !self.paused else { return }
                self.updateClock()
                do { try await Task.sleep(for:.milliseconds(8)) } catch { return }
            }
        }
    }
    private var leadTicks: Int { max(96,Int(ceil(settings.bpm*480/60*0.16))) }
    private func updateClock() {
        guard let value = timeline, let round else { return }
        let tick = audio.tick
        guard tick >= 0 else { return }
        let inputIndex = settings.mode == .groove ? value.inputIndex(at:tick,bpm:settings.bpm) : nil
        if inputReady != (inputIndex != nil) { inputReady = inputIndex != nil }
        if let index = value.index(at:tick) {
            let window = value.windows[index]
            let nextPulse = ((tick-window.start)/value.pulseTicks) % round.score.timeSignature.numerator
            if pulse != nextPulse { pulse = nextPulse }
            if lastWindow != index {
                if window.phase == .listen && (settings.mode == .groove || window.measure == value.windows.first(where: { $0.phase == .listen })?.measure) { mutateRecord { $0.listenStarts += 1 } }
                if settings.mode == .groove {
                    if let previous = lastWindow, value.windows[previous].phase == .listen { mutateRecord { $0.listenCompleted += 1 } }
                    if let previous = lastWindow, value.windows[previous].phase == .input { accumulateInputTime() }
                    if window.phase == .input { inputStarted = ProcessInfo.processInfo.systemUptime }
                }
                // Stop held live keys before the next reference phrase starts.
                if window.phase == .listen { audio.releaseKeys() }
                phase = window.phase; measure = window.measure; lastWindow = index
            }
            let nextProgress: Double
            if settings.mode == .memory, window.phase == .listen, let first = value.windows.first(where: { $0.phase == .listen }) {
                nextProgress = Double(tick-first.start)/Double(max(1,value.end-first.start))
            } else { nextProgress = Double(tick-window.start)/Double(max(1,window.end-window.start)) }
            if abs(progress-nextProgress) >= 0.008 { progress = nextProgress }
            let remaining = (Double(max(0,window.end-tick))/480*60/settings.bpm*10).rounded(.up)/10
            if remainingSeconds != remaining { remainingSeconds = remaining }
            if let inputIndex {
                let input = value.windows[inputIndex]
                if answers?.complete(input.measure) == true, settings.advanceEarly { armNext(after:inputIndex,early:true) }
                else if tick+leadTicks >= input.end { armNext(after:inputIndex,early:false) }
            }
        } else if tick >= value.end {
            audio.stopClock(); runner?.cancel(); runner = nil
            if settings.mode == .memory {
                mutateRecord { $0.listenCompleted += 1 }
                freeRecall = true; phase = .input; measure = 1; progress = 0; pulse = -1
                inputStarted = ProcessInfo.processInfo.systemUptime
                advanceMemory()
            } else { finish() }
        }
    }
    private func armNext(after index: Int, early: Bool) {
        guard var value = timeline, let round else { return }
        let next = value.windows[(index+1)...].first { $0.phase == .listen }
        guard next.map({ !scheduled.contains($0.measure) }) ?? true else { return }
        if early { value.shortenInput(at:index,now:audio.tick,lead:leadTicks) }
        timeline = value
        if let window = value.windows[(index+1)...].first(where: { $0.phase == .listen }) {
            do { try audio.schedule(window,round:round); scheduled.insert(window.measure) }
            catch { pause(); self.error = error.localizedDescription }
        }
    }
    func keyDown(_ midi: Int) {
        guard page == .playing, !paused, !working else { return }
        guard audio.isRunning else { pause(); error = "오디오가 중단됐어요. 계속하기로 다시 준비해 주세요."; return }
        // Classify input using the audio clock, even if the UI has not refreshed yet.
        if !freeRecall { updateClock() }
        guard page == .playing, !paused else { return }
        audio.noteOn(midi)
        guard canEnter else { return }
        let accepted: Bool
        if replacementMeasure == measure { accepted = answers?.replace(measure:measure,with:midi) == true }
        else { accepted = answers?.enter(midi,measure:measure) == true }
        guard accepted else {
            message = guidedPitch != nil ? "강조된 시작음을 먼저 눌러 주세요." : "이 마디는 다 채웠어요. 수정할 마디를 누르거나 제출해 주세요."
            return
        }
        replacementMeasure = nil; message = ""
        updateActual()
        if freeRecall { advanceMemory() }
        else if settings.advanceEarly, let value = timeline, let index = value.inputIndex(at:audio.tick,bpm:settings.bpm), answers?.complete(measure) == true {
            armNext(after:index,early:true)
        }
    }
    func keyUp(_ midi: Int) { audio.noteOff(midi) }
    private func advanceMemory() {
        guard let round, let answers else { return }
        while measure < round.score.measures && answers.complete(measure) { measure += 1 }
    }
    func undo() {
        guard canEnter else { return }
        if freeRecall { if let previous = answers?.undo() { measure = previous } }
        else {
            // The current bar stays editable until its scheduled boundary.
            // Earlier timed-out bars must never be changed by an undo in this bar.
            answers?.undo(in:measure)
        }
        updateActual()
        replacementMeasure = nil; message = ""
    }
    func clearBar() { guard canEnter else { return }; answers?.clear(measure:measure); replacementMeasure = nil; message = ""; updateActual() }
    func selectBar(_ bar: Int) {
        guard freeRecall, canEnter, let round, (1...round.score.measures).contains(bar) else { return }
        measure = bar
        replacementMeasure = round.targetIndices(measure:bar).contains(where:{ answers?.pitches[$0] != nil }) ? bar : nil
        message = replacementMeasure == nil ? "" : "건반을 누르면 \(bar)마디를 첫 음부터 다시 입력해요."
    }
    func submit() {
        guard canEnter, let result=answers?.result else { return }
        submissionCount+=1
        if result.accuracy == 100 { finish(); return }
        if submissionCount < 3 {
            message = submissionCount == 1 ? "음정이 일치하지 않아요. 다시 들어보세요." : "표시된 음을 다시 들어보세요."
            return
        }
        revealAnswer()
    }
    func revealAnswer() {
        guard canEnter else { return }
        answerRevealed=true; finish()
    }
    func finish() {
        guard page == .playing else { return }
        runner?.cancel(); runner = nil; audio.stopClock(); audio.releaseKeys(); page = .result; paused = false
        if let result = answers?.result {
            setScores[setIndex] = result.accuracy
            mutateRecord { $0.accuracy = result.accuracy }
        }
        endObservation(outcome:"submitted")
    }
    func pause() {
        if working || transitionPending { transition?.cancel(); transition = nil; transitionPending = false; working = false; page = .setup; audio.stop(); return }
        guard page == .playing, !awaitingStart else { stopReplay(); audio.stop(); return }
        runner?.cancel(); runner = nil; paused = true; audio.stop()
        accumulateInputTime(); mutateRecord { $0.interruptions += 1 }
    }
    func resume() {
        guard paused, !tutorialSuspended, !awaitingStart else { return }
        do {
            try audio.prepare(); paused = false
            if !freeRecall { try beginClock(from:settings.mode == .memory ? 1 : measure) }
            else { inputStarted = ProcessInfo.processInfo.systemUptime }
        } catch { audio.stop(); paused = true; self.error = error.localizedDescription }
    }
    func setup() { stop(); page = .setup }
    func stop() {
        transition?.cancel(); transition = nil; transitionPending = false; working = false
        runner?.cancel(); runner = nil; audio.stop(); replaying = nil; awaitingStart = false
        endObservation(outcome:"abandoned")
    }
    func listenAgain(includeCountIn: Bool = true) {
        guard page == .playing, settings.mode == .memory, freeRecall, !paused, !working else { return }
        accumulateInputTime(); freeRecall = false; replacementMeasure = nil; message = ""
        mutateRecord {
            if includeCountIn { $0.replayWithCountIn = ($0.replayWithCountIn ?? 0)+1 }
            else { $0.replayDirect = ($0.replayDirect ?? 0)+1 }
        }
        do { try beginClock(from:1,includeCountIn:includeCountIn) }
        catch { pause(); self.error = error.localizedDescription }
    }
    private func beginObservation() {
        guard let excerpt, let question, let round, let answers else { return }
        let record = MemoryPlayRecord(setId:setId,setIndex:setIndex,excerptId:excerpt.id,sourceId:question.id,
            sourceSha256:question.sha256 ?? "",catalogSha256:catalogHash,analysisKey:question.analysisKey ?? "",
            difficultyVersion:catalog?.difficultyVersion ?? "",level:difficulty,mode:settings.mode.rawValue,
            bars:excerpt.bars,first:excerpt.first,bpm:settings.bpm,score:excerpt.score,fingerprint:excerpt.fingerprint,
            priorExposures:records.filter { $0.excerptId == excerpt.id && $0.listenStarts > 0 }.count,
            priorPatternExposures:records.filter { $0.fingerprint == excerpt.fingerprint && $0.listenStarts > 0 }.count,
            expected:round.targets.map(\.midi),givenIndices:answers.givenIndices.sorted(),actual:answers.pitches)
        var updated = record
        updated.inputPolicy = "guided-first-manual-v3"
        updated.replayWithCountIn = 0; updated.replayDirect = 0
        updated.retryOf = records.last(where: { $0.setId == setId && $0.setIndex == setIndex && $0.outcome == "submitted" })?.id
        records.append(updated); currentRecordId = updated.id; persist()
    }
    private func mutateRecord(_ change: (inout MemoryPlayRecord)->Void) {
        guard let id = currentRecordId, let i = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[i]); persist()
    }
    private func updateActual() { if let pitches = answers?.pitches { mutateRecord { $0.actual = pitches } } }
    private func accumulateInputTime() {
        guard let start = inputStarted else { return }; inputStarted = nil
        let elapsed = Int(max(0,ProcessInfo.processInfo.systemUptime-start)*1000)
        mutateRecord { $0.inputMs += elapsed }
    }
    private func endObservation(outcome: String) {
        accumulateInputTime(); updateActual()
        mutateRecord { if $0.outcome == "in_progress" { $0.outcome = outcome } }
        currentRecordId = nil
        persist(export:true)
    }
    private func persist(export: Bool = false) {
        guard !stageMode else { return }
        guard let store else { return }
        do { try store.save(records); if export { exportURL = try store.csv(records) }; storageFailed = false }
        catch { storageFailed = true; self.error = "게임 기록을 기기에 저장하지 못했어요. 저장 공간을 확인해 주세요." }
    }
    func retryStorage() { persist(export:true) }
    func replay(user: Bool, measure: Int? = nil, includeCountIn: Bool = false) {
        guard let round, let answers, page == .result else { return }
        stopReplay()
        do {
            var events = user ? round.events(answers:answers.pitches) : round.score.events
            var ticks = round.score.totalTicks
            if let measure {
                let start = (measure-1)*round.score.ticksPerMeasure, end = start+round.score.ticksPerMeasure
                events = events.compactMap { e in
                    let a = max(start,e.onset), b = min(end,e.onset+e.duration)
                    return a < b ? MusicEvent(midi:e.midi,onset:a-start,duration:b-a) : nil
                }; ticks = round.score.ticksPerMeasure
            }
            guard events.contains(where: { $0.midi != nil }) else {
                error = "이 구간에는 재생할 음이 없어요."; return
            }
            var clicks: [MusicEvent] = []
            if includeCountIn {
                let meter=round.score.timeSignature
                let count=CountInPlayback(measures:1,beforeStepOrders:[1],beatsPerMeasure:meter.numerator,beatUnit:meter.denominator,accentVelocity:105,velocity:75,profileId:"sori-click-v1")
                events=events.map { MusicEvent(midi:$0.midi,onset:$0.onset+count.totalTicks,duration:$0.duration) }
                clicks=(0..<count.beatsPerMeasure).map { MusicEvent(midi:60,onset:$0*count.ticksPerBeat,duration:min(40,count.ticksPerBeat)) }
                ticks+=count.totalTicks
            }
            try audio.replay(events:events,ticks:ticks,bpm:settings.bpm,clicks:clicks)
            replaying = user ? "내 연주" : "원본 선율"
            runner = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    if self.audio.tick >= ticks { self.stopReplay(); return }
                    do { try await Task.sleep(for:.milliseconds(30)) } catch { return }
                }
            }
        } catch { audio.stop(); self.error = error.localizedDescription }
    }
    func stopReplay() { runner?.cancel(); runner = nil; audio.stopClock(); replaying = nil }
}
