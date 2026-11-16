import SwiftUI
import AVFoundation

struct MiniGameHubView: View {
    var connection: RhythmConnection? = nil
    @State private var playing = false
    @State private var playingRhythm = false
    @State private var playingEchoDragon = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:26) {
                SectionCaption(eyebrow:"PLAY WITH SOUND",title:"Drill",subtitle:"미니게임을 골라 듣고 기억하는 연습을 해보세요.")
                LazyVGrid(columns:[GridItem(.flexible(),spacing:20),GridItem(.flexible(),spacing:20)],spacing:20) {
                    gameCard("에코 드래곤",subtitle:"작은 간격부터 차근차근, 드래곤의 부름에 피아노로 답해요.",icon:"sparkles") { playingEchoDragon = true }
                    gameCard("Memory run",subtitle:"선율을 기억하고 건반으로 복원하세요.",icon:"pianokeys") { playing = true }
                    gameCard("Rhythm puzzle",subtitle:"두 마디를 듣고 리듬 조각을 완성하세요.",icon:"metronome") { playingRhythm = true }.disabled(connection == nil)
                }
            }.padding(32).frame(maxWidth:1060).frame(maxWidth:.infinity)
        }
        .fullScreenCover(isPresented:$playing) { MelodyRunView(connection:connection) }
        .fullScreenCover(isPresented:$playingRhythm) { RhythmPuzzleView(connection:connection) }
        .fullScreenCover(isPresented:$playingEchoDragon) { EchoDragonView() }
    }
    private func gameCard(_ title: String, subtitle: String, icon: String, action: @escaping ()->Void) -> some View {
        Button(action:action) {
            VStack(alignment:.leading,spacing:18) {
                HStack { Image(systemName:icon).font(.system(size:42,weight:.light)); Spacer(); Image(systemName:"arrow.up.right") }.foregroundStyle(SolfegeTheme.violet)
                Text(title).font(.system(size:28,weight:.bold,design:.rounded)).foregroundStyle(SolfegeTheme.ink)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength:0)
            }.padding(28).frame(maxWidth:.infinity,alignment:.leading).frame(height:224)
                .background(.white,in:RoundedRectangle(cornerRadius:22))
        }.buttonStyle(.plain)
    }
}

