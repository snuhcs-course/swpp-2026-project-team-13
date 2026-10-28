import SwiftUI

@MainActor final class MelodyRunModel: ObservableObject {
    enum Page { case setup, playing, result }
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
    let audio = MelodyRunAudio()
    private var timeline: MelodyTimeline?
    private var runner: Task<Void,Never>?
    private var scheduled: Set<Int> = []
    private var localURLs: [String:URL] = [:]
    private var freeRecall = false
    private var lastWindow: Int?
    var question: MelodyQuestion? { questions.first { $0.id == selection } }
    var canEnter: Bool { page == .playing && !paused && !working && (freeRecall || inputReady) }
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
        case .countIn: return "비트를 느껴 보세요"
        case .listen: return "귀에 담아요"
        case .beat: return "머릿속으로 한 번 더"
        case .input: return currentCount == currentTotal ? "입력 완료!" : "건반으로 이어 보세요"
        }
    }

    init() {
        do {
            guard let url = Bundle.main.url(forResource:"melody-catalog",withExtension:"json") else {
                throw SORIError.invalidScore("미니게임 문제 목록이 없어요.")
            }
            questions = try JSONDecoder().decode([MelodyQuestion].self,from:Data(contentsOf:url)).filter(\.isDemoEligible)
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
        guard source.isDemoEligible else { return }
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
                try source.validateDemoKey()
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
    func start() async {
        guard !working, let question else { return }
        working = true; defer { working = false }
        await Task.yield()
        do {
            try settings.validate()
            let url = localURLs[question.id] ?? Bundle.main.url(forResource:question.file,withExtension:nil)
            guard let url else { throw SORIError.invalidScore("문제 XML을 찾지 못했어요.") }
            let source = try MelodyXMLParser.parse(Data(contentsOf:url))
            try source.validateDemoKey()
            let value = try MelodyRound(source:source,start:settings.startBar,bars:settings.bars)
            runner?.cancel(); audio.stop()
            round = value; answers = MelodyAnswers(round:value); measure = 1; freeRecall = false
            try audio.prepare()
            page = .playing; paused = false
            try beginClock(from:1)
        } catch { audio.stop(); page = .setup; self.error = error.localizedDescription }
    }
    private func beginClock(from measure: Int) throws {
        guard let round else { return }
        let value = MelodyTimeline(round:round,settings:settings,fromMeasure:measure)
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
                // Stop held live keys before the next reference phrase starts.
                if window.phase == .listen { audio.releaseKeys() }
                phase = window.phase; measure = window.measure; lastWindow = index
            }
            let nextProgress = Double(tick-window.start)/Double(max(1,window.end-window.start))
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
                freeRecall = true; phase = .input; measure = 1; progress = 0; pulse = -1
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
        guard answers?.enter(midi,measure:measure) == true else { return }
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
    }
    func clearBar() { guard canEnter else { return }; answers?.clear(measure:measure) }
    func selectBar(_ bar: Int) { guard freeRecall, canEnter else { return }; measure = bar }
    func finish() {
        guard page == .playing else { return }
        runner?.cancel(); runner = nil; audio.stopClock(); audio.releaseKeys(); page = .result; paused = false
    }
    func pause() {
        guard page == .playing else { stopReplay(); audio.stop(); return }
        runner?.cancel(); runner = nil; paused = true; audio.stop()
    }
    func resume() {
        guard paused else { return }
        do {
            try audio.prepare(); paused = false
            if !freeRecall { try beginClock(from:settings.mode == .memory ? 1 : measure) }
        } catch { audio.stop(); paused = true; self.error = error.localizedDescription }
    }
    func setup() { runner?.cancel(); runner = nil; audio.stop(); replaying = nil; page = .setup }
    func stop() { runner?.cancel(); runner = nil; audio.stop(); replaying = nil }
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
