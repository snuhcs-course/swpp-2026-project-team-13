import SwiftUI
import AVFoundation

@MainActor struct EchoDragonView: View {
    @StateObject private var game: EchoDragonModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var help = false

    init(model: EchoDragonModel? = nil) {
        _game = StateObject(wrappedValue:model ?? EchoDragonModel())
    }

    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:14) {
                if game.challenge != nil {
                    Button { game.map() } label: { Label("레벨맵",systemImage:"chevron.left") }
                }
                Text("에코 드래곤").font(.title2.bold()).foregroundStyle(SolfegeTheme.ink)
                Spacer()
                if game.preview { Pill(text:"미리 체험 · 진행 저장 없음",icon:"eye") }
                Button { game.pause(); help = true } label: {
                    Image(systemName:"questionmark.circle").frame(width:44,height:44)
                }.accessibilityLabel("게임 방법")
                Button { game.stop(); dismiss() } label: {
                    Image(systemName:"xmark").frame(width:44,height:44)
                }.accessibilityLabel("게임 닫기")
            }.padding(.horizontal,24).padding(.vertical,8)
            ScrollView {
                if let challenge = game.challenge { play(challenge) }
                else { levelMap }
            }
        }
        .background(SolfegeTheme.background.ignoresSafeArea()).tint(SolfegeTheme.violet)
        .sheet(isPresented:$help) { instructions }
        .alert("확인이 필요해요",isPresented:Binding(get:{game.error != nil},set:{if !$0 { game.error = nil }})) {
            Button("확인") { game.error = nil }
        } message: { Text(game.error ?? "") }
        .onChange(of:scenePhase) { _, phase in if phase != .active { game.pause() } }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.interruptionNotification).receive(on:RunLoop.main)) { _ in game.pause() }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.mediaServicesWereResetNotification).receive(on:RunLoop.main)) { _ in game.pause() }
        .onReceive(NotificationCenter.default.publisher(for:.AVAudioEngineConfigurationChange).receive(on:RunLoop.main)) { note in
            if game.audio.needsRecovery(note) { game.pause() }
        }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.routeChangeNotification).receive(on:RunLoop.main)) { note in
            if let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               AVAudioSession.RouteChangeReason(rawValue:raw) == .oldDeviceUnavailable { game.pause() }
        }
        .onDisappear { game.stop() }
    }

    private var levelMap: some View {
        VStack(alignment:.leading,spacing:24) {
            HStack(spacing:24) {
                EchoDragonMascot(happy:false,singing:false).frame(width:160,height:145)
                VStack(alignment:.leading,spacing:10) {
                    Text("작은 인사부터,\n옥타브만큼 큰 인사까지.")
                        .font(.system(size:30,weight:.bold,design:.rounded)).foregroundStyle(SolfegeTheme.ink)
                    Text("두 음의 간격을 듣고 피아노로 답해요. 한 판씩 나아가면 새로운 소리가 열려요.")
                        .foregroundStyle(SolfegeTheme.muted)
                    HStack { Pill(text:"\(game.progress.completed) / 72판 완료",icon:"flag"); Pill(text:"\(game.progress.totalStars)개",icon:"star.fill") }
                }
                Spacer(minLength:0)
            }
            HStack(spacing:14) {
                Button { game.open(game.progress.unlocked) } label: {
                    Label("\(game.progress.unlocked)판에서 시작",systemImage:"play.fill")
                }.buttonStyle(PrimaryButton()).accessibilityIdentifier("echo-continue")
                Button("거울 대답 미리 체험") { game.open(25,preview:true) }
                    .buttonStyle(.bordered).accessibilityIdentifier("echo-preview-mirror")
                Button("옥타브 미리 체험") { game.open(67,preview:true) }.buttonStyle(.bordered)
            }
            Text("반음 → 온음 → 3도 → 4도 … 25판에서는 호수 속 친구와 거울 대답을 해요.")
                .font(.subheadline).foregroundStyle(SolfegeTheme.muted)
            LazyVGrid(columns:[GridItem(.adaptive(minimum:100),spacing:14)],spacing:14) {
                ForEach(1...EchoDragonLevel.count,id:\.self) { number in levelButton(number) }
            }.accessibilityIdentifier("echo-level-map")
            Text("진행과 별은 이 기기에 저장돼요. 다시 듣기는 자유롭고, 제한시간은 없어요.")
                .font(.footnote).foregroundStyle(SolfegeTheme.muted)
        }.padding(24).frame(maxWidth:1100).frame(maxWidth:.infinity)
    }

    private func levelButton(_ number: Int) -> some View {
        let level = EchoDragonLevel(number:number)
        let unlocked = number <= game.progress.unlocked
        let stars = game.progress.stars[number] ?? 0
        return Button { game.open(number) } label: {
            VStack(spacing:8) {
                HStack {
                    Text("\(number)").font(.title2.bold())
                    Spacer(minLength:2)
                    Image(systemName:!unlocked ? "lock.fill" : number == 25 ? "water.waves" : level.introducedInterval != nil ? "sparkles" : level.rule == .mirror ? "arrow.up.arrow.down" : "music.note")
                        .font(.caption)
                }
                Text(number == 25 ? "거울 대답" : level.introducedInterval?.name ?? (level.rule == .mirror ? "거울 인사" : "따라 하기"))
                    .font(.caption).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth:.infinity,alignment:.leading)
                HStack(spacing:3) {
                    ForEach(0..<3,id:\.self) { index in Image(systemName:index < stars ? "star.fill" : "star").font(.caption2) }
                    Spacer(minLength:0)
                }.foregroundStyle(stars > 0 ? Color.orange : SolfegeTheme.muted.opacity(0.4))
            }.padding(14).foregroundStyle(unlocked ? SolfegeTheme.ink : SolfegeTheme.muted)
                .frame(height:110).frame(maxWidth:.infinity)
                .background(unlocked ? Color.white : SolfegeTheme.field,in:RoundedRectangle(cornerRadius:18))
                .overlay(RoundedRectangle(cornerRadius:18).stroke(number == game.progress.unlocked ? SolfegeTheme.violet : .clear,lineWidth:2))
        }.buttonStyle(.plain).disabled(!unlocked)
            .accessibilityLabel("\(number)판, \(level.title), \(unlocked ? "별 \(stars)개" : "잠김")")
            .accessibilityIdentifier("echo-level-\(number)")
    }

    private func play(_ challenge: EchoDragonChallenge) -> some View {
        VStack(spacing:18) {
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    Text("\(challenge.level.number)판 · \(challenge.level.title)").font(.title3.bold())
                    Text(challenge.level.rule.instruction).foregroundStyle(SolfegeTheme.muted)
                }
                Spacer()
                Label(challenge.level.rule.title,systemImage:challenge.level.rule == .mirror ? "arrow.up.arrow.down" : "arrow.up.right")
                    .font(.headline).padding(12)
                    .background(challenge.level.rule == .mirror ? Color.cyan.opacity(0.12) : SolfegeTheme.soft,in:Capsule())
            }
            HStack(spacing:22) {
                EchoDragonMascot(happy:game.result == .correct,singing:game.isPlaying)
                    .frame(width:190,height:165)
                VStack(alignment:.leading,spacing:12) {
                    Text(message(challenge)).font(.system(size:24,weight:.bold,design:.rounded))
                        .foregroundStyle(SolfegeTheme.ink).fixedSize(horizontal:false,vertical:true)
                        .accessibilityIdentifier("echo-feedback")
                    if let introduction = challenge.level.introduction, game.result != .correct {
                        Text(introduction).font(.subheadline).foregroundStyle(SolfegeTheme.muted)
                    } else if game.result == .correct {
                        Text("\(EchoDragonInterval.at(challenge.interval).name) · \(challenge.interval)반음 · \(challenge.directionLabel)")
                            .foregroundStyle(SolfegeTheme.green)
                        HStack { ForEach(0..<3,id:\.self) { index in Image(systemName:index < game.stars ? "star.fill" : "star").foregroundStyle(.orange) } }
                    } else {
                        Text("드래곤을 듣고, 내 시작음에서 이어질 건반을 찾아요. 건반을 누르면 내 대답을 미리 들을 수 있어요.")
                            .font(.subheadline).foregroundStyle(SolfegeTheme.muted)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
                .background(challenge.level.rule == .mirror ? Color.cyan.opacity(0.07) : Color.white,in:RoundedRectangle(cornerRadius:24))

            HStack(spacing:12) {
                Button { game.listen() } label: {
                    Label(game.interrupted ? "다시 듣고 계속" : game.heardCall ? "드래곤 다시 듣기" : "드래곤 듣기",systemImage:"speaker.wave.2.fill")
                }.buttonStyle(.borderedProminent).disabled(game.isPlaying).accessibilityIdentifier("echo-listen")
                Button("내 시작음") { game.root() }.buttonStyle(.bordered).disabled(game.isPlaying || game.interrupted)
                Button("내 대답 듣기") { game.replayAnswer() }.buttonStyle(.bordered)
                    .disabled(game.selected == nil || game.isPlaying || game.interrupted)
                Spacer(minLength:0)
                if game.isPlaying { ProgressView().controlSize(.small) }
            }
            Text(game.isPlaying ? game.soundLabel : game.usedHint ? "반짝이는 건반이 정답이에요. 소리를 비교하며 따라 해보세요." : "발자국 = 내 시작음 · 밝은 건반 = 답 후보")
                .font(.subheadline).foregroundStyle(SolfegeTheme.muted).frame(maxWidth:.infinity,alignment:.leading)
                .accessibilityAddTraits(.updatesFrequently)

            EchoDragonKeyboard(challenge:challenge,selected:game.selected,
                               reveal:game.usedHint || game.result == .correct,
                               enabled:game.canAnswer,onRoot:{ game.root() },onSelect:{ game.select($0) })
                .frame(height:180)
            HStack(spacing:14) {
                if game.result == .correct {
                    Button { game.next() } label: {
                        Label(game.preview || challenge.level.number == EchoDragonLevel.count ? "레벨맵으로" : "다음 판",systemImage:"arrow.right")
                    }.buttonStyle(PrimaryButton()).accessibilityIdentifier("echo-next")
                    Button("정답 대답 다시 듣기") { game.replayAnswer() }.disabled(game.isPlaying || game.interrupted)
                } else {
                    Button { game.submit() } label: { Label("대답하기",systemImage:"paperplane.fill") }
                        .buttonStyle(PrimaryButton()).disabled(!game.canAnswer || game.selected == nil)
                        .accessibilityIdentifier("echo-submit")
                    Button("건반 힌트") { game.hint() }.buttonStyle(.bordered).disabled(!game.canAnswer)
                    if game.attempts > 0 {
                        Button("내 대답 → 정답 비교") { game.compare() }.buttonStyle(.bordered)
                            .disabled(game.selected == nil || game.isPlaying || game.interrupted)
                    }
                }
                Spacer(minLength:0)
            }
            Text("다시 듣기와 건반 탐색은 자유예요. 첫 제출 정답 ★★★ · 두 번째 정답 ★★ · 힌트 또는 세 번 이상 ★")
                .font(.footnote).foregroundStyle(SolfegeTheme.muted).frame(maxWidth:.infinity,alignment:.leading)
        }.padding(24).frame(maxWidth:1100).frame(maxWidth:.infinity)
    }

    private func message(_ challenge: EchoDragonChallenge) -> String {
        if game.interrupted { return "잠깐 쉬었어요. 다시 듣고 이어가요." }
        if game.result == .correct { return game.preview ? "마음이 통했어요!" : challenge.level.number == 72 ? "마지막 인사까지 전했어요!" : "마음이 통했어요! 다음 판이 열렸어요." }
        if game.result == .incorrect { return "고개를 갸웃… 다시 귀 기울여 볼까요?" }
        if !game.heardCall { return challenge.level.rule == .mirror ? "같은 간격으로, 반대 방향으로!" : "내 부름에 답해줄래?" }
        return game.isPlaying ? "소리를 귀에 담아요." : "내 시작음에서 어떤 음으로 이어질까요?"
    }

    private var instructions: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    EchoDragonMascot(happy:true,singing:false).frame(width:180,height:155).frame(maxWidth:.infinity)
                    Text("두 음 사이의 간격으로 대화해요.").font(.title2.bold())
                    Text("① 드래곤 듣기를 누르세요. 두 음 뒤에 내 시작음이 들려요.\n\n② 밝은 건반을 눌러 대답을 미리 들어보세요. 시작음과 고른 음이 함께 들려요.\n\n③ 마음에 드는 소리를 찾으면 대답하기를 누르세요. 정답이면 다음 번호의 판이 열려요.")
                    Text("따라 하기 ↗↗").font(.headline)
                    Text("드래곤이 온음 올라가면, 나도 내 시작음에서 온음 올라가요. 시작하는 음높이가 달라도 간격이 같으면 돼요.")
                    Text("거울 대답 ↗↘ · 25판에서 등장").font(.headline)
                    Text("드래곤이 온음 올라가면, 나는 온음 내려가요. 내려가는 부름에는 올라가며 답해요. 간격은 그대로예요.")
                    Text("다시 듣기에는 불이익이 없어요. 힌트를 쓰면 정답 건반이 표시되고 별 1개를 받아요. 예전 판을 다시 풀면 가장 좋은 별 기록이 남아요.")
                        .foregroundStyle(SolfegeTheme.muted)
                }.padding(28)
            }.navigationTitle("에코 드래곤 하는 법").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("확인") { help = false } } }
        }.presentationDetents([.large])
    }
}

