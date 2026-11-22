import SwiftUI
import AVFoundation

// A tiny, authored UI example; never loads the full problem bank.
enum TutorialSamples {
    static let rhythm: RhythmCatalog? = try? DemoContent.decode("rhythm-puzzle-v4", forceSmall: true)
    static let engraving: RhythmEngraving? = try? DemoContent.decode("rhythm-engraving-v4", forceSmall: true)
    static let rhythmRound: RhythmRound? = {
        guard let bank = rhythm else { return nil }
        return bank.rounds.first { round in
            round.meter == TimeSignature(numerator: 4, denominator: 4) &&
                round.solution.count == 8 && round.solution.allSatisfy { bank.tileMap[$0.tileId]?.duration == round.pulse }
        } ?? bank.rounds.first
    }()
    static let memory: MelodyRound? = {
        let pitches = [60, 62, 64, 67, 65, 64, 62, 60]
        let steps = ["C", "D", "E", "G", "F", "E", "D", "C"]
        let events = pitches.enumerated().map { MusicEvent(midi: $0.element, onset: $0.offset*480, duration: 480) }
        let symbols = pitches.enumerated().map { index, midi in
            ScoreSymbol(measure: index/4+1, onset: index*480, duration: 480, midi: midi,
                        step: steps[index], octave: 4, alter: 0, type: "quarter", dots: 0, tieStart: false, tieStop: false)
        }
        let score = MusicScore(tempo: 80, measures: 2, events: events, symbols: symbols)
        return try? MelodyRound(source: MelodySource(score: score, fifths: 0, mode: "major", clef: "G"), start: 1, bars: 2)
    }()
}

@MainActor final class TutorialDemoAudio: ObservableObject {
    @Published private(set) var playing = false
    @Published var error: String?
    private let audio = MelodyRunAudio()
    private var task: Task<Void, Never>?
    func play(events: [MusicEvent], ticks: Int, bpm: Double = 80, countIn: Bool = false) {
        stop()
        let offset = countIn ? 1920 : 0
        let notes = events.map { MusicEvent(midi: $0.midi, onset: $0.onset+offset, duration: $0.duration) }
        let clicks = countIn ? (0..<4).map { MusicEvent(midi: $0 == 0 ? 84 : 76, onset: $0*480, duration: 80) } : []
        do {
            try audio.replay(events: notes, ticks: ticks+offset, bpm: bpm, clicks: clicks)
            playing = true
            task = Task {
                let deadline = ProcessInfo.processInfo.systemUptime + Double(ticks+offset)/480*60/bpm+4
                while !Task.isCancelled && audio.tick < ticks+offset && audio.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                    do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                }
                guard !Task.isCancelled else { return }
                audio.stop(); playing = false
            }
        } catch { self.error = "소리를 재생하지 못했어요. 다시 시도해 주세요."; stop() }
    }
    func keyDown(_ midi: Int) {
        do { if !audio.ready || !audio.isRunning { try audio.prepare() }; audio.noteOn(midi) }
        catch { self.error = "소리를 재생하지 못했어요. 다시 시도해 주세요." }
    }
    func keyUp(_ midi: Int) { audio.noteOff(midi) }
    func stop() { task?.cancel(); task = nil; audio.stop(); playing = false }
}

