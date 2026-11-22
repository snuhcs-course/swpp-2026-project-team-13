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
    func play(events: [MusicEvent], ticks: Int, bpm: Double = 80, countIn: Bool = false, meter: TimeSignature = TimeSignature(numerator: 4, denominator: 4)) {
        stop()
        let leadIn = TutorialCountIn(meter: meter, enabled: countIn)
        let offset = leadIn.ticks
        let notes = events.map { MusicEvent(midi: $0.midi, onset: $0.onset+offset, duration: $0.duration) }
        let clicks = leadIn.clicks
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
    @ObservedObject var session: MiniTutorialSession
    let close: () -> Void
    @StateObject private var audio = TutorialDemoAudio()
    @Environment(\.scenePhase) private var scenePhase
    @State private var echoPhase = EchoIntervalPhase.waiting
    @State private var pendingReaction: EchoIntervalPhase?
    @State private var choiceFrames: [String: CGRect] = [:]
    @State private var barFrames: [Int: CGRect] = [:]
    @State private var dragging: String?
    @State private var dragPoint = CGPoint.zero
    private let range = 60...84
    private var kind: TutorialKind { session.kind }
    private var page: Int { session.page }
    var body: some View {
        GeometryReader { geometry in
            game(width: geometry.size.width, height: geometry.size.height)
        }.foregroundStyle(SolfegeTheme.ink).background(SolfegeTheme.background.ignoresSafeArea())
            .environment(\.rhythmEngraving, TutorialSamples.engraving)
            .onChange(of: page) { _, _ in pendingReaction = nil; audio.stop(); dragging = nil }
            .onChange(of: audio.playing) { _, playing in
                if !playing, let reaction = pendingReaction {
                    echoPhase = reaction; pendingReaction = nil
                    session.message = reaction == .happy ? "같은 음정이에요!" : "음정이 달라요. 다시 눌러보세요."
                }
            }
            .onChange(of: scenePhase) { _, value in if value != .active { pendingReaction = nil; audio.stop() } }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: RunLoop.main)) { _ in pendingReaction = nil; audio.stop() }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in pendingReaction = nil; audio.stop() }
            .onDisappear { audio.stop() }
            .alert("소리를 재생하지 못했어요", isPresented: Binding(get: { audio.error != nil }, set: { if !$0 { audio.error = nil } })) {
                Button("확인") { audio.error = nil }
            }
    }
    private func game(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 14) {
            header
            DrillSetProgress(results: Array(repeating: nil, count: kind == .echoDragon ? 10 : kind == .memoryRun ? 4 : 5), index: 0)
            if kind == .echoDragon {
                Image(audio.playing && pendingReaction == nil ? "echo-dragon-singing" : echoPhase == .happy ? "echo-dragon-happy" : echoPhase == .puzzled ? "echo-dragon-puzzled" : "echo-dragon-waiting")
                    .resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity).tutorialTarget(.character)
                HStack { Text(session.message); Spacer(); Text("♥  ♥  ♥").foregroundStyle(SolfegeTheme.danger) }.font(.subheadline).frame(height: 28)
                keyboard.frame(height: min(185, max(130, height*0.25)))
            } else if kind == .memoryRun {
                HStack { Text("4/4").font(.title.bold()); Text("♩ = 80").foregroundStyle(.secondary); Spacer() }
                memoryNotation.frame(maxHeight: .infinity)
                Text(session.message).font(.subheadline).frame(height: 22)
                keyboard.frame(height: min(185, max(130, height*0.25)))
            } else { rhythm(width: width) }
            actions
        }.padding(.horizontal, kind == .echoDragon ? 28 : 24).padding(.vertical, 20)
            .frame(maxWidth: kind == .echoDragon ? 1056 : 1100).frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: "rhythm-puzzle")
            .onPreferenceChange(TutorialChoiceFrames.self) { choiceFrames = $0 }
            .onPreferenceChange(RhythmBarFrames.self) { barFrames = $0 }
            .overlay(alignment: .topLeading) {
                if let id = dragging, let tile = TutorialSamples.rhythm?.tileMap[id], let round = TutorialSamples.rhythmRound {
                    RhythmTileFace(tile: tile, pulse: round.pulse, unitWidth: 90).frame(height: 98)
                        .shadow(color: .black.opacity(0.2), radius: 10, y: 8)
                        .position(x: dragPoint.x, y: dragPoint.y-30).allowsHitTesting(false)
                }
            }
    }
    private var header: some View {
        HStack {
            Text(kind.title).font(.title2.bold())
            Text("예시").font(.caption).padding(.horizontal, 10).padding(.vertical, 4).background(SolfegeTheme.soft, in: Capsule())
            Spacer()
            TutorialHelpButton(action: {}).allowsHitTesting(false).accessibilityHidden(true)
            Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("안내 닫기")
        }.frame(height: 44)
    }
    private var keyboard: some View {
        let enabled = !audio.playing && (kind == .memoryRun ? [3, 4].contains(page) : [3, 4, 5].contains(page))
        return MelodyPianoView(range: range, enabled: enabled, solfege: true,
                              reference: kind == .echoDragon ? 65 : 60, onDown: { if session.enter($0) { audio.keyDown($0) } }, onUp: audio.keyUp)
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
                if kind == .echoDragon { EchoPianoSelection(range: range, selected: Set(session.echoInputs), playing: nil).allowsHitTesting(false).accessibilityHidden(true) }
            }
            .accessibilityHidden(!enabled)
    }
    @ViewBuilder private var memoryNotation: some View {
        if let round = TutorialSamples.memory, let answers = session.memory {
            MemoryPhraseView(round: round, answers: answers.pitches, selectedBar: session.selectedBar, selectBar: session.selectBar)
                .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 16))
                .tutorialTarget(.notation).allowsHitTesting(page == 4)
        }
    }
    @ViewBuilder private func rhythm(width: CGFloat) -> some View {
        if let bank = TutorialSamples.rhythm, let round = TutorialSamples.rhythmRound {
            HStack { Text("\(round.meter.numerator)/\(round.meter.denominator)").font(.title.bold()); Text(round.tempoLabel); Spacer() }
            RhythmStaffSystem(round: round, board: session.board, tiles: bank.tileMap,
                              editable: page == 3 || page == 4 || (page == 5 && session.tieMode), tieMode: session.tieMode,
                              tapPiece: { piece in
                                  if page == 5 { session.message = "두 조각을 손가락으로 이어보세요." } else { session.remove(piece) }
                              }, connect: { a, b in _ = session.connect(a, b) }, movePiece: session.move, removePiece: session.remove)
                .overlay { rhythmTargets(round: round, tiles: bank.tileMap).allowsHitTesting(false) }
                .padding(.horizontal, 12).background(.white, in: RoundedRectangle(cornerRadius: 16)).tutorialTarget(.notation)
            Text(session.message).font(.subheadline).frame(height: 18)
            RhythmChoiceFlow {
                ForEach(RhythmChoiceDisplay.order(round: round, tiles: bank.tileMap, shuffled: round.choices), id: \.self) { id in
                    if let tile = bank.tileMap[id] { choice(tile, round: round, width: width) }
                }
            }.tutorialTarget(.choices)
            Spacer(minLength: 0)
        }
    }
    private func choice(_ tile: RhythmTile, round: RhythmRound, width: CGFloat) -> some View {
        let enabled = session.choiceEnabled(tile.id)
        let unitWidth = 100*min(1.2, (min(1100, width)-76)/CGFloat(100*(round.totalDuration/round.pulse).value+112))
        return RhythmTileFace(tile: tile, pulse: round.pulse, unitWidth: unitWidth)
            .contentShape(Rectangle())
            .transformAnchorPreference(key: TutorialAnchors.self, value: .bounds) { value, anchor in
                if tile.id == session.tapTile { value[.rhythmTapTile] = anchor }
                if tile.id == session.dragTile { value[.rhythmDragTile] = anchor }
            }
            .background(GeometryReader { proxy in
                Color.clear.preference(key: TutorialChoiceFrames.self, value: [tile.id: proxy.frame(in: .named("rhythm-puzzle"))])
            })
            .overlay {
                MiniGameTouchSurface(moved: { start, point in
                    guard enabled, session.didTap, hypot(point.x-start.x, point.y-start.y)>10,
                          let frame = choiceFrames[tile.id] else { return }
                    dragging = tile.id; dragPoint = CGPoint(x: frame.minX+point.x, y: frame.minY+point.y)
                }, ended: { _, point, tap in
                    defer { dragging = nil }
                    guard enabled else { return }
                    if tap { _ = session.tapChoice(tile.id) }
                    else if let frame = choiceFrames[tile.id] { drop(tile.id, at: CGPoint(x: frame.minX+point.x, y: frame.minY+point.y)) }
                }, cancelled: { dragging = nil }).accessibilityHidden(true)
            }.allowsHitTesting(enabled)
            .accessibilityAddTraits(.isButton).accessibilityLabel("리듬 조각 \(tile.label(pulse: round.pulse))")
            .accessibilityAction { if enabled { _ = session.tapChoice(tile.id) } }
            .accessibilityAction(named: "강조된 칸으로 옮기기") {
                if enabled && session.didTap { _ = session.dropTile(tile.id, at: round.pulse) }
            }
    }
    private func rhythmTargets(round: RhythmRound, tiles: [String: RhythmTile]) -> some View {
        GeometryReader { proxy in
            let drawings = TutorialSamples.engraving?.tiles ?? RhythmInk.drawings
            let a = RhythmBarLayout(round: round, bar: 0, board: session.board, tiles: tiles, drawings: drawings)
            let b = RhythmBarLayout(round: round, bar: 1, board: session.board, tiles: tiles, drawings: drawings)
            let scale = min(CGFloat(1.2), max(0.1, proxy.size.width/CGFloat(a.width+b.width)))
            let offset = max(0, (proxy.size.width-CGFloat(a.width+b.width)*scale)/2)
            ZStack(alignment: .topLeading) {
                if let slot = a.slots.first(where: { $0.start == round.pulse }) {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(SolfegeTheme.violet.opacity(page == 3 && session.didTap && !session.didDrag ? 0.9 : 0), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        .frame(width: CGFloat(slot.width)*scale, height: 82*scale).tutorialTarget(.dropSlot)
                        .offset(x: offset+CGFloat(slot.x)*scale, y: 16+12*scale)
                }
                if let left = session.board.placements.first(where: { $0.start == .zero }), let head = a.lastHead(left) {
                    Circle().stroke(SolfegeTheme.violet.opacity(page == 5 && session.tieMode ? 0.9 : 0), lineWidth: 2)
                        .frame(width: 32*scale, height: 32*scale).tutorialTarget(.tieStart)
                        .offset(x: offset+CGFloat(head)*scale-16*scale, y: 16+65*scale-16*scale)
                }
                if let right = session.board.placements.first(where: { $0.start == round.pulse }), let head = a.firstHead(right) {
                    Circle().stroke(SolfegeTheme.violet.opacity(page == 5 && session.tieMode ? 0.9 : 0), lineWidth: 2)
                        .frame(width: 32*scale, height: 32*scale).tutorialTarget(.tieEnd)
                        .offset(x: offset+CGFloat(head)*scale-16*scale, y: 16+65*scale-16*scale)
                }
            }
        }
    }
    private func drop(_ id: String, at point: CGPoint) {
        guard let round = TutorialSamples.rhythmRound, let bank = TutorialSamples.rhythm,
              let entry = barFrames.first(where: { $0.value.insetBy(dx: -10, dy: -10).contains(point) }) else {
            session.message = "강조된 점선 칸까지 끌어놓아보세요."; return
        }
        let layout = RhythmBarLayout(round: round, bar: entry.key, board: session.board, tiles: bank.tileMap, drawings: TutorialSamples.engraving?.tiles ?? RhythmInk.drawings)
        let scale = Double(entry.value.width)/layout.width
        let time = layout.nearestTime(to: Double(point.x-entry.value.minX)/scale, tiles: bank.tileMap)
        _ = session.dropTile(id, at: time)
    }
    private var actions: some View {
        HStack(spacing: 14) {
            HStack(spacing: 14) {
                Button { listen(false) } label: { RhythmReplayIcon().frame(width: 32, height: 32) }.accessibilityLabel("바로 다시 듣기")
                if kind != .echoDragon {
                    Button { listen(true) } label: { RhythmReplayIcon(withMetronome: true).frame(width: 32, height: 32) }.accessibilityLabel("예비박부터 다시 듣기")
                }
            }.buttonStyle(.bordered).tutorialTarget(.replay).allowsHitTesting(page == 2 && !audio.playing)
            Button(action: session.undo) { Image(systemName: "arrow.uturn.backward").frame(width: 28, height: 28) }
                .buttonStyle(.bordered).accessibilityLabel("되돌리기").tutorialTarget(.undo)
                .allowsHitTesting(kind == .memoryRun && [3, 4].contains(page))
            if kind == .memoryRun {
                Button(action: session.eraseBar) { Image(systemName: "eraser").frame(width: 28, height: 28) }
                    .buttonStyle(.bordered).accessibilityLabel("이 마디 지우기").tutorialTarget(.erase).allowsHitTesting(page == 4)
            }
            Spacer()
            if kind == .rhythmPuzzle {
                Button(action: session.enableTie) { RhythmTieIcon().frame(width: 32, height: 32) }
                    .buttonStyle(.bordered).tint(session.tieMode ? .blue : SolfegeTheme.violet)
                    .accessibilityLabel("타이 연결").tutorialTarget(.tie).allowsHitTesting(page == 5)
            }
            Button(page <= 1 ? "시작" : "제출") { if page == 1 { listen(kind != .echoDragon) } else { submit() } }
                .buttonStyle(PrimaryButton()).frame(minWidth: 150).tutorialTarget(.start).tutorialTarget(.submit)
                .allowsHitTesting((page == 1 || page == kind.steps.count) && !audio.playing)
        }.frame(height: 54)
    }
    private func listen(_ countIn: Bool) {
        if kind == .echoDragon {
            session.clearEcho(); pendingReaction = nil; echoPhase = .singing
            audio.play(events: [MusicEvent(midi: 60, onset: 0, duration: 480), MusicEvent(midi: 64, onset: 640, duration: 480)], ticks: 1120)
        } else if kind == .memoryRun, let score = TutorialSamples.memory?.score {
            audio.play(events: score.events, ticks: score.totalTicks, countIn: countIn, meter: score.timeSignature)
        } else if let round = TutorialSamples.rhythmRound {
            audio.play(events: round.audio.compactMap { note in
                guard let onset = note.onset.ticks, let duration = note.duration.ticks else { return nil }
                return MusicEvent(midi: note.midi, onset: onset, duration: duration)
            }, ticks: round.totalDuration.ticks ?? 3840, bpm: round.tempoBpm, countIn: countIn, meter: round.meter)
        }
    }
    private func submit() {
        if kind == .echoDragon {
            let inputs = session.echoInputs
            guard inputs.count == 2 else { session.message = "표시된 첫 음부터 두 음을 눌러보세요."; return }
            audio.play(events: inputs.enumerated().map { MusicEvent(midi: $0.element, onset: $0.offset*640, duration: 480) }, ticks: 1120)
            echoPhase = .waiting; pendingReaction = inputs[1]-inputs[0] == 4 ? .happy : .puzzled
        } else { session.message = "실제 게임에서도 같은 방법으로 제출해요." }
    }
}
private struct TutorialChoiceFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