private struct EchoDragonKeyboard: View {
    let challenge: EchoDragonChallenge
    let selected: Int?
    let reveal: Bool
    let enabled: Bool
    let onRoot: () -> Void
    let onSelect: (Int) -> Void
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment:.topLeading) {
                ForEach(PianoGeometry(range:challenge.keyboardRange).keys,id:\.midi) { key in
                    let candidate = challenge.choices.contains(key.midi)
                    let root = key.midi == challenge.replyRoot
                    let highlighted = reveal && key.midi == challenge.answer
                    Button { if root { onRoot() } else { onSelect(key.midi) } } label: {
                        ZStack(alignment:.bottom) {
                            RoundedRectangle(cornerRadius:key.black ? 7 : 10)
                                .fill(keyColor(key,candidate:candidate,highlighted:highlighted))
                            VStack(spacing:7) {
                                if highlighted { Image(systemName:"sparkles") }
                                if root { Image(systemName:"pawprint.fill"); Text("시작").font(.caption2) }
                                else if selected == key.midi { Image(systemName:"checkmark.circle.fill") }
                                else if candidate { Circle().frame(width:7,height:7) }
                            }.font(.headline).foregroundStyle(key.black ? Color.white : SolfegeTheme.violet)
                                .padding(.bottom,12)
                        }.overlay(RoundedRectangle(cornerRadius:key.black ? 7 : 10)
                            .stroke(highlighted ? Color.orange : selected == key.midi ? SolfegeTheme.violet : .clear,lineWidth:3))
                    }.buttonStyle(.plain)
                        .frame(width:max(1,proxy.size.width*key.width-2),height:proxy.size.height*key.height-2)
                        .offset(x:proxy.size.width*key.x+1,y:1)
                        .disabled(!enabled || (!candidate && !root))
                        .accessibilityLabel("\(MelodyRound.noteName(key.midi)), \(root ? "내 시작음" : candidate ? "답 후보" : "사용하지 않는 건반")")
                        .accessibilityIdentifier("echo-key-\(key.midi)")
                }
            }.background(SolfegeTheme.ink,in:RoundedRectangle(cornerRadius:12))
        }
    }
    private func keyColor(_ key: PianoKeyGeometry,candidate: Bool,highlighted: Bool) -> Color {
        if highlighted { return key.black ? SolfegeTheme.violet : Color.orange.opacity(0.22) }
        if selected == key.midi { return key.black ? SolfegeTheme.deepViolet : SolfegeTheme.soft }
        if key.midi == challenge.replyRoot { return key.black ? SolfegeTheme.violet : SolfegeTheme.soft }
        return key.black ? (candidate ? SolfegeTheme.ink : Color.gray.opacity(0.65)) : (candidate ? .white : Color(white:0.86))
    }
}