struct MelodyRunView: View {
    @StateObject private var game: MelodyRunModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("memory-run-tutorial-v4") private var tutorialSeen = false
    @State private var showingTutorial = false
    private let daily: DailyGameContext?
    init(connection: RhythmConnection? = nil, daily: DailyGameContext? = nil) {
        _game = StateObject(wrappedValue:MelodyRunModel(connection:connection)); self.daily = daily
    }
    var body: some View {
        VStack(spacing:16) {
            HStack(spacing:12) {
                Text("Memory run").font(.title2.bold())
                if daily != nil { DailyChip() }
                else if let level = game.level, game.page == .playing || game.page == .result {
                    Pill(text:"레벨 \(level.number) · \(level.keyLabel)",icon:"flag").accessibilityIdentifier("memory-level-label")
                }
                Spacer()
                if [.map,.setup,.playing].contains(game.page) {
                    Button { game.pause(); showingTutorial = true } label: { Label("게임 방법",systemImage:"questionmark.circle").frame(minHeight:44) }.accessibilityLabel("게임 방법")
                }
                Button(action:back) { Image(systemName:"xmark").frame(width:44,height:44) }.accessibilityLabel("뒤로가기")
            }
            switch game.page {
            case .map: if daily == nil { levelMap } else { Spacer() }
            case .setup: setup
            case .playing: play
            case .result: result
            case .summary: summary
            }
        }.padding(24).frame(maxWidth:1100).frame(maxWidth:.infinity)
            .background(SolfegeTheme.background.ignoresSafeArea()).tint(SolfegeTheme.violet).preferredColorScheme(.light)
            .overlay { if game.working { ProgressView("잠시 후 시작해요").padding(24).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18)).allowsHitTesting(false) } }
            .task { if !tutorialSeen { showingTutorial = true } else { startDaily() } }
            .sheet(isPresented:$showingTutorial,onDismiss:{ tutorialSeen = true; startDaily() }) { MemoryTutorialView { tutorialSeen = true; showingTutorial = false } }
            .onChange(of:game.page) { _, page in if page == .result { daily?.finished() } }
            .alert("확인이 필요해요",isPresented:Binding(get:{game.error != nil},set:{if !$0 {game.error = nil}})) {
                if game.storageFailed { Button("저장 다시 시도") { game.retryStorage() } }
                Button("확인") { game.error = nil }
            } message: { Text(game.error ?? "") }
            .onChange(of:scenePhase) { _, phase in if phase != .active { game.pause() } }
            .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.interruptionNotification).receive(on:RunLoop.main)) { _ in game.pause() }
            .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.mediaServicesWereResetNotification).receive(on:RunLoop.main)) { _ in game.pause() }
            .onReceive(NotificationCenter.default.publisher(for:.AVAudioEngineConfigurationChange).receive(on:RunLoop.main)) { n in if game.audio.owns(n), !game.audio.isRunning { game.pause() } }
            .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.routeChangeNotification).receive(on:RunLoop.main)) { n in
                if let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, AVAudioSession.RouteChangeReason(rawValue:raw) == .oldDeviceUnavailable { game.pause() }
            }
            .onDisappear { game.stop() }
    }

    // MARK: Level map (stage selection)
    private var levelMap: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                VStack(alignment:.leading,spacing:10) {
                    Text("선율을 기억해서 건반으로 복원해요").font(.system(size:28,weight:.bold,design:.rounded)).foregroundStyle(SolfegeTheme.ink)
                    Text("레벨마다 정해진 선율이 한 번 나와요. 강조된 첫 음을 뺀 음의 \(MemoryLevel.passAccuracy)% 이상을 맞히면 다음 레벨이 열려요.")
                        .foregroundStyle(SolfegeTheme.muted)
                    HStack { Pill(text:"\(game.levelProgress.cleared.count) / \(MemoryLevel.count) 레벨 완료",icon:"flag") }
                }
                Button { game.openLevel(game.levelProgress.unlocked) } label: {
                    Label("레벨 \(game.levelProgress.unlocked) 시작",systemImage:"play.fill")
                }.buttonStyle(PrimaryButton()).disabled(game.working || showingTutorial).accessibilityIdentifier("memory-continue")
                Text("한 마디 세 음 → 네 음 → 두 마디 → 4도 도약 → 8분음표 → 사장조·바장조 → 네 마디")
                    .font(.subheadline).foregroundStyle(SolfegeTheme.muted)
                LazyVGrid(columns:[GridItem(.adaptive(minimum:120),spacing:14)],spacing:14) {
                    ForEach(1...MemoryLevel.count,id:\.self) { levelButton($0) }
                }.accessibilityIdentifier("memory-level-map")
                Button { game.openGroove() } label: {
                    HStack(spacing:18) {
                        Image(systemName:"metronome").font(.system(size:28,weight:.light)).foregroundStyle(SolfegeTheme.violet)
                        VStack(alignment:.leading,spacing:6) {
                            Text("Groove 연습").font(.headline)
                            Text("한 마디씩 듣고 바로 따라 쳐요. 레벨 진행과는 따로 기록돼요.").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(); Image(systemName:"chevron.right")
                    }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(.white,in:RoundedRectangle(cornerRadius:18))
                }.buttonStyle(.plain)
                Text("레벨 진행과 최고 기록은 이 기기에 저장돼요. 인터넷 연결 없이도 열린 레벨을 풀 수 있어요.")
                    .font(.footnote).foregroundStyle(SolfegeTheme.muted)
            }.padding(.vertical,8)
        }
    }
    private func levelButton(_ number: Int) -> some View {
        let level = MemoryLevel.level(number)
        let unlocked = number <= game.levelProgress.unlocked
        let best = game.levelProgress.best[number]
        let cleared = (best ?? 0) >= MemoryLevel.passAccuracy
        return Button { game.openLevel(number) } label: {
            VStack(alignment:.leading,spacing:8) {
                HStack {
                    Text("\(number)").font(.title2.bold())
                    Spacer(minLength:2)
                    Image(systemName:!unlocked ? "lock.fill" : cleared ? "checkmark.circle.fill" : level.isMilestone ? "sparkles" : "music.note")
                        .font(.caption).foregroundStyle(cleared ? SolfegeTheme.green : unlocked ? SolfegeTheme.violet : SolfegeTheme.muted)
                }
                Text(level.stageTitle).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                Text(best.map { "최고 \($0)%" } ?? (unlocked ? "도전 전" : "잠김")).font(.caption2).foregroundStyle(SolfegeTheme.muted)
            }.padding(14).foregroundStyle(unlocked ? SolfegeTheme.ink : SolfegeTheme.muted)
                .frame(height:104).frame(maxWidth:.infinity)
                .background(unlocked ? Color.white : SolfegeTheme.field,in:RoundedRectangle(cornerRadius:18))
                .overlay(RoundedRectangle(cornerRadius:18).stroke(number == game.levelProgress.unlocked ? SolfegeTheme.violet : .clear,lineWidth:2))
        }.buttonStyle(.plain).disabled(!unlocked || game.working)
            .accessibilityLabel("레벨 \(number), \(level.stageTitle), \(unlocked ? best.map { "최고 \($0)%" } ?? "도전 전" : "잠김")")
            .accessibilityIdentifier("memory-level-\(number)")
    }

    // MARK: Groove setup
    private var setup: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:26) {
                Button("레벨맵으로",systemImage:"chevron.left") { game.showMap() }
                Text("Groove").font(.title2.bold())
                Text("한 마디씩 듣고, 바로 따라 치기").foregroundStyle(.secondary)
                Picker("난이도",selection:$game.difficulty) { ForEach(MemoryDifficulty.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                VStack(alignment:.leading,spacing:12) {
                    Text(difficultyTitle).font(.title3.bold())
                    Text(game.difficulty == .beginner ? "2마디" : game.difficulty == .intermediate ? "2~4마디" : "4마디").foregroundStyle(.secondary)
                }.padding(22).frame(maxWidth:.infinity,alignment:.leading).background(.white,in:RoundedRectangle(cornerRadius:18))
                Button("\(game.difficulty.barPlan.count)문제 시작") { game.newSet() }.buttonStyle(PrimaryButton()).disabled(game.catalog == nil || game.working || showingTutorial)
            }
        }
    }
    private var difficultyTitle: String {
        game.difficulty == .beginner ? "차근차근 따라 치기" : game.difficulty == .intermediate ? "조금 더 빠르게" : "빠른 선율에 도전하기"
    }
    @ViewBuilder private var setProgress: some View {
        if let daily { DailyProgressBar(done:daily.done,current:daily.index) }
        else if game.level == nil {
            HStack(spacing:7) {
                ForEach(0..<game.setCount,id:\.self) { i in Capsule().fill(i < game.setIndex || (i == game.setIndex && game.page == .result) ? SolfegeTheme.violet : SolfegeTheme.violet.opacity(0.13)).frame(height:6) }
                Text("\(game.setIndex+1)/\(game.setCount)").font(.caption.monospacedDigit()).padding(.leading,8)
            }
        }
    }
    // Daily Training skips the level map and opens one question at today's difficulty.
    private func startDaily() {
        guard let daily, game.page == .map || game.page == .setup, !game.working else { return }
        game.newDailyRound(difficulty:daily.difficulty)
    }
    private var play: some View {
        GeometryReader { geometry in
            VStack(spacing:14) {
                setProgress
                HStack(spacing:14) {
                    if let meter = game.round?.score.timeSignature { Text("\(meter.numerator)/\(meter.denominator)").font(.system(size:32,weight:.bold,design:.rounded)) }
                    Text(game.tempoLabel).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(game.label).font(.headline).foregroundStyle(SolfegeTheme.violet)
                    Button { game.paused ? game.resume() : game.pause() } label: { Image(systemName:game.paused ? "play.fill" : "pause.fill").frame(width:44,height:44) }.accessibilityLabel(game.paused ? "계속하기" : "일시 정지")
                }
                if game.phase != .input { ProgressView(value:min(1,max(0,game.progress))).tint(SolfegeTheme.violet) }
                ScrollView {
                    if let round = game.round, let answers = game.answers {
                        MemoryPhraseView(round:round,answers:answers.pitches,selectedBar:game.measure,selectBar:game.selectBar)
                            .padding(.horizontal,12).background(.white,in:RoundedRectangle(cornerRadius:16))
                    }
                }.frame(maxHeight:.infinity)
                HStack {
                    Text(game.message.isEmpty ? (game.canEnter ? "\(game.measure)마디 · \(game.currentCount)/\(game.currentTotal)음 입력" : "선율을 듣는 동안 건반 입력을 잠시 기다려 주세요.") : game.message)
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if let first = game.guidedPitch { Text("첫 음 \(MelodyRound.noteName(first)) ↓").font(.subheadline.bold()).foregroundStyle(SolfegeTheme.violet) }
                }
                MelodyPianoView(range:game.keyboardRange,enabled:game.canEnter,solfege:game.showsSolfege,reference:game.guidedPitch,onDown:game.keyDown,onUp:game.keyUp)
                    .frame(height:max(150,min(230,geometry.size.height*0.30))).frame(maxWidth:game.keyboardRange.count <= 13 ? 780 : .infinity)
                HStack(spacing:12) {
                    if game.settings.mode == .memory {
                        Button("바로 듣기",systemImage:"play.fill") { game.listenAgain(includeCountIn:false) }.buttonStyle(.bordered).disabled(!game.canEnter)
                        Button("예비박부터 듣기",systemImage:"metronome") { game.listenAgain(includeCountIn:true) }.buttonStyle(.bordered).disabled(!game.canEnter)
                    }
                    Button { game.undo() } label: { Image(systemName:"arrow.uturn.backward").frame(width:24,height:24) }.buttonStyle(.bordered).disabled(!game.canEnter).accessibilityLabel("한 음 취소")
                    Button { game.clearBar() } label: { Image(systemName:"eraser").frame(width:24,height:24) }.buttonStyle(.bordered).disabled(!game.canEnter).accessibilityLabel("이 마디 지우기")
                    Spacer()
                    Button("제출") { game.finish() }.buttonStyle(PrimaryButton(compact:true)).disabled(!game.canEnter || game.working)
                }
            }.overlay { if game.paused {
                VStack(spacing:18) { Text("잠시 쉬는 중").font(.title3.bold()); Button("계속하기") { game.resume() }.buttonStyle(PrimaryButton()) }
                    .frame(maxWidth:.infinity,maxHeight:.infinity).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18))
            } }
        }
    }
    private var result: some View {
        ScrollView {
            if let round = game.round, let answers = game.answers {
                VStack(alignment:.leading,spacing:20) {
                    setProgress
                    HStack(alignment:.firstTextBaseline) {
                        Text("\(answers.result.accuracy)%").font(.system(size:48,weight:.bold,design:.rounded)).foregroundStyle(SolfegeTheme.violet)
                        Text("\(answers.result.correct)/\(answers.result.expected.count)음").foregroundStyle(.secondary)
                        Spacer()
                    }
                    if let level = game.level {
                        Text(game.passed ? (level.number == MemoryLevel.count ? "마지막 레벨까지 통과했어요!" : "통과! 레벨 \(level.number+1)이 열렸어요.")
                                         : "\(MemoryLevel.passAccuracy)% 이상이면 다음 레벨이 열려요. 다시 풀어 볼까요?")
                            .font(.headline).foregroundStyle(game.passed ? SolfegeTheme.green : SolfegeTheme.ink)
                            .accessibilityIdentifier("memory-level-outcome")
                    }
                    HStack(spacing:12) {
                        Button { game.replay(user:false) } label: { Label("원본",systemImage:"play.fill") }.buttonStyle(.bordered)
                        Button { game.replay(user:true) } label: { Label("내 답",systemImage:"play.fill") }.buttonStyle(.bordered)
                        if game.replaying != nil { Button { game.stopReplay() } label: { Image(systemName:"stop.fill") }.accessibilityLabel("재생 정지") }
                        Spacer()
                        if let daily {
                            DailyNextButton(nextTitle:daily.nextTitle) { game.stop(); daily.next() }.disabled(game.working)
                        } else if let level = game.level {
                            Button("다시 풀기") { game.retry() }.buttonStyle(.bordered).disabled(game.working)
                            Button("레벨맵") { game.showMap() }.buttonStyle(.bordered).disabled(game.working)
                            if game.passed && level.number < MemoryLevel.count {
                                Button("다음 판") { game.nextLevel() }.buttonStyle(PrimaryButton(compact:true)).disabled(game.working).accessibilityIdentifier("memory-next-level")
                            }
                        } else {
                            Button("다시 풀기") { game.retry() }.buttonStyle(.bordered).disabled(game.working)
                            Button(game.isLastRound ? "결과 보기" : "다음") { game.next() }.buttonStyle(PrimaryButton(compact:true)).disabled(game.working)
                        }
                    }
                    VStack(alignment:.leading,spacing:8) {
                        Text("정답").font(.headline).foregroundStyle(SolfegeTheme.green)
                        MemoryPhraseView(round:round,answers:answers.pitches,reveal:true)
                        Divider().padding(.vertical,8)
                        Text("내 답").font(.headline)
                        MemoryPhraseView(round:round,answers:answers.pitches,markErrors:true)
                    }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(.white,in:RoundedRectangle(cornerRadius:16))
                }
            }
        }
    }
    private var summary: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                Text("\(game.setCount)문제를 모두 풀었어요").font(.largeTitle.bold()).padding(.top,28)
                ForEach(0..<game.setCount,id:\.self) { i in
                    HStack { Text("\(i+1)번").font(.headline); Text("\(game.setExcerpts.indices.contains(i) ? game.setExcerpts[i].bars : 2)마디").foregroundStyle(.secondary); Spacer(); Text("\(game.setScores[i] ?? 0)%").font(.title2.bold()).foregroundStyle(SolfegeTheme.violet) }
                        .padding(20).background(.white,in:RoundedRectangle(cornerRadius:16))
                }
                HStack(spacing:16) {
                    Button("다시 \(game.setCount)문제 풀기") { game.newSet() }.buttonStyle(PrimaryButton()).disabled(game.working)
                    Button("난이도 변경하기") { game.setup() }.buttonStyle(.bordered)
                }
            }
        }
    }
    private func back() {
        if let daily { game.stop(); daily.exit(); return }
        switch game.page {
        case .map: game.stop(); dismiss()
        case .setup: game.showMap()
        case .summary: game.setup()
        case .playing, .result:
            if game.level != nil { game.showMap() } else { game.setup() }
        }
    }
}

struct MelodyStaff: View {
    let score: MusicScore
    let fifths: Int
    let clef: String
    var pending: Set<Int> = []
    var incorrect: Set<Int> = []
    var spacing: MelodyBarSpacing? = nil
    var scale = 0.8
    var body: some View {
        let layout = spacing ?? MelodyBarSpacing(symbols:score.symbols,fifths:fifths,clef:clef)
        Canvas { context,size in NativeScoreRenderer(singleMeasure:true,keyFifths:fifths,clef:clef,pending:pending,incorrect:incorrect,compactSpacing:layout).render(score,context:&context,size:size) }
            .frame(width:layout.width*scale,height:layout.height*scale).background(.white)
            .accessibilityLabel("\(score.symbols.filter { $0.midi != nil }.count)음의 리듬 악보, \(pending.count)음 미입력")
    }
}
