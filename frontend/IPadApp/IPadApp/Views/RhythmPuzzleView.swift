import SwiftUI
import AVFoundation

struct RhythmPuzzleView: View {
    @StateObject private var game: RhythmPuzzleModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    init(connection: RhythmConnection?) { _game = StateObject(wrappedValue:RhythmPuzzleModel(connection:connection)) }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    HStack {
                        Label("리듬 퍼즐",systemImage:"square.grid.3x3.fill").font(.title2.bold())
                        Spacer()
                        Button { game.close(); dismiss() } label: { Image(systemName:"xmark").frame(width:44,height:44) }.accessibilityLabel("리듬 게임 닫기")
                    }
                    if game.page == .setup { setup }
                    else if game.page == .summary { summary }
                    else if let round = game.round, let draft = game.draft { play(round,draft:draft,compact:geometry.size.width < 950) }
                    if game.storageFailed { Button("기기 저장 재시도") { game.retryStorage() }.buttonStyle(PrimaryButton()) }
                }.padding(24).frame(maxWidth:1280).frame(maxWidth:.infinity)
            }.background(SORITheme.background.ignoresSafeArea())
        }
        .tint(SORITheme.violet).preferredColorScheme(.light)
        .task { game.sync(); game.makeExport() }
        .alert("확인이 필요해요",isPresented:Binding(get:{game.error != nil},set:{if !$0 {game.error = nil}})) { Button("확인") { game.error = nil } } message: { Text(game.error ?? "") }
        .onChange(of:phase) { _, value in if value == .active { game.activate() } else { game.pause() } }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.interruptionNotification).receive(on:RunLoop.main)) { _ in game.pause() }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.mediaServicesWereResetNotification).receive(on:RunLoop.main)) { _ in game.pause() }
        .onReceive(NotificationCenter.default.publisher(for:.AVAudioEngineConfigurationChange).receive(on:RunLoop.main)) { n in if game.audio.owns(n), !game.audio.running { game.pause() } }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.routeChangeNotification).receive(on:RunLoop.main)) { n in
            if let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, AVAudioSession.RouteChangeReason(rawValue:raw) == .oldDeviceUnavailable { game.pause() }
        }
        .onDisappear { game.close() }
    }
    private var setup: some View {
        VStack(alignment:.leading,spacing:22) {
            SectionCaption(eyebrow:"LISTEN · PIECE · CONNECT",title:"들은 리듬을 조각으로 완성해요",subtitle:"실제 청음 문제의 두 마디를 듣고, 음높이 대신 리듬에 집중하세요.")
            Card {
                VStack(alignment:.leading,spacing:14) {
                    Label("예비박 한 마디 → 선율 두 마디",systemImage:"ear").font(.headline)
                    Text("조각을 탭하면 첫 빈칸에 들어가요. 원하는 위치로 끌어 놓을 수도 있어요. 긴 음은 여러 박을 차지하고, 필요한 음끼리는 타이로 연결해요.")
                    Text("첫 오답은 정오만, 두 번째에는 힌트, 세 번째에는 정답을 보여드려요.").foregroundStyle(.secondary)
                    HStack { Pill(text:"5문제 한 세트"); Pill(text:"\(game.catalog?.rounds.count ?? 0)개 구간"); Pill(text:"중급·고급 청음") }
                }
            }
            Picker("문제 풀",selection:$game.level) { Text("중급 + 고급").tag("mixed"); Text("중급").tag("intermediate"); Text("고급").tag("advanced") }.pickerStyle(.segmented)
            HStack(spacing:14) {
                if game.canResume { Button("이어서 풀기") { game.resume() }.buttonStyle(PrimaryButton()) }
                Button("새 5문제 시작") { game.newSet() }.buttonStyle(PrimaryButton()).disabled(game.catalog == nil || game.connection == nil || game.storageFailed)
            }
            if !game.message.isEmpty { Text(game.message).font(.footnote).foregroundStyle(.secondary) }
            storage
        }
    }
    private func play(_ round: RhythmRound, draft: RhythmDraft, compact: Bool) -> some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing:7) {
                ForEach(draft.setIds.indices,id:\.self) { i in Capsule().fill(i < draft.index || (i == draft.index && draft.finished) ? SORITheme.violet : SORITheme.violet.opacity(0.13)).frame(height:7) }
                Text("\(draft.index+1) / \(draft.setIds.count)").font(.caption.monospacedDigit()).padding(.leading,8)
            }.accessibilityLabel("\(draft.setIds.count)문제 중 \(draft.index+1)번째")
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:3) {
                    Text("\(round.meter.numerator)/\(round.meter.denominator) · \(round.tempoLabel)").font(.title3.bold())
                    Text("\(round.title) · 원곡 \(round.firstMeasure)–\(round.firstMeasure+1)마디").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment:.trailing,spacing:3) {
                    Text("리듬 난도 \(round.difficulty.score)/100").font(.headline)
                    Text("같은 박자 문제군 기준 · 실험값").font(.caption2).foregroundStyle(.secondary)
                }
            }
            RhythmPuzzleBoardView(game:game,round:round,compact:compact)
                .padding(.horizontal,8).padding(.vertical,10).background(.white,in:RoundedRectangle(cornerRadius:18))
            HStack(spacing:12) {
                Button { game.listen() } label: { Label(game.playing ? "재생 중" : "다시 듣기",systemImage:game.playing ? "speaker.wave.2.fill" : "arrow.counterclockwise") }
                    .disabled(game.playing || draft.finished).buttonStyle(.bordered)
                Button { game.tieMode.toggle() } label: { Label("타이 \(game.tieMode ? "켜짐" : "연결")",systemImage:"link") }
                    .buttonStyle(.bordered).tint(game.tieMode ? .blue : SORITheme.violet).disabled(!game.canEdit)
                Button { game.undo() } label: { Label("되돌리기",systemImage:"arrow.uturn.backward") }.buttonStyle(.bordered).disabled(!game.canEdit || draft.undo.isEmpty)
                Spacer()
                if draft.finished { Button(draft.index+1 == draft.setIds.count ? "세트 완료" : "다음 문제") { game.next() }.buttonStyle(PrimaryButton()) }
                else { Button("제출") { game.submit() }.buttonStyle(PrimaryButton()).disabled(!game.canSubmit) }
            }
            VStack(alignment:.leading,spacing:4) {
                Text(game.feedback).font(.subheadline.weight(.medium))
                    .foregroundStyle(draft.finished && draft.record.outcome == "correct" ? SORITheme.green : SORITheme.ink)
                if !game.message.isEmpty { Text(game.message).font(.caption).foregroundStyle(.secondary) }
                if game.tieMode { Text("다음 조각의 첫 음을 바로 앞 음과 연결해요. 타이 버튼을 다시 누르면 취소돼요.").font(.caption).foregroundStyle(.blue) }
            }.frame(maxWidth:.infinity,alignment:.leading).padding(12).background(draft.finished && draft.record.outcome == "correct" ? SORITheme.green.opacity(0.08) : SORITheme.soft,in:RoundedRectangle(cornerRadius:12))
            if draft.finished && draft.record.outcome == "revealed" {
                VStack(alignment:.leading,spacing:8) {
                    HStack { Label("정답 리듬",systemImage:"checkmark.circle").foregroundStyle(SORITheme.green); Spacer(); Button("정답 리듬 듣기") { game.listen(reason:"reference") }.disabled(game.playing) }
                    RhythmReferenceView(round:round,tiles:game.tiles)
                }.padding(14).background(.white,in:RoundedRectangle(cornerRadius:14))
            }
            HStack { Text("조각 선택").font(.headline); Spacer(); Text("파랑: 1박 초과 · 보라: 1박 미만 · 조각은 여러 번 사용 가능").font(.caption).foregroundStyle(.secondary) }
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:12),count:4),spacing:12) {
                ForEach(draft.record.choiceOrder,id:\.self) { id in
                    if let tile = game.tiles[id] {
                        Button { game.place(id) } label: { RhythmTileFace(tile:tile,pulse:round.pulse) }
                            .buttonStyle(RhythmLiftStyle()).draggable(id) { RhythmTileFace(tile:tile,pulse:round.pulse).frame(width:240).shadow(radius:12,y:8) }
                            .accessibilityLabel("리듬 조각, \(tile.label(pulse:round.pulse)), 음표 또는 쉼표 \(tile.symbols.count)개")
                    }
                }
            }.allowsHitTesting(game.canEdit).opacity(draft.finished ? 0.55 : 1)
            Text("채운 조각을 탭하면 삭제돼요. 두 조각 사이의 연결 버튼을 누르거나 곡선으로 이으면 타이가 생겨요.").font(.caption).foregroundStyle(.secondary)
            storage
        }
    }
    private var summary: some View {
        VStack(alignment:.leading,spacing:22) {
            SectionCaption(eyebrow:"PRACTICE COMPLETE",title:"다섯 문제를 마쳤어요",subtitle:"정답 여부뿐 아니라 다시 들은 횟수와 힌트를 사용한 과정도 기록했어요.")
            Card {
                VStack(alignment:.leading,spacing:12) {
                    Text("기록은 난이도를 검토하는 단서로 사용해요.").font(.headline)
                    Text("반복해서 익숙해진 문제와 처음 푼 문제를 구분해 보관해요. 아직 개인의 약점이나 검증된 난이도 점수로 단정하지 않아요.").foregroundStyle(.secondary)
                    if let url = game.exportURL { ShareLink(item:url) { Label("플레이 기록 CSV 내보내기",systemImage:"square.and.arrow.up") } }
                }
            }
            Button("새 세트 준비") { game.page = .setup }.buttonStyle(PrimaryButton())
            storage
        }
    }
    private var storage: some View {
        HStack {
            Text(game.connection?.demo == true ? "데모 · 기기에 기록 보관" : game.syncMessage.isEmpty ? "기기에 기록 보관" : game.syncMessage).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if game.connection?.demo == false && game.pending > 0 { Button("서버 저장 재시도 (\(game.pending))") { game.sync() }.font(.caption).disabled(game.syncing) }
            if game.page == .setup, let url = game.exportURL { ShareLink(item:url) { Image(systemName:"square.and.arrow.up") }.accessibilityLabel("기록 CSV 내보내기") }
        }
    }
}