// A native vector mascot keeps the prototype self-contained and sharp on iPad.
private struct EchoDragonMascot: View {
    let happy: Bool
    let singing: Bool
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Ellipse().fill(SolfegeTheme.violet.opacity(0.09)).frame(width:160,height:22).offset(y:68)
                DragonWing().fill(SolfegeTheme.violet.opacity(0.35)).frame(width:60,height:72).rotationEffect(.degrees(-12)).offset(x:-60,y:8)
                DragonWing().fill(SolfegeTheme.violet.opacity(0.35)).frame(width:60,height:72).scaleEffect(x:-1,y:1).rotationEffect(.degrees(12)).offset(x:60,y:8)
                Capsule().fill(SolfegeTheme.violet).frame(width:65,height:22).rotationEffect(.degrees(-25)).offset(x:64,y:44)
                Ellipse().fill(SolfegeTheme.violet).frame(width:106,height:104).offset(y:27)
                Ellipse().fill(SolfegeTheme.soft).frame(width:58,height:66).offset(y:34)
                DragonWing().fill(Color.orange.opacity(0.7)).frame(width:22,height:35).offset(x:-30,y:-59)
                DragonWing().fill(Color.orange.opacity(0.7)).frame(width:22,height:35).scaleEffect(x:-1,y:1).offset(x:30,y:-59)
                RoundedRectangle(cornerRadius:38).fill(SolfegeTheme.violet).frame(width:124,height:100).offset(y:-22)
                ForEach([-1.0,1.0],id:\.self) { side in
                    Ellipse().fill(Color.pink.opacity(0.6)).frame(width:19,height:10).offset(x:side*41,y:-8)
                    if happy {
                        Capsule().fill(Color.white).frame(width:15,height:5).rotationEffect(.degrees(side * -20)).offset(x:side*26,y:-29)
                    } else {
                        Ellipse().fill(Color.white).frame(width:19,height:24).offset(x:side*26,y:-29)
                        Circle().fill(SolfegeTheme.ink).frame(width:9,height:9).offset(x:side*26,y:-27)
                    }
                    Capsule().fill(SolfegeTheme.deepViolet).frame(width:33,height:16).offset(x:side*36,y:68)
                }
                if singing { Ellipse().fill(SolfegeTheme.ink).frame(width:16,height:20).offset(y:1) }
                else { Capsule().fill(SolfegeTheme.ink).frame(width:happy ? 27 : 15,height:happy ? 8 : 4).offset(y:2) }
            }.frame(width:200,height:180)
                .rotationEffect(.degrees(happy ? -6 : singing ? 3 : 0))
                .animation(.spring(response:0.4,dampingFraction:0.6),value:happy)
                .animation(.easeInOut(duration:0.25),value:singing)
                .scaleEffect(min(proxy.size.width/200,proxy.size.height/180))
                .position(x:proxy.size.width/2,y:proxy.size.height/2)
        }.accessibilityHidden(true)
    }
}

private struct DragonWing: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to:CGPoint(x:rect.maxX,y:rect.maxY))
        path.addQuadCurve(to:CGPoint(x:rect.minX,y:rect.minY),control:CGPoint(x:rect.minX,y:rect.maxY*0.7))
        path.addLine(to:CGPoint(x:rect.maxX*0.48,y:rect.maxY*0.25))
        path.addLine(to:CGPoint(x:rect.maxX*0.7,y:rect.maxY*0.05))
        path.addQuadCurve(to:CGPoint(x:rect.maxX,y:rect.maxY),control:CGPoint(x:rect.maxX*0.9,y:rect.maxY*0.3))
        path.closeSubpath()
        return path
    }
}
