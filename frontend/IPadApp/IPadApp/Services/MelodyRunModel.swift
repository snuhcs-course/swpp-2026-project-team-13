import SwiftUI

@MainActor final class MelodyRunModel: ObservableObject {
    enum Page { case setup, playing, result, summary }
    @Published var difficulty: MemoryDifficulty = .beginner
    @Published private(set) var setIndex = 0
    @Published private(set) var setExcerpts: [MemoryExcerpt] = []
    @Published private(set) var setScores: [Int?] = Array(repeating:nil,count:4)
    @Published private(set) var exportURL: URL?
    @Published private(set) var storageFailed = false
    private(set) var catalog: MemoryCatalog?
    private var catalogHash = ""
    private var setId = UUID()
    private var records: [MemoryPlayRecord] = []
    private var currentRecordId: UUID?
    private var store: MemoryRunStore?
    private var transition: Task<Void,Never>?
    private var transitionPending = false
    private var inputStarted: TimeInterval?
    var excerpt: MemoryExcerpt? { setExcerpts.indices.contains(setIndex) ? setExcerpts[setIndex] : nil }
    var tempoLabel: String {
        let meter = round?.score.timeSignature ?? TimeSignature(numerator:4,denominator:4)
        if meter.denominator == 8 && [6,9,12].contains(meter.numerator) { return "♩. = \(Int((settings.bpm/1.5).rounded()))" }
        if meter.denominator == 2 { return "𝅗𝅥 = \(Int((settings.bpm/2).rounded()))" }
        return "♩ = \(Int(settings.bpm.rounded()))"
    }
    var keyboardRange: ClosedRange<Int> { difficulty == .beginner && excerpt != nil ? 60...72 : round?.keyboardRange ?? 60...84 }
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
    var canEnter: Bool { page == .playing && !paused && !working && !transitionPending && (freeRecall || inputReady) }
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
        if paused { return "잠시 쉬는 중" }
        if inputReady, phase == .beat { return "미리 입력해도 좋아요" }
        switch phase {
        case .countIn: return "예비박 듣는 중"
        case .listen: return "선율 재생 중"
        case .beat: return "입력 준비"
        case .input: return currentCount == currentTotal ? "마디 입력 완료" : "건반으로 입력하세요"
        }
    }

    init(connection: RhythmConnection? = nil) {
        do {
            guard let url = Bundle.main.url(forResource:"memory-run-v2",withExtension:"json") else {
                throw SolfegeError.invalidScore("미니게임 문제 목록이 없어요.")
            }
            let data = try Data(contentsOf:url)
            let value = try JSONDecoder().decode(MemoryCatalog.self,from:data)
            try value.validate(); catalog = value; catalogHash = data.sha256
            questions = value.sources
            let root = try LocalStore(scope:connection?.scope ?? "memory-run-guest").root
            let storage = try MemoryRunStore(root:root)
            records = try storage.load(); store = storage
            // A prior app termination is an interrupted observation, not an incorrect answer.
            for i in records.indices where records[i].outcome == "in_progress" { records[i].outcome = "interrupted" }
            try storage.save(records); exportURL = try storage.csv(records)
            try loadLocalQuestions()
            selection = questions.first?.id ?? ""
        } catch { self.error = error.localizedDescription }
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
        guard let catalog, !working, !transitionPending else { return }
        do {
            endObservation(outcome:"abandoned")
            var rng = SystemRandomNumberGenerator()
            setExcerpts = try catalog.makeSet(level:difficulty,using:&rng)
            setIndex = 0; setScores = Array(repeating:nil,count:4); setId = UUID()
            queueStart()
        } catch { self.error = error.localizedDescription }
    }
    private func queueStart() {
        transition?.cancel()
        stopReplay()
        transitionPending = true
        transition = Task { [weak self] in
            await self?.start(afterDelay:true)
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
            settings.bpm = difficulty.quarterBpm; settings.inputBars = 2; settings.advanceEarly = true
        }
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
            let url = localURLs[question.id] ?? Bundle.main.url(forResource:question.file,withExtension:nil)
            guard let url else { throw SolfegeError.invalidScore("문제 XML을 찾지 못했어요.") }
            let data = try Data(contentsOf:url)
            if let expected = question.sha256, data.sha256 != expected { throw SolfegeError.invalidScore("선율 파일이 변경됐어요. 최신 앱을 설치해 주세요.") }
            let source = try MelodyXMLParser.parse(data)
            let value = try MelodyRound(source:source,start:settings.startBar,bars:settings.bars)
            runner?.cancel(); audio.stop()
            round = value; answers = MelodyAnswers(round:value,guideFirst:true); measure = 1; freeRecall = false
            replacementMeasure = nil; message = ""
            try audio.prepare()
            page = .playing; paused = false
            beginObservation()
            try beginClock(from:1)
        } catch { audio.stop(); endObservation(outcome:"technical_error"); page = .setup; self.error = error.localizedDescription }
    }
    private func beginClock(from measure: Int, includeCountIn: Bool = true) throws {
        guard let round else { return }
        let value = MelodyTimeline(round:round,settings:settings,fromMeasure:measure,includeCountIn:includeCountIn)
        timeline = value; phase = .countIn; lastWindow = nil; inputReady = false; pulse = -1
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
        guard page == .playing else { stopReplay(); audio.stop(); return }
        runner?.cancel(); runner = nil; paused = true; audio.stop()
        accumulateInputTime(); mutateRecord { $0.interruptions += 1 }
    }
    func resume() {
        guard paused else { return }
        do {
            try audio.prepare(); paused = false
            if !freeRecall { try beginClock(from:settings.mode == .memory ? 1 : measure) }
            else { inputStarted = ProcessInfo.processInfo.systemUptime }
        } catch { audio.stop(); paused = true; self.error = error.localizedDescription }
    }
    func setup() { stop(); page = .setup }
    func stop() {
        transition?.cancel(); transition = nil; transitionPending = false; working = false
        runner?.cancel(); runner = nil; audio.stop(); replaying = nil
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
        guard let store else { return }
        do { try store.save(records); if export { exportURL = try store.csv(records) }; storageFailed = false }
        catch { storageFailed = true; self.error = "게임 기록을 기기에 저장하지 못했어요. 저장 공간을 확인해 주세요." }
    }
    func retryStorage() { persist(export:true) }
    func replay(user: Bool, measure: Int? = nil) {
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
            try audio.replay(events:events,ticks:ticks,bpm:settings.bpm)
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