struct RhythmLiftStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.98 : 1).offset(y:configuration.isPressed ? 2 : 0)
            .shadow(color:.black.opacity(configuration.isPressed ? 0.03 : 0.09),radius:2,x:0,y:configuration.isPressed ? 1 : 4)
    }
}
struct RhythmTileFace: View {
    let tile: RhythmTile; let pulse: RhythmTime
    private var color: Color { tile.duration > pulse ? .blue : tile.duration < pulse ? SORITheme.violet : .gray }
    var body: some View {
        VStack(spacing:0) {
            RhythmNotationView(symbols:tile.symbols,duration:tile.duration).frame(height:86)
            Text(tile.label(pulse:pulse)).font(.caption2.monospacedDigit()).foregroundStyle(color).padding(.bottom,6)
        }.frame(maxWidth:.infinity).background(color.opacity(tile.duration == pulse ? 0.04 : 0.09),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(color.opacity(0.2)))
    }
}

struct RhythmPuzzleBoardView: View {
    @ObservedObject var game: RhythmPuzzleModel
    let round: RhythmRound; var compact = false
    var body: some View {
        VStack(spacing:4) {
            if compact { bar(0); between; bar(1) }
            else { HStack(spacing:6) { bar(0); between.frame(width:44); bar(1) } }
        }
    }
    @ViewBuilder private var between: some View {
        if game.board.validBoundaries(tiles:game.tiles).contains(round.measureDuration) {
            Button { game.toggleTie(round.measureDuration) } label: {
                Label(game.board.ties.contains(round.measureDuration) ? "마디 연결됨" : "마디 사이 타이",systemImage:"link")
                    .labelStyle(.iconOnly).frame(width:44,height:44).background(game.board.ties.contains(round.measureDuration) ? Color.blue.opacity(0.16) : Color.gray.opacity(0.06),in:Circle())
            }.disabled(!game.canEdit).accessibilityLabel("마디 사이 타이 \(game.board.ties.contains(round.measureDuration) ? "삭제" : "연결")")
        } else { Color.clear.frame(width:compact ? 1 : 44,height:compact ? 1 : 44) }
    }
    private func bar(_ number: Int) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width, beginning = round.measureDuration*number
            let placements = game.board.placements.filter { beginning <= $0.start && $0.start < beginning+round.measureDuration }
            ZStack(alignment:.topLeading) {
                HStack(spacing:0) {
                    ForEach(0..<round.pulsesPerMeasure,id:\.self) { beat in
                        VStack { Text("\(beat+1)").font(.caption2).foregroundStyle(.secondary); Rectangle().fill(.gray.opacity(0.16)).frame(width:1); Spacer(minLength:0) }
                            .frame(maxWidth:.infinity).background(beat % 2 == 0 ? Color.gray.opacity(0.025) : .clear)
                    }
                }
                Rectangle().fill(.black.opacity(0.22)).frame(height:1).offset(y:61)
                ForEach(placements) { p in
                    if let tile = game.tiles[p.tileId] {
                        let x = CGFloat(((p.start-beginning)/round.measureDuration).value)*width
                        let w = CGFloat((tile.duration/round.measureDuration).value)*width
                        let hinted = game.hintPositions.contains { p.start <= $0 && $0 < p.start+tile.duration }
                        Button { game.remove(p) } label: {
                            RhythmNotationView(symbols:tile.symbols,duration:tile.duration)
                                .frame(width:max(1,w-3),height:92).background(hinted ? Color.red.opacity(0.07) : tile.duration > round.pulse ? Color.blue.opacity(0.06) : tile.duration < round.pulse ? SORITheme.violet.opacity(0.06) : Color.clear,in:RoundedRectangle(cornerRadius:8))
                                .overlay(RoundedRectangle(cornerRadius:8).stroke(hinted ? .red.opacity(0.4) : .gray.opacity(0.15)))
                        }.buttonStyle(.plain).offset(x:x,y:12).disabled(!game.canEdit).accessibilityLabel("\(number+1)마디 리듬 조각 삭제")
                    }
                }
                ForEach(game.board.validBoundaries(tiles:game.tiles).filter { beginning < $0 && $0 < beginning+round.measureDuration },id:\.self) { t in
                    let x = CGFloat(((t-beginning)/round.measureDuration).value)*width
                    Button { game.toggleTie(t) } label: {
                        Image(systemName:"link.badge.plus").font(.system(size:15)).opacity(game.board.ties.contains(t) ? 0 : 1).frame(width:44,height:44)
                            .background(.white.opacity(0.92),in:Capsule()).foregroundStyle(game.board.ties.contains(t) ? .blue : .gray)
                    }.offset(x:x-22,y:72).disabled(!game.canEdit)
                        .accessibilityLabel("\(number+1)마디 타이 \(game.board.ties.contains(t) ? "삭제" : "연결")")
                }
                // Curved ties between pieces are visible independently from their generous hit areas.
                Canvas { context,size in
                    for t in game.board.ties where beginning < t && t < beginning+round.measureDuration {
                        let x = CGFloat(((t-beginning)/round.measureDuration).value)*size.width
                        var path = Path(); path.move(to:CGPoint(x:x-18,y:82)); path.addQuadCurve(to:CGPoint(x:x+18,y:82),control:CGPoint(x:x,y:104))
                        context.stroke(path,with:.color(.blue),lineWidth:2)
                    }
                }.allowsHitTesting(false)
            }.contentShape(Rectangle())
                .dropDestination(for:String.self) { items,location in
                    guard game.canEdit, let id = items.first else { return false }
                    let anchors = dropAnchors(beginning:beginning)
                    let fraction = max(0,min(1,location.x/width))
                    let target = anchors.min { abs((($0-beginning)/round.measureDuration).value-Double(fraction)) < abs((($1-beginning)/round.measureDuration).value-Double(fraction)) } ?? beginning
                    let previous = game.board; game.place(id,at:target); return previous != game.board
                }
                .simultaneousGesture(DragGesture(minimumDistance:18).onEnded { value in
                    guard game.canEdit, value.startLocation.y > 40, value.location.y > 40 else { return }
                    let a = min(value.startLocation.x,value.location.x), b = max(value.startLocation.x,value.location.x)
                    let boundaries = game.board.validBoundaries(tiles:game.tiles).filter { t in
                        let x = CGFloat(((t-beginning)/round.measureDuration).value)*width
                        return beginning < t && t < beginning+round.measureDuration && a < x && x < b
                    }
                    if boundaries.count == 1 { game.toggleTie(boundaries[0]) }
                })
        }.frame(height:130)
    }
    private func dropAnchors(beginning: RhythmTime) -> [RhythmTime] {
        var times = Set<RhythmTime>()
        for i in 0..<round.pulsesPerMeasure {
            for divisor in [1,2,3,4] {
                for part in 0..<divisor { times.insert(beginning+round.pulse*i+(round.pulse/RhythmTime(divisor))*part) }
            }
        }
        for p in game.board.placements {
            let end = game.board.end(p,tiles:game.tiles)
            if beginning <= end && end < beginning+round.measureDuration { times.insert(end) }
            if beginning <= p.start && p.start < beginning+round.measureDuration { times.insert(p.start) }
        }
        return times.sorted()
    }
}

struct RhythmReferenceView: View {
    let round: RhythmRound; let tiles: [String:RhythmTile]
    var body: some View {
        VStack(spacing:8) {
            ForEach(0..<2,id:\.self) { bar in
                let beginning = round.measureDuration*bar
                let placements = round.solution.filter { beginning <= $0.start && $0.start < beginning+round.measureDuration }
                var groupBase = 0
                let symbols = placements.flatMap { p -> [RhythmSymbol] in
                    var n = tiles[p.tileId]?.symbols ?? []
                    let largest = n.map(\.group).max() ?? 0
                    for i in n.indices where n[i].group > 0 { n[i].group += groupBase }
                    groupBase += largest
                    if !n.isEmpty, let tile = tiles[p.tileId], round.solutionTies.contains(p.start+tile.duration) { n[n.count-1].tieNext = true }
                    return n
                }
                HStack { Text("\(bar+1)").font(.caption).foregroundStyle(.secondary); RhythmNotationView(symbols:symbols,duration:round.measureDuration).frame(height:90) }
            }
            if round.solutionTies.contains(round.measureDuration) { Text("1마디 마지막 음과 2마디 첫 음은 타이로 이어져요.").font(.caption).foregroundStyle(.blue) }
        }
    }
}
