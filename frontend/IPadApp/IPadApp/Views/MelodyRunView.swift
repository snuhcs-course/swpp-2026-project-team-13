import SwiftUI
import AVFoundation

struct MiniGameHubView: View {
    var connection: RhythmConnection? = nil
    @State private var playing = false
    @State private var playingRhythm = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:26) {
                SectionCaption(eyebrow:"PLAY WITH SOUND",title:"Drills",subtitle:"미니게임을 골라 듣고 기억하는 연습을 해보세요.")
                LazyVGrid(columns:[GridItem(.flexible(),spacing:20),GridItem(.flexible(),spacing:20)],spacing:20) {
                    gameCard("Memory run",subtitle:"선율을 기억하고 건반으로 복원하세요.",icon:"pianokeys") { playing = true }
                    gameCard("Rhythm puzzle",subtitle:"두 마디를 듣고 리듬 조각을 완성하세요.",icon:"metronome") { playingRhythm = true }.disabled(connection == nil)
                }
            }.padding(32).frame(maxWidth:1060).frame(maxWidth:.infinity)
        }
        .fullScreenCover(isPresented:$playing) { MelodyRunView(connection:connection) }
        .fullScreenCover(isPresented:$playingRhythm) { RhythmPuzzleView(connection:connection) }
    }
    private func gameCard(_ title: String, subtitle: String, icon: String, action: @escaping ()->Void) -> some View {
        Button(action:action) {
            VStack(alignment:.leading,spacing:18) {
                HStack { Image(systemName:icon).font(.system(size:42,weight:.light)); Spacer(); Image(systemName:"arrow.up.right") }.foregroundStyle(SORITheme.violet)
                Text(title).font(.system(size:28,weight:.bold,design:.rounded)).foregroundStyle(SORITheme.ink)
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
    @AppStorage("memory-run-tutorial-v2") private var tutorialSeen = false
    @State private var showingTutorial = false
    init(connection: RhythmConnection? = nil) { _game = StateObject(wrappedValue:MelodyRunModel(connection:connection)) }
    var body: some View {
        VStack(spacing:16) {
            HStack {
                Text("Memory run").font(.title2.bold())
                Spacer()
                Button { game.pause(); showingTutorial = true } label: { Image(systemName:"questionmark.circle").frame(width:44,height:44) }.accessibilityLabel("게임 방법")
                Button { game.stop(); dismiss() } label: { Image(systemName:"xmark").frame(width:44,height:44) }.accessibilityLabel("게임 닫기")
            }
            switch game.page {
            case .setup: setup
            case .playing: play
            case .result: result
            case .summary: summary
            }
        }.padding(24).frame(maxWidth:1100).frame(maxWidth:.infinity)
            .background(SORITheme.background.ignoresSafeArea()).tint(SORITheme.violet).preferredColorScheme(.light)
            .overlay { if game.working { ProgressView("잠시 후 시작해요").padding(24).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18)).allowsHitTesting(false) } }
            .task { if !tutorialSeen { showingTutorial = true } }
            .sheet(isPresented:$showingTutorial) { MemoryTutorialView { tutorialSeen = true; showingTutorial = false } }
            .alert("확인이 필요해요",isPresented:Binding(get:{game.error != nil},set:{if !$0 {game.error = nil}})) { Button("확인") { game.error = nil } } message: { Text(game.error ?? "") }
            .onChange(of:scenePhase) { _, phase in if phase != .active { game.pause() } }
            .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.interruptionNotification).receive(on:RunLoop.main)) { _ in game.pause() }
            .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.mediaServicesWereResetNotification).receive(on:RunLoop.main)) { _ in game.pause() }
            .onReceive(NotificationCenter.default.publisher(for:.AVAudioEngineConfigurationChange).receive(on:RunLoop.main)) { n in if game.audio.owns(n), !game.audio.isRunning { game.pause() } }
            .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.routeChangeNotification).receive(on:RunLoop.main)) { n in
                if let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, AVAudioSession.RouteChangeReason(rawValue:raw) == .oldDeviceUnavailable { game.pause() }
            }
            .onDisappear { game.stop() }
    }
    private var setup: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:26) {
                Text("듣고, 기억하고, 건반으로 이어보세요.").font(.title3).padding(.top,28)
                Picker("모드",selection:$game.settings.mode) { Text("메모리").tag(MelodyMode.memory); Text("그루브").tag(MelodyMode.groove) }.pickerStyle(.segmented)
                Picker("난이도",selection:$game.difficulty) { ForEach(MemoryDifficulty.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                VStack(alignment:.leading,spacing:14) {
                    HStack { Text(game.difficulty.title).font(.title3.bold()); Spacer(); Text(game.difficulty == .beginner ? "처음이어도 괜찮아요" : game.difficulty == .intermediate ? "조금 더 길게" : "네 마디를 한 번에").foregroundStyle(.secondary) }
                    HStack(spacing:10) {
                        ForEach(Array(game.difficulty.barPlan.enumerated()),id:\.offset) { i,bars in
                            VStack(spacing:8) { Text("\(i+1)").font(.caption).foregroundStyle(.secondary); Text("\(bars)마디").font(.headline) }
                                .frame(maxWidth:.infinity).padding(.vertical,16).background(SORITheme.soft,in:RoundedRectangle(cornerRadius:12))
                        }
                    }
                    Text(game.settings.mode == .memory ? "예비박 뒤 선율을 쭉 듣고 복원해요. 입력 시간은 무제한이에요." : "한 마디를 듣고, 준비박 뒤 건반으로 답해요.").font(.subheadline).foregroundStyle(.secondary)
                    if game.difficulty == .beginner { Text("짧고 단순한 선율 · 흰건반 · 첫 음 제공").font(.subheadline).foregroundStyle(SORITheme.violet) }
                }.padding(22).background(.white,in:RoundedRectangle(cornerRadius:18))
                Button("4문제 시작") { game.newSet() }.buttonStyle(PrimaryButton()).disabled(game.catalog == nil || game.working || showingTutorial)
                storage
                credits
            }
        }
    }
    private var setProgress: some View {
        HStack(spacing:7) {
            ForEach(0..<4,id:\.self) { i in Capsule().fill(i < game.setIndex || (i == game.setIndex && game.page == .result) ? SORITheme.violet : SORITheme.violet.opacity(0.13)).frame(height:6) }
            Text("\(game.setIndex+1)/4").font(.caption.monospacedDigit()).padding(.leading,8)
        }
    }
    private var play: some View {
        GeometryReader { geometry in
            VStack(spacing:14) {
                setProgress
                HStack(spacing:14) {
                    if let meter = game.round?.score.timeSignature { Text("\(meter.numerator)/\(meter.denominator)").font(.system(size:32,weight:.bold,design:.rounded)) }
                    Text(game.tempoLabel).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(game.label).font(.headline).foregroundStyle(SORITheme.violet)
                    Button { game.paused ? game.resume() : game.pause() } label: { Image(systemName:game.paused ? "play.fill" : "pause.fill").frame(width:44,height:44) }.accessibilityLabel(game.paused ? "계속하기" : "일시 정지")
                }
                if let label = game.question?.sourceLabel { Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading) }
                if game.phase != .input { ProgressView(value:min(1,max(0,game.progress))).tint(SORITheme.violet) }
                ScrollView {
                    if let round = game.round, let answers = game.answers {
                        LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:12),count:geometry.size.width < 650 ? 1 : 2),spacing:12) {
                            ForEach(1...round.score.measures,id:\.self) { bar in
                                playBar(bar,round:round,answers:answers)
                            }
                        }
                    }
                }.frame(maxHeight:.infinity)
                MelodyPianoView(range:game.keyboardRange,enabled:game.canEnter,solfege:game.difficulty == .beginner,reference:game.round?.targets.first?.midi,onDown:game.keyDown,onUp:game.keyUp)
                    .frame(height:max(150,min(230,geometry.size.height*0.30))).frame(maxWidth:game.difficulty == .beginner ? 780 : .infinity)
                HStack(spacing:12) {
                    if game.settings.mode == .memory { Button { game.listenAgain() } label: { Label("다시 듣기",systemImage:"arrow.counterclockwise") }.buttonStyle(.bordered).disabled(!game.canEnter) }
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
    private func playBar(_ bar: Int, round: MelodyRound, answers: MelodyAnswers) -> some View {
        let display = round.display(measure:bar,answers:answers.pitches)
        return VStack(alignment:.leading,spacing:4) {
            HStack {
                Text("\(bar)마디").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if bar == round.targets.first?.measure { Text("첫 음 제공").font(.caption2).foregroundStyle(SORITheme.violet) }
            }
            fittedStaff(display.0,round:round,pending:display.1,bar:bar)
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.white,in:RoundedRectangle(cornerRadius:16))
            .overlay(RoundedRectangle(cornerRadius:16).stroke(game.measure == bar ? SORITheme.violet.opacity(0.65) : .clear,lineWidth:1.5))
            .contentShape(Rectangle()).onTapGesture { game.selectBar(bar) }
    }
    private func fittedStaff(_ score: MusicScore, round: MelodyRound, pending: Set<Int> = [], incorrect: Set<Int> = [], bar: Int) -> some View {
        let source = round.score.symbols.filter { $0.measure == bar }
        let spacing = MelodyBarSpacing(symbols:source,fifths:round.source.fifths,clef:round.source.clef,displayedSymbols:score.symbols)
        return ViewThatFits(in:.horizontal) {
            MelodyStaff(score:score,fifths:round.source.fifths,clef:round.source.clef,pending:pending,incorrect:incorrect,spacing:spacing,scale:0.8)
            MelodyStaff(score:score,fifths:round.source.fifths,clef:round.source.clef,pending:pending,incorrect:incorrect,spacing:spacing,scale:0.65)
            ScrollView(.horizontal,showsIndicators:true) { MelodyStaff(score:score,fifths:round.source.fifths,clef:round.source.clef,pending:pending,incorrect:incorrect,spacing:spacing,scale:0.8) }.frame(height:spacing.height*0.8)
        }
    }
    private var result: some View {
        ScrollView {
            if let round = game.round, let answers = game.answers {
                VStack(alignment:.leading,spacing:20) {
                    setProgress
                    HStack(alignment:.firstTextBaseline) {
                        Text("\(answers.result.accuracy)%").font(.system(size:48,weight:.bold,design:.rounded)).foregroundStyle(SORITheme.violet)
                        Text("\(answers.result.correct)/\(answers.result.expected.count)음").foregroundStyle(.secondary)
                        Spacer(); Text("첫 음 제외 · 음높이 채점").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing:12) {
                        Button { game.replay(user:false) } label: { Label("원본",systemImage:"play.fill") }.buttonStyle(.bordered)
                        Button { game.replay(user:true) } label: { Label("내 답",systemImage:"play.fill") }.buttonStyle(.bordered)
                        if game.replaying != nil { Button { game.stopReplay() } label: { Image(systemName:"stop.fill") }.accessibilityLabel("재생 정지") }
                        Spacer(); Button("다시 풀기") { game.retry() }.buttonStyle(.bordered).disabled(game.working)
                        Button(game.setIndex == 3 ? "세트 결과" : "다음") { game.next() }.buttonStyle(PrimaryButton(compact:true)).disabled(game.working)
                    }
                    ForEach(1...round.score.measures,id:\.self) { bar in
                        let expected = round.display(measure:bar,answers:answers.pitches,reveal:true)
                        let actual = round.display(measure:bar,answers:answers.pitches)
                        VStack(alignment:.leading,spacing:8) {
                            Text("\(bar)마디").font(.caption).foregroundStyle(.secondary)
                            HStack(alignment:.top,spacing:18) {
                                VStack(alignment:.leading,spacing:4) { Text("정답").font(.caption).foregroundStyle(SORITheme.green); fittedStaff(expected.0,round:round,bar:bar) }
                                VStack(alignment:.leading,spacing:4) { Text("내 답").font(.caption).foregroundStyle(.secondary); fittedStaff(actual.0,round:round,pending:actual.1,incorrect:actual.2,bar:bar) }
                            }
                        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(.white,in:RoundedRectangle(cornerRadius:16))
                    }
                    storage
                }
            }
        }
    }
    private var summary: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                Text("네 문제를 모두 풀었어요").font(.largeTitle.bold()).padding(.top,28)
                ForEach(0..<4,id:\.self) { i in
                    HStack { Text("\(i+1)번").font(.headline); Text("\(game.setExcerpts.indices.contains(i) ? game.setExcerpts[i].bars : 2)마디").foregroundStyle(.secondary); Spacer(); Text("\(game.setScores[i] ?? 0)%").font(.title2.bold()).foregroundStyle(SORITheme.violet) }
                        .padding(20).background(.white,in:RoundedRectangle(cornerRadius:16))
                }
                Button("다시 연습하기") { game.setup() }.buttonStyle(PrimaryButton())
                storage
            }
        }
    }
    private var storage: some View {
        HStack {
            Text(game.storageFailed ? "기기 저장을 확인해 주세요" : "연습 기록은 기기에 저장돼요").font(.caption).foregroundStyle(.secondary)
            if game.storageFailed { Button("저장 재시도") { game.retryStorage() }.font(.caption) }
            Spacer(); if let url = game.exportURL { ShareLink(item:url) { Image(systemName:"square.and.arrow.up") }.accessibilityLabel("연습 기록 내보내기") }
        }
    }
    private var credits: some View {
        DisclosureGroup("음원·문제 출처") {
            VStack(alignment:.leading,spacing:8) {
                Text("기존 선율: The Trained Ear · Andre Mount · CC BY-SA 4.0. 중급 청음과 클래식 발췌 선율을 함께 사용해요.")
                Link("피아노: YDP Grand Piano · CC BY 3.0",destination:URL(string:"https://freepats.zenvoid.org/Piano/acoustic-grand-piano.html")!)
                Link("기존 선율 라이선스",destination:URL(string:"https://creativecommons.org/licenses/by-sa/4.0/")!)
                Text("난도는 음정·반복·음 수·리듬을 반영한 실험값이에요. 초급은 별도의 쉬운 선율 조건을 적용해요.")
                ForEach(["melody-source-license","melody-piano-license"],id:\.self) { name in
                    if let url = Bundle.main.url(forResource:name,withExtension:"txt"), let text = try? String(contentsOf:url,encoding:.utf8) { Text(text).textSelection(.enabled) }
                }
            }.font(.caption).foregroundStyle(.secondary).padding(.top,10)
        }.font(.caption).foregroundStyle(.secondary)
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

struct MemoryTutorialView: View {
    let done: ()->Void
    @State private var step = 0
    private let icons = ["ear","pianokeys","arrow.uturn.backward","checkmark.circle"]
    private let titles = ["먼저 선율을 들어요","첫 음부터 이어보세요","천천히 고쳐도 괜찮아요","네 문제를 한 세트로"]
    private let messages = [
        "메모리는 예비박 뒤 두 마디 또는 네 마디를 끊지 않고 들려줘요. 다 들은 뒤 입력해요. 그루브는 한 마디 듣기와 입력을 번갈아 해요.",
        "첫 음은 이미 적혀 있어요. 회색 음표 자리에 나머지 음을 건반으로 차례대로 넣으세요. 리듬·쉼표·붙임줄은 자동이에요. 초급은 도레미가 적힌 흰건반을 사용해요.",
        "메모리는 시간제한이 없어요. 다시 듣기, 한 음 취소, 마디 지우기를 사용할 수 있어요. 마디를 눌러 수정할 곳을 고르세요. 그루브는 입력 시간이 끝나면 다음 마디로 넘어가요.",
        "제출하면 정답과 내 답을 함께 확인해요. 첫 음을 제외한 음높이를 채점해요. 중급은 2·2·4·4마디, 초급은 모두 2마디, 고급은 모두 4마디예요."
    ]
    var body: some View {
        VStack(spacing:28) {
            HStack { Text("Memory run · 게임 방법").font(.headline); Spacer(); Button("닫기",action:done) }
            Spacer()
            Image(systemName:icons[step]).font(.system(size:72,weight:.light)).foregroundStyle(SORITheme.violet).frame(width:150,height:150).background(SORITheme.soft,in:RoundedRectangle(cornerRadius:26))
            Text(titles[step]).font(.title2.bold())
            Text(messages[step]).font(.body).lineSpacing(7).multilineTextAlignment(.center).frame(maxWidth:490)
            Spacer()
            HStack(spacing:8) { ForEach(0..<4,id:\.self) { i in Capsule().fill(i == step ? SORITheme.violet : SORITheme.soft).frame(width:26,height:5) } }
            HStack { if step > 0 { Button("이전") { step -= 1 } }; Spacer(); Button(step == 3 ? "시작해 볼게요" : "다음") { if step == 3 { done() } else { step += 1 } }.buttonStyle(PrimaryButton(compact:true)) }
        }.padding(32).frame(maxWidth:650).frame(maxWidth:.infinity).background(SORITheme.background.ignoresSafeArea())
    }
}
