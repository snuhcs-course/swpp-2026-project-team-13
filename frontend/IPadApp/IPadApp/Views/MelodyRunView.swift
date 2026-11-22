import SwiftUI
import AVFoundation

struct MelodyRunView: View {
    @StateObject private var game: MelodyRunModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tutorialScope) private var tutorialScope
    @State private var showingTutorial = false
    @State private var choosingDifficulty = false
    @State private var confirmingExit = false
    @State private var confirmingReveal = false
    private let daily: DailyGameContext?
    private let stage: DrillStageContext?
    init(connection: RhythmConnection? = nil, daily: DailyGameContext? = nil, stage: DrillStageContext? = nil, preparedGame: MelodyRunModel? = nil) {
        _game = StateObject(wrappedValue:preparedGame ?? MelodyRunModel(connection:connection,stageMode:true)); self.daily = daily; self.stage = stage
    }
    var body: some View {
        VStack(spacing:16) {
            HStack {
                Text("Memory run").font(.title2.bold())
                if daily != nil { DailyChip() }
                if let stage { StageChip(stage:stage.stage) }
                Spacer()
                if game.page == .setup || game.page == .playing {
                    TutorialHelpButton(action: openTutorial)
                }
                Button(action:back) { Image(systemName:"xmark").frame(width:44,height:44) }.accessibilityLabel("뒤로가기")
            }
            switch game.page {
            case .setup: if let stage { stageStart(stage) } else { setup }
            case .playing: play
            case .result: if game.settings.mode == .memory { play } else { result }
            case .summary: summary
            }
        }.padding(24).frame(maxWidth:1100).frame(maxWidth:.infinity)
            .background(SolfegeTheme.background.ignoresSafeArea()).tint(SolfegeTheme.violet).preferredColorScheme(.light)
            .overlay { if game.working && stage == nil { ProgressView("잠시 후 시작해요").padding(24).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18)).allowsHitTesting(false) } }
            .overlay { if game.contentLoading { ProgressView("문제를 준비하고 있어요").padding(24).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18)) } }
            .task {
                game.requireManualStart(); stage?.activity(false)
                await game.prepareContent(); guard !Task.isCancelled else { return }
                if let stage { game.newStageRound(stage.question) } else { startDaily() }
                if stage == nil && daily == nil && !TutorialHistory.hasSeen(.memoryRun, scope: tutorialScope) { openTutorial() }
            }
            .onChange(of: game.awaitingStart) { _, ready in
                if ready && !TutorialHistory.hasSeen(.memoryRun, scope: tutorialScope) { openTutorial() }
            }
            .overlay {
                if showingTutorial {
                    TutorialWalkthrough(kind: .memoryRun) {
                        game.finishTutorial(); showingTutorial = false
                        if game.page == .setup { startDaily() }
                    }
                }
            }
            .onChange(of: game.paused) { _, paused in stage?.activity(!paused && !game.awaitingStart && !showingTutorial) }
            .onChange(of:stage?.question.id) { _, _ in if let stage { game.newStageRound(stage.question) } }
            .onChange(of:game.page) { _, page in if page == .result {
                if let daily { do { try game.commitStage(); daily.finished() } catch { game.error=error.localizedDescription } }
                stage?.report(DrillRoundResult(accuracy:game.answers?.result.accuracy ?? 0,revealed:game.answerRevealed,elapsedMs:0))
            } else if page == .summary && stage == nil { do { try game.commitStage() } catch { game.error=error.localizedDescription } } }
            .alert(confirmingExit ? "게임 종료" : "확인이 필요해요",isPresented:Binding(get:{confirmingExit || game.error != nil},set:{if !$0 { confirmingExit=false; game.error=nil }})) {
                if confirmingExit {
                    Button("계속하기",role:.cancel) { if game.page == .setup { startDaily() } else { game.resume() } }
                    Button("종료",role:.destructive) { game.discardStage(); leave() }
                } else {
                    if game.catalog == nil { Button("다시 시도") { Task { await game.prepareContent(); startDaily() } } }
                    if game.storageFailed { Button("저장 다시 시도") { game.retryStorage() } }
                    Button("확인") { game.error=nil }
                }
            } message: { Text(confirmingExit ? "진행 상황이 저장되지 않습니다. 정말 종료하시겠습니까?" : game.error ?? "") }
            .confirmationDialog("정답을 보면 이번 스테이지를 클리어할 수 없어요.",isPresented:$confirmingReveal,titleVisibility:.visible) {
                Button("정답 보기",role:.destructive) { stage?.acknowledgeReveal(); game.revealAnswer() }
                Button("취소",role:.cancel) { }
            }
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
        ScrollView(.vertical,showsIndicators:true) {
            VStack(alignment:.leading,spacing:26) {
                if !choosingDifficulty {
                    Text("게임 선택").font(.title2.bold()).padding(.top,28)
                    modeButton(.memory,title:"Memory",description:"선율 전체를 기억해서 건반으로 복원하기",icon:"brain.head.profile")
                    modeButton(.groove,title:"Groove",description:"한 마디씩 듣고, 바로 따라 치기",icon:"metronome")
                } else {
                    Button("모드 다시 선택",systemImage:"chevron.left") { choosingDifficulty = false }
                    Text(game.settings.mode == .memory ? "Memory" : "Groove").font(.title2.bold())
                    Picker("난이도",selection:$game.difficulty) { ForEach(MemoryDifficulty.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    VStack(alignment:.leading,spacing:12) {
                        Text(difficultyTitle).font(.title3.bold())
                        Text("2마디").foregroundStyle(.secondary)
                    }.padding(22).frame(maxWidth:.infinity,alignment:.leading).background(.white,in:RoundedRectangle(cornerRadius:18))
                    Button("\(game.difficulty.barPlan.count)문제 시작") { game.newSet() }.buttonStyle(PrimaryButton()).disabled(game.catalog == nil || game.working || showingTutorial)
                }
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
    private var difficultyTitle: String {
        if game.settings.mode == .groove {
            return game.difficulty == .beginner ? "차근차근 따라 치기" : game.difficulty == .intermediate ? "조금 더 빠르게" : "빠른 선율에 도전하기"
        }
        return game.difficulty == .beginner ? "짧고 익숙한 선율부터" : game.difficulty == .intermediate ? "조금 더 다양한 선율로" : "복잡한 두 마디에 도전하기"
    }
    @ViewBuilder private var setProgress: some View {
        if let stage { DrillSetProgress(results:stage.results,index:stage.index) }
        else if let daily { DailyProgressBar(done:daily.done,current:daily.index) } else { HStack(spacing:7) {
            ForEach(0..<game.setCount,id:\.self) { i in Capsule().fill(i < game.setIndex || (i == game.setIndex && game.page == .result) ? SolfegeTheme.violet : SolfegeTheme.violet.opacity(0.13)).frame(height:6) }
            Text("\(game.setIndex+1)/\(game.setCount)").font(.caption.monospacedDigit()).padding(.leading,8)
        } }
    }
    // Daily Training and a Drill stage skip setup and open one question at their difficulty.
    private func startDaily() {
        guard game.page == .setup, !game.working else { return }
        if let daily { game.newDailyRound(difficulty:daily.difficulty) }
        else if let stage { game.newStageRound(stage.question) }
    }
    // Shown only if the stage's question could not start (content failed, or paused while starting).
    private func stageStart(_ stage: DrillStageContext) -> some View {
        VStack(spacing:18) {
            Text("\(stage.stage.name) · Memory run").font(.title2.bold())
            Text(stage.stage.difficulty.title).foregroundStyle(.secondary)
            Button("시작하기") { startDaily() }.buttonStyle(PrimaryButton()).disabled(game.catalog == nil || game.working || showingTutorial)
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private var play: some View {
        GeometryReader { geometry in
            VStack(spacing:14) {
                setProgress
                playHeader
            if game.page == .playing && !game.awaitingStart && game.phase != .input { ProgressView(value:min(1,max(0,game.progress))).tint(SolfegeTheme.violet) }
                ScrollView(.vertical,showsIndicators:true) { playNotation }.frame(maxHeight:.infinity)
                playFeedbackRow
                playKeyboard(height:geometry.size.height)
                playActions
            }.overlay { pauseLayer }
        }
    }
    private var playHeader: some View {
        HStack(spacing:14) {
            if let meter=game.round?.score.timeSignature { Text("\(meter.numerator)/\(meter.denominator)").font(.system(size:32,weight:.bold,design:.rounded)) }
            Text(game.tempoLabel).font(.subheadline).foregroundStyle(.secondary)
            if let credit=game.classicalCredit { Text(credit).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Text(game.page == .result ? (game.replaying ?? "결과 확인") : game.label).font(.headline).foregroundStyle(SolfegeTheme.violet)
            if game.page == .playing && !game.awaitingStart {
                Button { game.paused ? game.resume() : game.pause() } label: { Image(systemName:game.paused ? "play.fill" : "pause.fill").frame(width:44,height:44) }.accessibilityLabel(game.paused ? "계속하기" : "일시 정지")
            }
        }
    }
    @ViewBuilder private var playNotation: some View {
        if let round=game.round, let answers=game.answers {
            Group {
                if game.page == .playing {
                    MemoryPhraseView(round:round,answers:answers.pitches,markErrors:game.submissionCount>=2,selectedBar:game.measure,selectBar:{ bar in game.selectBar(bar) })
                } else {
                    MemoryPhraseView(round:round,answers:answers.pitches,reveal:game.answerRevealed,markErrors:game.submissionCount>=2)
                }
            }.padding(.horizontal,12).background(.white,in:RoundedRectangle(cornerRadius:16))
        }
    }
    private var playFeedbackRow: some View {
        HStack {
            Text(playFeedback).font(.subheadline).foregroundStyle(game.page == .result && !game.answerRevealed ? SolfegeTheme.green : SolfegeTheme.ink)
            Spacer()
            if let first=game.guidedPitch, game.page == .playing { Text("첫 음 \(MelodyRound.noteName(first)) ↓").font(.subheadline.bold()).foregroundStyle(SolfegeTheme.violet) }
        }
    }
    private func playKeyboard(height: CGFloat) -> some View {
        MelodyPianoView(range:game.keyboardRange,enabled:game.canEnter,solfege:game.difficulty == .beginner,reference:game.guidedPitch,onDown:game.keyDown,onUp:game.keyUp)
            .frame(height:max(150,min(230,height*0.30))).frame(maxWidth:game.difficulty == .beginner ? 780 : .infinity)
    }
    @ViewBuilder private var pauseLayer: some View {
        if game.paused {
            VStack(spacing:18) { Text("잠시 쉬는 중").font(.title3.bold()); Button("계속하기") { game.resume() }.buttonStyle(PrimaryButton()) }
                .frame(maxWidth:.infinity,maxHeight:.infinity).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18))
        }
    }
    private var playFeedback: String {
        if game.page == .result { return game.answerRevealed ? "정답을 공개했어요." : "정확해요!" }
        if !game.message.isEmpty { return game.message }
        return game.canEnter ? "\(game.measure)마디 · \(game.currentCount)/\(game.currentTotal)음 입력" : "선율을 듣는 동안 건반 입력을 잠시 기다려 주세요."
    }
    private func relisten(_ countIn: Bool) {
        if game.replaying != nil { game.stopReplay() }
        else if game.page == .result { game.replay(user:false,includeCountIn:countIn) }
        else { game.listenAgain(includeCountIn:countIn) }
    }
    private var playActions: some View {
        HStack(spacing:14) {
            if game.settings.mode == .memory {
                Button { relisten(false) } label: {
                    if game.replaying != nil { Image(systemName:"stop.fill").frame(width:32,height:32) }
                    else { RhythmReplayIcon().frame(width:32,height:32) }
                }.buttonStyle(.bordered).disabled(!game.canEnter && game.page != .result).accessibilityLabel(game.replaying == nil ? "바로 다시 듣기" : "재생 정지")
                Button { relisten(true) } label: { RhythmReplayIcon(withMetronome:true).frame(width:32,height:32) }
                    .buttonStyle(.bordered).disabled((!game.canEnter && game.page != .result) || game.replaying != nil).accessibilityLabel("예비박부터 다시 듣기")
            }
            Button { game.undo() } label: { Image(systemName:"arrow.uturn.backward").frame(width:28,height:28) }.buttonStyle(.bordered).disabled(!game.canEnter).accessibilityLabel("한 음 취소")
            Button { game.clearBar() } label: { Image(systemName:"eraser").frame(width:28,height:28) }.buttonStyle(.bordered).disabled(!game.canEnter).accessibilityLabel("이 마디 지우기")
            Spacer()
            if game.page == .playing && game.settings.mode == .memory {
                Button {
                    if let stage, !stage.revealAcknowledged { confirmingReveal=true }
                    else { game.revealAnswer() }
                } label: { Image(systemName:"eye").frame(width:32,height:32) }
                    .buttonStyle(.bordered).tint(.orange).disabled(!game.canEnter).accessibilityLabel("정답 보고 넘기기")
            }
            Spacer()
            if game.awaitingStart {
                Button("시작") { stage?.activity(true); game.startPreparedRound() }
                    .buttonStyle(PrimaryButton(compact: true)).disabled(game.working)
                    .accessibilityIdentifier("memory-start")
            } else if game.page == .result {
                if let daily { DailyNextButton(nextTitle:daily.nextTitle) { game.stop(); daily.next() } }
                else if let stage { Button(stage.nextTitle) { game.stopReplay(); stage.next() }.buttonStyle(PrimaryButton(compact:true)).accessibilityIdentifier("drill-stage-next") }
                else { Button(game.isLastRound ? "결과 보기" : "다음") { game.next() }.buttonStyle(PrimaryButton(compact:true)) }
            } else {
                Button("제출") { if game.settings.mode == .memory { game.submit() } else { game.finish() } }.buttonStyle(PrimaryButton(compact:true)).disabled(!game.canEnter || game.working)
            }
        }
    }
    private func openTutorial() {
        stage?.activity(false); game.suspendForTutorial(); showingTutorial = true
    }
    private var result: some View {
        ScrollView(.vertical,showsIndicators:true) {
            if let round = game.round, let answers = game.answers {
                VStack(alignment:.leading,spacing:20) {
                    setProgress
                    HStack(alignment:.firstTextBaseline) {
                        Text("\(answers.result.accuracy)%").font(.system(size:48,weight:.bold,design:.rounded)).foregroundStyle(SolfegeTheme.violet)
                        Text("\(answers.result.correct)/\(answers.result.expected.count)음").foregroundStyle(.secondary)
                        Spacer()
                    }
                    HStack(spacing:12) {
                        Button { game.replay(user:false) } label: { Label("원본",systemImage:"play.fill") }.buttonStyle(.bordered)
                        Button { game.replay(user:true) } label: { Label("내 답",systemImage:"play.fill") }.buttonStyle(.bordered)
                        if game.replaying != nil { Button { game.stopReplay() } label: { Image(systemName:"stop.fill") }.accessibilityLabel("재생 정지") }
                        Spacer()
                        if let daily {
                            DailyNextButton(nextTitle:daily.nextTitle) { game.stop(); daily.next() }.disabled(game.working)
                        } else if let stage {
                            Button(stage.nextTitle) { game.stopReplay(); stage.next() }.buttonStyle(PrimaryButton(compact:true)).disabled(game.working)
                                .accessibilityIdentifier("drill-stage-next")
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
        ScrollView(.vertical,showsIndicators:true) {
            VStack(alignment:.leading,spacing:24) {
                Text("\(game.setCount)문제를 모두 풀었어요").font(.largeTitle.bold()).padding(.top,28)
                ForEach(0..<game.setCount,id:\.self) { i in
                    HStack { Text("\(i+1)번").font(.headline); Text("\(game.setExcerpts.indices.contains(i) ? game.setExcerpts[i].bars : 2)마디").foregroundStyle(.secondary); Spacer(); Text("\(game.setScores[i] ?? 0)%").font(.title2.bold()).foregroundStyle(SolfegeTheme.violet) }
                        .padding(20).background(.white,in:RoundedRectangle(cornerRadius:16))
                }
                HStack(spacing:16) {
                    Button("다시 \(game.setCount)문제 풀기") { game.newSet() }.buttonStyle(PrimaryButton()).disabled(game.working)
                    Button("난이도 변경하기") { game.setup(); choosingDifficulty = true }.buttonStyle(.bordered)
                }
            }
        }
    }
    private func back() {
        if stage != nil || game.page == .playing || (game.page == .result && daily == nil) || game.working {
            game.pause(); confirmingExit=true; return
        }
        leave()
    }
    private func leave() {
        if let daily { game.stop(); daily.exit(); return }
        if let stage { game.stop(); stage.exit(); return }
        if game.page == .playing || game.page == .result || game.working {
            game.setup(); choosingDifficulty = true
        } else if game.page == .summary {
            game.setup(); choosingDifficulty = false
        } else if choosingDifficulty {
            game.stop(); choosingDifficulty = false
        } else {
            game.stop(); dismiss()
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
