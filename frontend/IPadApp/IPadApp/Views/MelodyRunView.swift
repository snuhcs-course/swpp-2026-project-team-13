import SwiftUI
import AVFoundation

struct MiniGameHubView: View {
    var connection: RhythmConnection? = nil
    @State private var playing = false
    @State private var playingRhythm = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:26) {
                SectionCaption(eyebrow:"PLAY WITH SOUND",title:"Drill",subtitle:"미니게임을 골라 듣고 기억하는 연습을 해보세요.")
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
    @AppStorage("memory-run-tutorial-v3") private var tutorialSeen = false
    @State private var showingTutorial = false
    @State private var choosingDifficulty = false
    init(connection: RhythmConnection? = nil) { _game = StateObject(wrappedValue:MelodyRunModel(connection:connection)) }
    var body: some View {
        VStack(spacing:16) {
            HStack {
                Text("Memory run").font(.title2.bold())
                Spacer()
                Button { game.pause(); showingTutorial = true } label: { Label("게임 방법",systemImage:"questionmark.circle").frame(minHeight:44) }.accessibilityLabel("게임 방법")
                Button { game.stop(); dismiss() } label: { Image(systemName:"xmark").frame(width:44,height:44) }.accessibilityLabel("게임 닫기")
            }
            switch game.page {
            case .setup: setup
            case .playing: play
            case .result: result
            case .summary: summary
            }
        }.padding(24).frame(maxWidth:1100).frame(maxWidth:.infinity)
            .background(SolfegeTheme.background.ignoresSafeArea()).tint(SolfegeTheme.violet).preferredColorScheme(.light)
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
                if !choosingDifficulty {
                    Text("어떻게 연습할까요?").font(.title2.bold()).padding(.top,28)
                    modeButton(.memory,title:"Memory",description:"선율 전체를 듣고, 기억한 음을 건반으로 복원해요. 입력 시간은 무제한이에요.",icon:"brain.head.profile")
                    modeButton(.groove,title:"Groove",description:"한 마디 듣기와 정해진 시간 안에 입력하기를 번갈아 해요.",icon:"metronome")
                } else {
                    Button("모드 다시 선택",systemImage:"chevron.left") { choosingDifficulty = false }
                    Text(game.settings.mode == .memory ? "Memory" : "Groove").font(.title2.bold())
                    Picker("난이도",selection:$game.difficulty) { ForEach(MemoryDifficulty.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    VStack(alignment:.leading,spacing:12) {
                        Text(game.difficulty == .beginner ? "짧고 익숙한 선율부터" : game.difficulty == .intermediate ? "조금 더 길고 빠르게" : "네 마디를 한 번에").font(.title3.bold())
                        Text(game.difficulty == .beginner ? "2마디씩 4문제 · 느린 속도 · 흰건반" : game.difficulty == .intermediate ? "2 · 2 · 4 · 4마디 · 보통 속도" : "4마디씩 4문제 · 빠른 속도").foregroundStyle(.secondary)
                        Text("난이도에 따라 길이·재생 속도·선율의 복잡도가 달라져요. 첫 음은 표시된 건반을 직접 눌러 시작하세요.").font(.subheadline).foregroundStyle(.secondary)
                    }.padding(22).frame(maxWidth:.infinity,alignment:.leading).background(.white,in:RoundedRectangle(cornerRadius:18))
                    Button("4문제 시작") { game.newSet() }.buttonStyle(PrimaryButton()).disabled(game.catalog == nil || game.working || showingTutorial)
                }
                storage
                credits
            }
        }
    }
    private func modeButton(_ mode: MelodyMode,title: String,description: String,icon: String) -> some View {
        Button { game.settings.mode = mode; choosingDifficulty = true } label: {
            HStack(spacing:24) {
                Image(systemName:icon).font(.system(size:36,weight:.light)).frame(width:56).foregroundStyle(SolfegeTheme.violet)
                VStack(alignment:.leading,spacing:10) { Text(title).font(.title.bold()); Text(description).font(.body).foregroundStyle(.secondary) }
                Spacer(); Image(systemName:"chevron.right")
            }.padding(28).frame(maxWidth:.infinity,alignment:.leading).background(.white,in:RoundedRectangle(cornerRadius:18))
        }.buttonStyle(.plain)
    }
    private var setProgress: some View {
        HStack(spacing:7) {
            ForEach(0..<4,id:\.self) { i in Capsule().fill(i < game.setIndex || (i == game.setIndex && game.page == .result) ? SolfegeTheme.violet : SolfegeTheme.violet.opacity(0.13)).frame(height:6) }
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
                    Text(game.label).font(.headline).foregroundStyle(SolfegeTheme.violet)
                    Button { game.paused ? game.resume() : game.pause() } label: { Image(systemName:game.paused ? "play.fill" : "pause.fill").frame(width:44,height:44) }.accessibilityLabel(game.paused ? "계속하기" : "일시 정지")
                }
                if let label = game.question?.sourceLabel { Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading) }
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
                MelodyPianoView(range:game.keyboardRange,enabled:game.canEnter,solfege:game.difficulty == .beginner,reference:game.guidedPitch,onDown:game.keyDown,onUp:game.keyUp)
                    .frame(height:max(150,min(230,geometry.size.height*0.30))).frame(maxWidth:game.difficulty == .beginner ? 780 : .infinity)
                HStack(spacing:12) {
                    if game.settings.mode == .memory {
                        Menu {
                            Button("바로 다시 듣기",systemImage:"play.fill") { game.listenAgain(includeCountIn:false) }
                            Button("예비박부터 듣기",systemImage:"metronome") { game.listenAgain(includeCountIn:true) }
                        } label: { Label("다시 듣기",systemImage:"arrow.counterclockwise") }.buttonStyle(.bordered).disabled(!game.canEnter)
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
                        Spacer(); Text("첫 음 제외 · 음높이 채점").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing:12) {
                        Button { game.replay(user:false) } label: { Label("원본",systemImage:"play.fill") }.buttonStyle(.bordered)
                        Button { game.replay(user:true) } label: { Label("내 답",systemImage:"play.fill") }.buttonStyle(.bordered)
                        if game.replaying != nil { Button { game.stopReplay() } label: { Image(systemName:"stop.fill") }.accessibilityLabel("재생 정지") }
                        Spacer(); Button("다시 풀기") { game.retry() }.buttonStyle(.bordered).disabled(game.working)
                        Button(game.setIndex == 3 ? "세트 결과" : "다음") { game.next() }.buttonStyle(PrimaryButton(compact:true)).disabled(game.working)
                    }
                    VStack(alignment:.leading,spacing:8) {
                        Text("정답").font(.headline).foregroundStyle(SolfegeTheme.green)
                        MemoryPhraseView(round:round,answers:answers.pitches,reveal:true)
                        Divider().padding(.vertical,8)
                        Text("내 답").font(.headline)
                        MemoryPhraseView(round:round,answers:answers.pitches,markErrors:true)
                    }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(.white,in:RoundedRectangle(cornerRadius:16))
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
                    HStack { Text("\(i+1)번").font(.headline); Text("\(game.setExcerpts.indices.contains(i) ? game.setExcerpts[i].bars : 2)마디").foregroundStyle(.secondary); Spacer(); Text("\(game.setScores[i] ?? 0)%").font(.title2.bold()).foregroundStyle(SolfegeTheme.violet) }
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
