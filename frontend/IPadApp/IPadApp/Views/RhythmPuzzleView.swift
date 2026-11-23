import SwiftUI
import AVFoundation

struct RhythmPuzzleView: View {
    @StateObject private var game: RhythmPuzzleModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.tutorialScope) private var tutorialScope
    @State private var showingTutorial = false
    @State private var frames: [Int:CGRect] = [:]
    @State private var dragId: String?
    @State private var dragPoint = CGPoint.zero
    @State private var confirmingExit = false
    @State private var confirmingReveal = false
    @State private var showingSpecialHint = false
    private let daily: DailyGameContext?
    private let stage: DrillStageContext?
    init(connection: RhythmConnection?, daily: DailyGameContext? = nil, stage: DrillStageContext? = nil, preparedGame: RhythmPuzzleModel? = nil) {
        _game = StateObject(wrappedValue:preparedGame ?? RhythmPuzzleModel(connection:connection,stageMode:true)); self.daily = daily; self.stage = stage
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment:.topLeading) {
                ScrollView {
                    VStack(alignment:.leading,spacing:18) {
                        HStack {
                            Text("Rhythm puzzle").font(.title2.bold())
                            if daily != nil { DailyChip() }
                            if let stage { StageChip(stage:stage.stage) }
                            Spacer()
                            if game.page == .setup || (game.page == .playing && game.draft?.finished == false) {
                                TutorialHelpButton(action: openTutorial)
                            }
                            Button(action:back) { Image(systemName:"xmark").frame(width:44,height:44) }.accessibilityLabel("뒤로가기")
                        }
                        if game.page == .setup { if let stage { stageStart(stage) } else { setup } }
                        else if game.page == .summary { summary }
                        else if let round = game.round, let draft = game.draft {
                            // The board sits in the middle of the space under the title, so a 4:3
                            // 12.9/13-inch screen does not leave its lower third empty.
                            Spacer(minLength:0)
                            play(round,draft:draft,compact:geometry.size.width < 950,width:min(1100,geometry.size.width)-76)
                            Spacer(minLength:0)
                        }
                        if game.storageFailed { Button("기기 저장 재시도") { game.retryStorage() }.buttonStyle(PrimaryButton()) }
                    }.padding(24).frame(maxWidth:1100).frame(maxWidth:.infinity)
                        .frame(minHeight:geometry.size.height,alignment:.top)
                }
                if let id = dragId, let tile = game.tiles[id], let round = game.round {
                    RhythmTileFace(tile:tile,pulse:round.pulse,unitWidth:100*min(1.2,(min(1100,geometry.size.width)-76)/CGFloat(100*(round.totalDuration/round.pulse).value+112))).frame(height:100)
                        .shadow(color:.black.opacity(0.18),radius:14,y:10)
                        .position(x:dragPoint.x,y:dragPoint.y-36).allowsHitTesting(false)
                }
            }.coordinateSpace(name:"rhythm-puzzle")
                .onPreferenceChange(RhythmBarFrames.self) { frames = $0 }
                .background(SolfegeTheme.background.ignoresSafeArea())
        }.tint(SolfegeTheme.violet).preferredColorScheme(.light)
        .environment(\.rhythmEngraving,game.engraving)
        .overlay { if game.contentLoading { ProgressView("문제를 준비하고 있어요").padding(24).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18)) } }
        .task {
            game.requireManualStart(); stage?.activity(false)
            await game.prepareContent(); guard !Task.isCancelled else { return }
            game.sync(); game.makeExport()
            if let stage { game.newStageRound(stage.question) } else { startDaily() }
            if stage == nil && daily == nil && !TutorialHistory.hasSeen(.rhythmPuzzle, scope: tutorialScope) { openTutorial() }
        }
        .onChange(of: game.awaitingStart) { _, ready in
            if ready && !TutorialHistory.hasSeen(.rhythmPuzzle, scope: tutorialScope) { openTutorial() }
        }
        .onChange(of: game.playing) { _, playing in
            guard !playing, !game.awaitingStart, !showingTutorial, !confirmingExit, !confirmingReveal,
                  game.draft?.finished == false, game.draft?.hasListened == true,
                  let round = game.round,
                  TutorialHistory.store(scope: tutorialScope)?.hasSeenHint(.rhythmSpecialLengths) != true else { return }
            let ids = game.draft?.record.visibleChoiceOrder ?? round.choices
            if ids.contains(where: { id in
                guard let tile = game.tiles[id] else { return false }
                return tile.duration != round.pulse || tile.symbols.contains { $0.actual != $0.normal }
            }) { showingSpecialHint = true }
        }
        .onChange(of:game.draft?.finished == true) { _, finished in if finished {
            if let daily { do { try game.commitStage(); daily.finished() } catch { game.error=error.localizedDescription } }
            let correct=game.draft?.record.outcome == "correct"
            stage?.report(DrillRoundResult(accuracy:correct ? 100 : 0,revealed:!correct,elapsedMs:0))
        } }
        .onChange(of:game.page) { _, page in if page == .summary && stage == nil { do { try game.commitStage() } catch { game.error=error.localizedDescription } } }
        .onChange(of:stage?.question.id) { _, _ in if let stage { game.newStageRound(stage.question) } }
        .allowsHitTesting(!showingTutorial)
        .overlay {
            if showingTutorial {
                TutorialWalkthrough(kind: .rhythmPuzzle) {
                    game.finishTutorial(); showingTutorial = false
                    if game.page == .setup { startDaily() }
                }
            } else if game.tutorialPaused {
                VStack(spacing: 18) {
                    Text("준비되면 이어서 해요").font(.title3.bold())
                    Button("계속하기") { stage?.activity(true); game.continueAfterTutorial() }.buttonStyle(PrimaryButton())
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.regularMaterial)
            }
        }
        .alert(confirmingExit ? "게임 종료" : confirmingReveal ? "정답을 볼까요?" : "확인이 필요해요",
               isPresented:Binding(get:{confirmingExit || confirmingReveal || game.error != nil},set:{if !$0 { confirmingExit=false; confirmingReveal=false; game.error=nil }})) {
            if confirmingExit {
                Button("계속하기",role:.cancel) { game.activate() }
                Button("종료",role:.destructive) { game.discardStage(); leave() }
            } else if confirmingReveal {
                Button("계속 풀기",role:.cancel) { game.activate() }
                Button("정답 보기",role:.destructive) { stage?.acknowledgeReveal(); game.revealAndSkip() }
            } else {
                if game.catalog == nil { Button("다시 시도") { Task { await game.prepareContent(); startDaily() } } }
                if game.storageFailed { Button("저장 다시 시도") { game.retryStorage() } }
                Button("확인") { game.error=nil }
            }
        } message: { Text(confirmingExit ? "진행 상황이 저장되지 않습니다. 정말 종료하시겠습니까?" : confirmingReveal ? "정답을 보면 이번 스테이지는 클리어할 수 없어요." : game.error ?? "") }
        .onChange(of:phase) { _, value in if value == .active { game.activate() } else { dragId = nil; game.pause() } }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.interruptionNotification).receive(on:RunLoop.main)) { _ in game.pause() }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.mediaServicesWereResetNotification).receive(on:RunLoop.main)) { _ in game.pause() }
        .onReceive(NotificationCenter.default.publisher(for:.AVAudioEngineConfigurationChange).receive(on:RunLoop.main)) { n in if game.audio.owns(n), !game.audio.running { game.pause() } }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.routeChangeNotification).receive(on:RunLoop.main)) { n in
            if let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, AVAudioSession.RouteChangeReason(rawValue:raw) == .oldDeviceUnavailable { game.pause() }
        }
        .onDisappear { game.close() }
    }
    private var setup: some View {
        VStack(alignment:.leading,spacing:24) {
            Text("두 마디를 듣고 리듬을 완성하세요.").font(.title3)
            Picker("난이도",selection:$game.level) {
                Text("초급").tag("beginner"); Text("중급").tag("intermediate"); Text("고급").tag("advanced")
            }.pickerStyle(.segmented)
            VStack(alignment:.leading,spacing:12) {
                Text(game.level == "beginner" ? "기본 리듬부터 차근차근" : game.level == "intermediate" ? "엇박과 붙임줄에 익숙해지기" : "복잡한 리듬에 도전하기").font(.title3.bold())
                Text("2마디").foregroundStyle(.secondary)
            }.padding(22).frame(maxWidth:.infinity,alignment:.leading).background(.white,in:RoundedRectangle(cornerRadius:18))
            HStack(spacing:14) {
                if game.canResume { Button("이어서 풀기") { game.resume() }.buttonStyle(PrimaryButton()) }
                Button("5문제 시작") { game.newSet() }.buttonStyle(PrimaryButton()).disabled(game.catalog == nil || game.connection == nil || game.storageFailed)
            }
        }.padding(.vertical,32)
    }
    private func play(_ round: RhythmRound, draft: RhythmDraft, compact: Bool, width: CGFloat) -> some View {
        VStack(alignment:.leading,spacing:14) {
            if let stage { DrillSetProgress(results:stage.results,index:stage.index) }
            else if let daily { DailyProgressBar(done:daily.done,current:daily.index) } else { HStack(spacing:7) {
                ForEach(draft.setIds.indices,id:\.self) { i in Capsule().fill(i < draft.index || (i == draft.index && draft.finished) ? SolfegeTheme.violet : SolfegeTheme.violet.opacity(0.13)).frame(height:6) }
                Text("\(draft.index+1)/\(draft.setIds.count)").font(.caption.monospacedDigit()).padding(.leading,8)
            } }
            HStack(alignment:.center) {
                Text("\(round.meter.numerator)/\(round.meter.denominator)").font(.system(size:34,weight:.bold,design:.rounded))
                Text(round.tempoLabel).font(.subheadline).foregroundStyle(.secondary)
                Text(game.awaitingStart ? "시작을 눌러주세요" : game.waitingToPlay ? "잠시 후 재생" : game.playing ? "선율 재생 중" : draft.finished ? "결과 확인" : "리듬을 채우세요")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if game.waitingToPlay { ProgressView().controlSize(.small).accessibilityLabel("1초 후 재생") }
                Text("\(round.difficulty.score)/100").font(.caption.monospacedDigit()).foregroundStyle(.secondary).accessibilityLabel("리듬 난도 \(round.difficulty.score), 실험값")
            }
            RhythmPuzzleBoardView(game:game,round:round,compact:compact)
                .padding(.horizontal,14).background(.white,in:RoundedRectangle(cornerRadius:18))
            Text(game.message.isEmpty ? game.feedback : game.message).font(.subheadline)
                .foregroundStyle(draft.finished && draft.record.outcome == "correct" ? SolfegeTheme.green : SolfegeTheme.ink)
                .frame(maxWidth:.infinity,minHeight:28,alignment:.leading)
            if draft.finished && ["revealed","skipped"].contains(draft.record.outcome) {
                VStack(spacing:4) {
                    HStack { Text("정답").foregroundStyle(SolfegeTheme.green); Spacer(); Button { game.listen(reason:"reference",includeCountIn:false) } label: { Image(systemName:"speaker.wave.2") }.disabled(game.playing || game.waitingToPlay).accessibilityLabel("원본 선율 듣기") }
                    RhythmReferenceView(round:round,tiles:game.tiles,compact:compact)
                }.padding(12).background(.white,in:RoundedRectangle(cornerRadius:14))
            }
            RhythmChoiceFlow {
                ForEach(draft.record.visibleChoiceOrder ?? draft.record.choiceOrder,id:\.self) { id in
                    if let tile = game.tiles[id] {
                        RhythmTileFace(tile:tile,pulse:round.pulse,unitWidth:100*min(1.2,width/CGFloat(100*(round.totalDuration/round.pulse).value+112)))
                            .opacity(dragId == id ? 0.3 : 1).contentShape(RoundedRectangle(cornerRadius:12))
                            .overlay {
                                GeometryReader { proxy in
                                    let frame = proxy.frame(in:.named("rhythm-puzzle"))
                                    MiniGameTouchSurface(moved:{ start,point in
                                        if hypot(point.x-start.x,point.y-start.y) > 10 {
                                            dragId = id; dragPoint = CGPoint(x:frame.minX+point.x,y:frame.minY+point.y)
                                        }
                                    },ended:{ _,point,tap in
                                        defer { dragId = nil }
                                        guard game.canEdit else { return }
                                        if tap { game.place(id) }
                                        else { drop(id,at:CGPoint(x:frame.minX+point.x,y:frame.minY+point.y)) }
                                    },cancelled:{ dragId = nil }).accessibilityHidden(true)
                                }
                            }
                            .accessibilityAddTraits(.isButton).accessibilityLabel("리듬 조각, \(tile.label(pulse:round.pulse))")
                            .accessibilityAction { game.place(id) }
                    }
                }
            }.allowsHitTesting(game.canEdit).opacity(draft.finished ? 0.5 : 1)
                .popover(isPresented: $showingSpecialHint) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("조각의 길이를 확인해보세요").font(.headline)
                        Text("색이 있는 조각은 한 박보다 길거나 짧아요.\n남은 반 박은 작은 점선 칸으로 표시돼요.\n셋잇단음표는 한 조각으로 넣을 수 있어요.")
                            .font(.subheadline).lineSpacing(5)
                        Button("알겠어요") { showingSpecialHint = false }.buttonStyle(PrimaryButton(compact: true))
                    }.padding(24).frame(maxWidth: 360).presentationCompactAdaptation(.popover)
                }
                .onChange(of: showingSpecialHint) { _, shown in
                    if !shown { try? TutorialHistory.store(scope: tutorialScope)?.markHintSeen(.rhythmSpecialLengths) }
                }
            HStack(spacing:14) {
                Button { game.listen(includeCountIn:false) } label: { RhythmReplayIcon().frame(width:32,height:32) }
                    .buttonStyle(.bordered).disabled(game.awaitingStart || game.playing || game.waitingToPlay || draft.finished).accessibilityLabel("바로 다시 듣기").help("바로 다시 듣기")
                Button { game.listen(includeCountIn:true) } label: { RhythmReplayIcon(withMetronome:true).frame(width:32,height:32) }
                    .buttonStyle(.bordered).disabled(game.awaitingStart || game.playing || game.waitingToPlay || draft.finished).accessibilityLabel("예비박부터 다시 듣기").help("예비박부터 다시 듣기")
                Button { game.undo() } label: { Image(systemName:"arrow.uturn.backward").frame(width:28,height:28) }
                    .buttonStyle(.bordered).disabled(!game.canEdit || draft.undo.isEmpty).accessibilityLabel("되돌리기")
                Spacer(minLength:24)
                if !draft.finished {
                    Button {
                        if let stage, !stage.revealAcknowledged { game.pause(); confirmingReveal=true }
                        else { game.revealAndSkip() }
                    } label: { Image(systemName:"eye").frame(width:32,height:32) }
                        .buttonStyle(.bordered).tint(.orange).disabled(!game.canEdit).accessibilityLabel("정답 보고 넘기기").help("정답 보고 넘기기")
                }
                Spacer()
                Button { game.toggleTieMode() } label: { RhythmTieIcon(color:game.tieMode ? .blue : SolfegeTheme.violet).frame(width:32,height:32) }
                    .buttonStyle(.bordered).tint(game.tieMode ? .blue : SolfegeTheme.violet).disabled(!game.canEdit)
                    .accessibilityLabel("타이 연결").help("타이 연결")
                    .accessibilityValue(game.tieMode ? "연결할 두 조각을 선택" : "꺼짐")
                if game.awaitingStart {
                    Button("시작") { stage?.activity(true); game.startPreparedRound() }.buttonStyle(PrimaryButton()).frame(width: 150)
                        .accessibilityIdentifier("rhythm-start")
                } else if draft.finished, let daily { DailyNextButton(nextTitle:daily.nextTitle) { game.close(); daily.next() } }
                else if draft.finished, let stage {
                    Button(stage.nextTitle,action:stage.next).buttonStyle(PrimaryButton()).frame(width:150).accessibilityIdentifier("drill-stage-next")
                }
                else if draft.finished { Button(draft.index+1 == draft.setIds.count ? "결과 보기" : "다음") { game.next() }.buttonStyle(PrimaryButton()) }
                else { Button("제출") { game.submit() }.buttonStyle(PrimaryButton()).frame(width:150).disabled(!game.canSubmit) }
            }.padding(.top,6)
        }
    }
    private func openTutorial() {
        dragId = nil; stage?.activity(false); game.suspendForTutorial(); showingTutorial = true
    }
    private func drop(_ id: String, at location: CGPoint) {
        guard let round = game.round else { return }
        let candidates = frames.filter { $0.value.insetBy(dx:-12,dy:-12).contains(location) }
        let entry = candidates.min { a,b in
            let insideA = a.value.contains(location), insideB = b.value.contains(location)
            if insideA != insideB { return insideA }
            let distanceA = abs(a.value.midY-location.y), distanceB = abs(b.value.midY-location.y)
            return distanceA == distanceB ? a.key < b.key : distanceA < distanceB
        }
        guard let entry else { game.message = "위 악보의 점선 빈칸에 놓아 주세요."; return }
        let layout = RhythmBarLayout(round:round,bar:entry.key,board:game.board,tiles:game.tiles,drawings:game.engraving?.tiles ?? RhythmInk.drawings)
        let scale = Double(entry.value.width)/layout.width
        let x = Double(location.x-entry.value.minX)/scale
        game.place(id,at:layout.nearestTime(to:x,tiles:game.tiles))
    }
    private var summary: some View {
        VStack(alignment:.leading,spacing:24) {
            Text("연습 완료").font(.largeTitle.bold())
            HStack(spacing:16) {
                Button("다시 \(game.setCount)문제 풀기") { game.newSet() }.buttonStyle(PrimaryButton())
                Button("난이도 변경하기") { game.setup() }.buttonStyle(.bordered)
            }
        }.padding(.vertical,32)
    }
    // Daily Training and a Drill stage skip setup and open one round at their difficulty.
    private func startDaily() {
        guard game.page == .setup else { return }
        if let daily { game.newDailyRound(difficulty:daily.difficulty) }
        else if let stage { game.newStageRound(stage.question) }
    }
    // Shown only if the stage's round could not start (content or storage failed).
    private func stageStart(_ stage: DrillStageContext) -> some View {
        VStack(spacing:18) {
            Text("\(stage.stage.name) · Rhythm puzzle").font(.title2.bold())
            Text(stage.stage.difficulty.title).foregroundStyle(.secondary)
            Button("시작하기") { startDaily() }.buttonStyle(PrimaryButton())
                .disabled(game.catalog == nil || game.connection == nil || game.storageFailed || showingTutorial)
        }.frame(maxWidth:.infinity).padding(.vertical,80)
    }
    private func back() {
        if stage != nil || (game.page == .playing && !(daily != nil && game.draft?.finished == true)) { game.pause(); confirmingExit=true; return }
        leave()
    }
    private func leave() {
        if let daily { game.close(); daily.exit(); return }
        if let stage { game.close(); stage.exit(); return }
        if game.page == .playing { game.setup() }
        else { game.close(); dismiss() }
    }
}