struct TutorialDemoScreen: View {
    let kind: TutorialKind
    let target: TutorialTarget?
    let close: () -> Void
    @StateObject private var audio = TutorialDemoAudio()
    @StateObject private var drawing = DrawingController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var inputs: [Int] = []
    @State private var board = RhythmBoard()
    @State private var tieMode = false
    @State private var tieSelection: RhythmPlacement?
    @State private var selectedBar = 1
    @State private var replaceBar = false
    @State private var echoPhase = EchoIntervalPhase.waiting
    @State private var pendingReaction: EchoIntervalPhase?
    @State private var message = ""
    @State private var blank: UIImage?
    private let range = 60...84
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 14) {
                header
                if kind == .exam { examContent }
                else {
                    DrillSetProgress(results: Array(repeating: nil, count: kind == .echoDragon ? 10 : kind == .memoryRun ? 4 : 5), index: 0)
                    if kind == .echoDragon {
                        Image(audio.playing && pendingReaction == nil ? "echo-dragon-singing" : echoPhase == .happy ? "echo-dragon-happy" : echoPhase == .puzzled ? "echo-dragon-puzzled" : "echo-dragon-waiting")
                            .resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                        HStack { Text(message); Spacer(); Text("♥  ♥  ♥").foregroundStyle(SolfegeTheme.danger) }.font(.subheadline).frame(height: 28)
                        keyboard.frame(height: min(180, geometry.size.height*0.26))
                    } else if kind == .memoryRun {
                        HStack { Text("4/4").font(.title.bold()); Text("♩ = 80").foregroundStyle(.secondary); Spacer() }
                        memoryNotation.frame(maxHeight: .infinity)
                        Text(message).font(.subheadline).frame(height: 28)
                        keyboard.frame(height: min(180, geometry.size.height*0.26))
                    } else { rhythmContent(tileHeight: min(85, max(48, (geometry.size.height-440)/3))) }
                    actions
                }
            }
            .padding(24).frame(maxWidth: 1050).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SolfegeTheme.background).foregroundStyle(SolfegeTheme.ink)
        .environment(\.rhythmEngraving, TutorialSamples.engraving)
        .task {
            let sheet = MusicScore(tempo: 80, measures: 8, events: [], symbols: [])
            blank = ImageRenderer(content: ScoreView(score: sheet).frame(width: 1330, height: 846)).uiImage
        }
        .onChange(of: target) { _, value in
            pendingReaction = nil; audio.stop(); message = ""
            if kind == .echoDragon && value == .firstKey { inputs = [] }
            if kind == .echoDragon && value == .submit { inputs = [65, 69] }
            if kind == .memoryRun && value == .notation { inputs = [60, 62, 64, 67, 65, 64, 62, 60] }
            if kind == .rhythmPuzzle && (value == .notation || value == .tie), let round = TutorialSamples.rhythmRound {
                board = RhythmBoard(placements: round.solution, ties: [])
            }
        }
        .onChange(of: audio.playing) { _, playing in
            if !playing, let reaction = pendingReaction {
                echoPhase = reaction; pendingReaction = nil
                message = reaction == .happy ? "같은 간격이에요!" : "간격이 달라요. 다시 눌러보세요."
            }
        }
        .onChange(of: scenePhase) { _, value in if value != .active { audio.stop() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: RunLoop.main)) { _ in audio.stop() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in audio.stop() }
        .onDisappear { audio.stop() }
        .alert("소리를 재생하지 못했어요", isPresented: Binding(get: { audio.error != nil }, set: { if !$0 { audio.error = nil } })) {
            Button("확인") { audio.error = nil }
        }
    }
    private var header: some View {
        HStack {
            Text(kind.title).font(.title2.bold())
            Text("예시").font(.caption).padding(.horizontal, 10).padding(.vertical, 4).background(SolfegeTheme.soft, in: Capsule())
            Spacer()
            TutorialHelpButton(action: {})
            Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("안내 닫기")
        }.frame(height: 44)
    }
    private var keyboard: some View {
        MelodyPianoView(range: range, enabled: !audio.playing, solfege: true,
                        reference: kind == .echoDragon ? 65 : 60, onDown: enter, onUp: audio.keyUp)
            .tutorialTarget(.keyboard)
            .overlay(alignment: .topLeading) {
                GeometryReader { geometry in
                    if let key = PianoGeometry(range: range).keys.first(where: { $0.midi == 65 }) {
                        Color.clear.frame(width: max(0, key.width*Double(geometry.size.width)-6), height: Double(geometry.size.height)*0.35)
                            .tutorialTarget(.firstKey).offset(x: key.x*Double(geometry.size.width)+3, y: Double(geometry.size.height)*0.65)
                    }
                }.allowsHitTesting(false)
            }
            .overlay {
                if kind == .echoDragon {
                    EchoPianoSelection(range: range, selected: Set(inputs), playing: nil)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
    @ViewBuilder private var memoryNotation: some View {
        if let round = TutorialSamples.memory {
            MemoryPhraseView(round: round, answers: round.targets.indices.map { inputs.indices.contains($0) ? inputs[$0] : nil },
                             selectedBar: selectedBar, selectBar: { bar in selectedBar = bar; replaceBar = true })
                .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 16)).tutorialTarget(.notation)
        }
    }
    @ViewBuilder private func rhythmContent(tileHeight: CGFloat) -> some View {
        if let bank = TutorialSamples.rhythm, let round = TutorialSamples.rhythmRound {
            HStack { Text("\(round.meter.numerator)/\(round.meter.denominator)").font(.title.bold()); Text(round.tempoLabel); Spacer() }
            RhythmStaffSystem(round: round, board: board, tiles: bank.tileMap, editable: true, tieMode: tieMode,
                              tapPiece: tapPiece, tapTie: { boundary in board.ties.removeAll { $0 == boundary } },
                              connect: connect, movePiece: { piece, time in
                                  var next = board
                                  next.remove(piece, tiles: bank.tileMap)
                                  if next.place(piece.tileId, at: time, round: round, tiles: bank.tileMap) { board = next }
                              }, removePiece: { piece in board.remove(piece, tiles: bank.tileMap) })
                .padding(.horizontal, 12).background(.white, in: RoundedRectangle(cornerRadius: 16))
                .tutorialTarget(.notation)
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first else { return false }; place(id); return true
                }
            Text(message).font(.subheadline).frame(height: 24)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(RhythmChoiceDisplay.order(round: round, tiles: bank.tileMap, shuffled: round.choices), id: \.self) { id in
                    if let tile = bank.tileMap[id] {
                        RhythmTileFace(tile: tile, pulse: round.pulse).frame(height: 98).scaleEffect(tileHeight/98)
                            .frame(height: tileHeight).clipped().contentShape(Rectangle())
                            .onTapGesture { place(id) }.draggable(id)
                            .accessibilityAddTraits(.isButton).accessibilityLabel("리듬 조각 \(tile.label(pulse: round.pulse))")
                            .accessibilityAction { place(id) }
                    }
                }
            }.tutorialTarget(.choices)
            Spacer(minLength: 0)
        }
    }
    private var actions: some View {
        HStack(spacing: 14) {
            HStack(spacing: 14) {
                Button { listen(false) } label: { RhythmReplayIcon().frame(width: 32, height: 32) }.accessibilityLabel("바로 다시 듣기")
                if kind != .echoDragon {
                    Button { listen(true) } label: { RhythmReplayIcon(withMetronome: true).frame(width: 32, height: 32) }.accessibilityLabel("예비박부터 다시 듣기")
                }
            }.buttonStyle(.bordered).tutorialTarget(.replay)
            Button { if !inputs.isEmpty { inputs.removeLast() } } label: { Image(systemName: "arrow.uturn.backward").frame(width: 32, height: 32) }
                .buttonStyle(.bordered).accessibilityLabel("되돌리기")
            Spacer()
            if kind == .rhythmPuzzle {
                Button { tieMode.toggle(); tieSelection = nil } label: { RhythmTieIcon().frame(width: 32, height: 32) }
                    .buttonStyle(.bordered).tint(tieMode ? .blue : SolfegeTheme.violet)
                    .accessibilityLabel("타이 연결").tutorialTarget(.tie)
            }
            Button(target == .start || target == nil ? "시작" : "제출") {
                if target == .start { listen(kind != .echoDragon) } else { submit() }
            }.buttonStyle(PrimaryButton()).frame(minWidth: 150)
                .tutorialTarget(.start).tutorialTarget(.submit)
        }.frame(height: 54)
    }
    private var examContent: some View {
        VStack(spacing: 14) {
            ViewThatFits {
                HStack(spacing: 20) { Text("C장조  ·  4/4  ·  ♩ = 80").font(.headline); examProgress; examTimer }
                VStack { HStack { Text("C장조  ·  4/4  ·  ♩ = 80"); Spacer(); examTimer }; examProgress }
            }
            HStack(spacing: 10) {
                Button { drawing.erasing = false } label: { Label("펜", systemImage: "pencil.tip") }
                Button { drawing.erasing = true } label: { Label("지우개", systemImage: "eraser") }
                Divider().frame(height: 24)
                ForEach([1.5, 2, 4.5], id: \.self) { width in
                    Button { drawing.penWidth = width; drawing.erasing = false } label: {
                        Circle().frame(width: width*3+1, height: width*3+1).frame(width: 40, height: 40)
                    }.accessibilityLabel(width == 4.5 ? "굵은 펜" : width == 2 ? "보통 펜" : "가는 펜")
                }
                Button { drawing.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 40, height: 40) }.accessibilityLabel("실행 취소")
            }.buttonStyle(.bordered).tutorialTarget(.tools).frame(maxWidth: .infinity, alignment: .leading)
            if let blank {
                AnswerCanvas(template: blank, drawing: drawing).frame(maxHeight: .infinity).tutorialTarget(.notation)
            } else { Color.white.tutorialTarget(.notation) }
            HStack {
                Spacer()
                Button("다음 구간") { message = "다음 구간으로 넘어가요." }.buttonStyle(SecondaryActionButton()).tutorialTarget(.next)
                Button("답안 제출") { message = "실제 시험에서는 제출 후 AI가 채점해요." }.buttonStyle(PrimaryButton()).tutorialTarget(.submit)
            }
            Text(message).font(.caption).frame(height: 18)
        }
    }
    private var examProgress: some View {
        SegmentProgressBar(cursor: PlaybackCursor()).tutorialTarget(.progress)
    }
    private var examTimer: some View {
        VStack(alignment: .trailing) { Text("남은 필기 시간").font(.caption); Text("00:18").font(.system(size: 32, weight: .semibold)).monospacedDigit() }
            .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 10)).tutorialTarget(.timer)
    }
    private func enter(_ midi: Int) {
        if kind == .echoDragon {
            if inputs.count == 2 { inputs = [] }
            guard !inputs.isEmpty || midi == 65 else { message = "표시된 첫 음부터 눌러보세요."; return }
            audio.keyDown(midi); inputs.append(midi)
        } else if kind == .memoryRun {
            audio.keyDown(midi)
            if replaceBar { inputs = Array(inputs.prefix((selectedBar-1)*4)); replaceBar = false }
            if inputs.count < 8 { inputs.append(midi) }
            selectedBar = min(2, inputs.count/4+1)
        }
    }
    private func listen(_ countIn: Bool) {
        if kind == .echoDragon {
            inputs = []; pendingReaction = nil; echoPhase = .singing
            audio.play(events: [MusicEvent(midi: 60, onset: 0, duration: 480), MusicEvent(midi: 64, onset: 640, duration: 480)], ticks: 1120)
        } else if kind == .memoryRun, let score = TutorialSamples.memory?.score {
            audio.play(events: score.events, ticks: score.totalTicks, countIn: countIn)
        } else if let round = TutorialSamples.rhythmRound {
            audio.play(events: round.audio.compactMap { note in
                guard let onset = note.onset.ticks, let duration = note.duration.ticks else { return nil }
                return MusicEvent(midi: note.midi, onset: onset, duration: duration)
            }, ticks: round.totalDuration.ticks ?? 3840, bpm: round.tempoBpm, countIn: countIn)
        }
    }
    private func place(_ id: String) {
        guard let bank = TutorialSamples.rhythm, let round = TutorialSamples.rhythmRound else { return }
        if let issue = board.placementIssue(id, round: round, tiles: bank.tileMap) { message = issue }
        else { board.place(id, round: round, tiles: bank.tileMap); message = "" }
    }
    private func tapPiece(_ piece: RhythmPlacement) {
        guard let tiles = TutorialSamples.rhythm?.tileMap else { return }
        if tieMode {
            if let first = tieSelection { connect(first, piece); tieSelection = nil } else { tieSelection = piece }
        } else { board.remove(piece, tiles: tiles) }
    }
    private func connect(_ first: RhythmPlacement, _ second: RhythmPlacement) {
        guard let tiles = TutorialSamples.rhythm?.tileMap else { return }
        let boundary = max(first.start, second.start)
        guard board.validBoundaries(tiles: tiles).contains(boundary) else { message = "이웃한 두 음을 골라보세요."; return }
        if board.ties.contains(boundary) { board.ties.removeAll { $0 == boundary } } else { board.ties.append(boundary) }
        message = "두 음을 타이로 연결했어요."
    }
    private func submit() {
        if kind == .echoDragon {
            guard inputs.count == 2 else { message = "표시된 첫 음부터 두 음을 눌러보세요."; return }
            let correct = inputs[1]-inputs[0] == 4
            audio.play(events: inputs.enumerated().map { MusicEvent(midi: $0.element, onset: $0.offset*640, duration: 480) }, ticks: 1120)
            echoPhase = .waiting; pendingReaction = correct ? .happy : .puzzled
        } else { message = "실제 게임에서도 같은 방법으로 제출해요." }
    }
}
