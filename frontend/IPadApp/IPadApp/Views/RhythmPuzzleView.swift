import SwiftUI
import AVFoundation

struct RhythmPuzzleView: View {
    @StateObject private var game: RhythmPuzzleModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @AppStorage("rhythm-puzzle-tutorial-v3") private var tutorialSeen = false
    @State private var showingTutorial = false
    @State private var frames: [Int:CGRect] = [:]
    @State private var dragId: String?
    @State private var dragPoint = CGPoint.zero
    init(connection: RhythmConnection?) { _game = StateObject(wrappedValue:RhythmPuzzleModel(connection:connection)) }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment:.topLeading) {
                ScrollView {
                    VStack(alignment:.leading,spacing:18) {
                        HStack {
                            Text("Rhythm puzzle").font(.title2.bold())
                            Spacer()
                            if game.page == .setup || (game.page == .playing && game.draft?.finished == false) {
                                Button { game.pause(); showingTutorial = true } label: { Label("게임 방법",systemImage:"questionmark.circle").frame(minHeight:44) }
                            }
                            Button(action:back) { Image(systemName:"xmark").frame(width:44,height:44) }.accessibilityLabel("뒤로가기")
                        }
                        if game.page == .setup { setup }
                        else if game.page == .summary { summary }
                        else if let round = game.round, let draft = game.draft { play(round,draft:draft,compact:geometry.size.width < 950) }
                        if game.storageFailed { Button("기기 저장 재시도") { game.retryStorage() }.buttonStyle(PrimaryButton()) }
                    }.padding(24).frame(maxWidth:1100).frame(maxWidth:.infinity)
                }
                if let id = dragId, let tile = game.tiles[id], let round = game.round {
                    RhythmTileFace(tile:tile,pulse:round.pulse).frame(width:190,height:100)
                        .shadow(color:.black.opacity(0.18),radius:14,y:10)
                        .position(x:dragPoint.x,y:dragPoint.y-36).allowsHitTesting(false)
                }
            }.coordinateSpace(name:"rhythm-puzzle")
                .onPreferenceChange(RhythmBarFrames.self) { frames = $0 }
                .background(SolfegeTheme.background.ignoresSafeArea())
        }.tint(SolfegeTheme.violet).preferredColorScheme(.light)
        .task { game.sync(); game.makeExport(); if !tutorialSeen { showingTutorial = true } }
        .sheet(isPresented:$showingTutorial,onDismiss:{ game.activate() }) {
            RhythmTutorialView { tutorialSeen = true; showingTutorial = false }
        }
        .alert("확인이 필요해요",isPresented:Binding(get:{game.error != nil},set:{if !$0 {game.error = nil}})) {
            if game.storageFailed { Button("저장 다시 시도") { game.retryStorage() } }
            Button("확인") { game.error = nil }
        } message: { Text(game.error ?? "") }
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
    private func play(_ round: RhythmRound, draft: RhythmDraft, compact: Bool) -> some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing:7) {
                ForEach(draft.setIds.indices,id:\.self) { i in Capsule().fill(i < draft.index || (i == draft.index && draft.finished) ? SolfegeTheme.violet : SolfegeTheme.violet.opacity(0.13)).frame(height:6) }
                Text("\(draft.index+1)/\(draft.setIds.count)").font(.caption.monospacedDigit()).padding(.leading,8)
            }
            HStack(alignment:.center) {
                Text("\(round.meter.numerator)/\(round.meter.denominator)").font(.system(size:34,weight:.bold,design:.rounded))
                Text(round.tempoLabel).font(.subheadline).foregroundStyle(.secondary)
                Text(game.waitingToPlay ? "잠시 후 재생" : game.playing ? "선율 재생 중" : draft.finished ? "결과 확인" : "리듬을 채우세요")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if game.waitingToPlay { ProgressView().controlSize(.small).accessibilityLabel("1초 후 재생") }
                Text("\(round.difficulty.score)/100").font(.caption.monospacedDigit()).foregroundStyle(.secondary).accessibilityLabel("리듬 난도 \(round.difficulty.score), 실험값")
            }
            RhythmPuzzleBoardView(game:game,round:round,compact:compact)
                .padding(.horizontal,14).background(.white,in:RoundedRectangle(cornerRadius:18))
            if !game.feedback.isEmpty || !game.message.isEmpty {
                Text(game.message.isEmpty ? game.feedback : game.message).font(.subheadline)
                    .foregroundStyle(draft.finished && draft.record.outcome == "correct" ? SolfegeTheme.green : SolfegeTheme.ink)
                    .frame(maxWidth:.infinity,minHeight:28,alignment:.leading)
            }
            if draft.finished && ["revealed","skipped"].contains(draft.record.outcome) {
                VStack(spacing:4) {
                    HStack { Text("정답").foregroundStyle(SolfegeTheme.green); Spacer(); Button { game.listen(reason:"reference") } label: { Image(systemName:"speaker.wave.2") }.disabled(game.playing || game.waitingToPlay).accessibilityLabel("정답 리듬 듣기") }
                    RhythmReferenceView(round:round,tiles:game.tiles,compact:compact)
                }.padding(12).background(.white,in:RoundedRectangle(cornerRadius:14))
            }
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:12),count:4),spacing:12) {
                ForEach(draft.record.choiceOrder,id:\.self) { id in
                    if let tile = game.tiles[id] {
                        RhythmTileFace(tile:tile,pulse:round.pulse)
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
            HStack(spacing:14) {
                Button { game.listen(includeCountIn:false) } label: { Label("바로 듣기",systemImage:"play.fill") }
                    .buttonStyle(.bordered).disabled(game.playing || game.waitingToPlay || draft.finished)
                Button { game.listen(includeCountIn:true) } label: { Label("예비박부터 듣기",systemImage:"metronome") }
                    .buttonStyle(.bordered).disabled(game.playing || game.waitingToPlay || draft.finished)
                Button { game.undo() } label: { Image(systemName:"arrow.uturn.backward").frame(width:28,height:28) }
                    .buttonStyle(.bordered).disabled(!game.canEdit || draft.undo.isEmpty).accessibilityLabel("되돌리기")
                Spacer()
            }
            HStack(spacing:14) {
                if !draft.finished {
                    Button("정답 보고 넘기기",systemImage:"forward.end") { game.revealAndSkip() }.buttonStyle(.bordered).disabled(!game.canEdit)
                }
                Spacer()
                Button { game.toggleTieMode() } label: { Label { Text("타이") } icon: { RhythmTieIcon(color:game.tieMode ? .blue : SolfegeTheme.violet).frame(width:28,height:28) } }
                    .buttonStyle(.bordered).tint(game.tieMode ? .blue : SolfegeTheme.violet).disabled(!game.canEdit)
                    .accessibilityValue(game.tieMode ? "연결할 두 조각을 선택" : "꺼짐")
                if draft.finished { Button(draft.index+1 == draft.setIds.count ? "결과 보기" : "다음") { game.next() }.buttonStyle(PrimaryButton()) }
                else { Button("제출") { game.submit() }.buttonStyle(PrimaryButton()).disabled(!game.canSubmit) }
            }.padding(.top,6)
        }
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
        let layout = RhythmBarLayout(round:round,bar:entry.key,board:game.board,tiles:game.tiles,drawings:RhythmInk.drawings)
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
    private func back() {
        if game.page == .playing { game.setup() }
        else { game.close(); dismiss() }
    }
}

struct RhythmTileFace: View {
    let tile: RhythmTile; let pulse: RhythmTime
    private var color: Color { tile.duration > pulse ? .blue : tile.duration < pulse ? SolfegeTheme.violet : .gray }
    var body: some View {
        ZStack(alignment:.bottomTrailing) {
            RhythmNotationView(tile:tile).frame(height:98)
            if tile.duration != pulse { Text(tile.label(pulse:pulse)).font(.system(size:10,weight:.medium)).foregroundStyle(color).padding(6) }
        }.frame(maxWidth:.infinity).background(color.opacity(tile.duration == pulse ? 0.025 : 0.065),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(color.opacity(0.17)))
    }
}