struct RhythmReplayIcon: View {
    var withMetronome = false
    var body: some View {
        ZStack {
            Image(systemName:"arrow.counterclockwise").font(.system(size:27,weight:.medium))
            if withMetronome { Image(systemName:"metronome").font(.system(size:11,weight:.semibold)).offset(x:1,y:3) }
        }.accessibilityHidden(true)
    }
}

struct RhythmTileFace: View {
    let tile: RhythmTile; let pulse: RhythmTime
    var unitWidth: CGFloat? = nil
    private var color: Color { tile.duration > pulse ? .blue : tile.duration < pulse ? SolfegeTheme.violet : .gray }
    var body: some View {
        ZStack(alignment:.bottomTrailing) {
            RhythmNotationView(tile:tile).frame(height:98)
            if tile.duration != pulse { Text(tile.label(pulse:pulse)).font(.system(size:10,weight:.medium)).foregroundStyle(color).padding(6) }
        }.frame(width:unitWidth.map { $0*CGFloat((tile.duration/pulse).value) })
            .frame(maxWidth:unitWidth == nil ? .infinity : nil)
            .background(color.opacity(tile.duration == pulse ? 0.025 : 0.065),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(color.opacity(0.17)))
    }
}

struct RhythmChoiceFlow: Layout {
    private func positions(_ subviews: Subviews,width: CGFloat) -> ([CGPoint],CGFloat) {
        var points: [CGPoint]=[], x: CGFloat=0, y: CGFloat=0, row: CGFloat=0
        for view in subviews {
            let size=view.sizeThatFits(.unspecified)
            if x>0 && x+size.width>width { x=0; y+=row+12; row=0 }
            points.append(CGPoint(x:x,y:y)); x+=size.width+12; row=max(row,size.height)
        }
        return (points,y+row)
    }
    func sizeThatFits(proposal: ProposedViewSize,subviews: Subviews,cache: inout ()) -> CGSize {
        let width=proposal.width ?? 1000
        return CGSize(width:width,height:positions(subviews,width:width).1)
    }
    func placeSubviews(in bounds: CGRect,proposal: ProposedViewSize,subviews: Subviews,cache: inout ()) {
        let points=positions(subviews,width:bounds.width).0
        for (index,view) in subviews.enumerated() {
            view.place(at:CGPoint(x:bounds.minX+points[index].x,y:bounds.minY+points[index].y),anchor:.topLeading,proposal:.unspecified)
        }
    }
}
