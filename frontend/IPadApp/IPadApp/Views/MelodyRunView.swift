import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct MiniGameHubView: View {
    @State private var playing = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:26) {
                SectionCaption(eyebrow:"PLAY WITH SOUND",title:"미니게임",subtitle:"짧게 듣고, 가볍게 연주하고. 귀의 감각을 깨워 보세요.")
                Button { playing = true } label: {
                    VStack(alignment:.leading,spacing:24) {
                        HStack { Pill(text:"NEW · 두 가지 플레이"); Spacer(); Image(systemName:"arrow.up.right").font(.title2) }
                        HStack(spacing:24) {
                            Image(systemName:"pianokeys").font(.system(size:64,weight:.light))
                            VStack(alignment:.leading,spacing:10) {
                                Text("멜로디 런").font(.system(size:34,weight:.bold,design:.rounded))
                                Text("귀에 담은 멜로디를, 손끝으로 다시.").font(.title3)
                                Text("메모리 · 그루브  /  2·4·8마디  /  피아노 입력").font(.subheadline).opacity(0.8)
                            }
                        }
                        Label("플레이하기",systemImage:"play.fill").font(.headline).padding(.horizontal,20).padding(.vertical,12).background(.white.opacity(0.22),in:Capsule())
                    }.foregroundStyle(.white).padding(32).frame(maxWidth:.infinity,alignment:.leading)
                        .background(LinearGradient(colors:[SORITheme.violet,Color(red:0.47,green:0.40,blue:0.92)],startPoint:.topLeading,endPoint:.bottomTrailing),in:RoundedRectangle(cornerRadius:26))
                }.buttonStyle(.plain)
                Card {
                    HStack(spacing:18) {
                        Image(systemName:"metronome").font(.largeTitle).foregroundStyle(SORITheme.violet.opacity(0.4))
                        VStack(alignment:.leading,spacing:6) { Text("리듬 런").font(.headline); Text("다음 소리 놀이를 준비하고 있어요").font(.subheadline).foregroundStyle(.secondary) }
                        Spacer(); Pill(text:"COMING SOON")
                    }
                }
                Label("서버 연결 없이도 모든 미니게임 문제를 플레이할 수 있어요",systemImage:"wifi.slash").font(.footnote).foregroundStyle(.secondary)
            }.padding(32).frame(maxWidth:1060).frame(maxWidth:.infinity)
        }
        .fullScreenCover(isPresented:$playing) { MelodyRunView() }
    }
}

struct MelodyRunView: View {
    @StateObject private var game = MelodyRunModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var picking = false
    @State private var importing = false
    var body: some View {
        ZStack {
            SORITheme.background.ignoresSafeArea()
            switch game.page {
            case .setup: setup
            case .playing: play
            case .result: result
            }
            if game.working {
                Color.black.opacity(0.12).ignoresSafeArea()
                ProgressView("피아노와 선율 준비 중").padding(28).background(.regularMaterial,in:RoundedRectangle(cornerRadius:20))
            }
        }.tint(SORITheme.violet).preferredColorScheme(.light)
        .sheet(isPresented:$picking) { MelodyQuestionPicker(game:game) }
        .fileImporter(isPresented:$importing,allowedContentTypes:[.xml,UTType(filenameExtension:"musicxml") ?? .xml],allowsMultipleSelection:true) { result in
            switch result {
            case .success(let urls): game.importFiles(urls)
            case .failure(let error): game.error = error.localizedDescription
            }
        }
        .alert("확인이 필요해요",isPresented:Binding(get:{game.error != nil},set:{if !$0 {game.error = nil}})) {
            Button("확인") { game.error = nil }
        } message: { Text(game.error ?? "") }
        .onChange(of:scenePhase) { _, phase in if phase != .active { game.pause() } }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.interruptionNotification).receive(on:RunLoop.main)) { _ in game.pause() }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.mediaServicesWereResetNotification).receive(on:RunLoop.main)) { _ in game.pause() }
        .onReceive(NotificationCenter.default.publisher(for:.AVAudioEngineConfigurationChange).receive(on:RunLoop.main)) { notification in
            if game.audio.owns(notification), !game.audio.isRunning { game.pause() }
        }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.routeChangeNotification).receive(on:RunLoop.main)) { notification in
            if let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               AVAudioSession.RouteChangeReason(rawValue:raw) == .oldDeviceUnavailable { game.pause() }
        }
        .onDisappear { game.stop() }
    }
    private var close: some View {
        Button { game.stop(); dismiss() } label: { Image(systemName:"xmark").font(.headline).frame(width:44,height:44).background(.white,in:Circle()) }
            .accessibilityLabel("미니게임 닫기")
    }
    private var setup: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                HStack(alignment:.top) { SectionCaption(eyebrow:"MELODY RUN",title:"귀에 담고, 손끝으로 달려요",subtitle:"리듬은 준비되어 있어요. 기억한 음높이만 차례로 눌러 보세요."); Spacer(); close }
                HStack(spacing:16) {
                    modeCard(.memory,icon:"brain.head.profile",description:"전부 듣고, 한 번에 복원",detail:"시간제한 없이 기억에 집중해요")
                    modeCard(.groove,icon:"waveform.path",description:"듣고, 느끼고, 바로 연주",detail:"같은 템포로 한 마디씩 이어가요")
                }
                HStack(alignment:.top,spacing:20) {
                    Card {
                        VStack(alignment:.leading,spacing:18) {
                            HStack { Text("오늘의 선율").font(.headline); Spacer(); Button { game.randomize() } label: { Label("랜덤",systemImage:"shuffle") } }
                            Text(game.question?.title ?? "문제를 추가해 주세요").font(.title3.bold()).lineLimit(2)
                            if let q = game.question {
                                Text("\(q.key) · \(q.beats)/\(q.beatType) · \(q.noteCount)음").font(.subheadline).foregroundStyle(.secondary)
                                Text("음역 \(MelodyRound.noteName(q.lowestMidi)) – \(MelodyRound.noteName(q.highestMidi))").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack { Button("문제 선택 · \(game.questions.count)개") { picking = true }.buttonStyle(.bordered); Button { importing = true } label: { Label("XML 추가",systemImage:"square.and.arrow.down") } }
                            Divider()
                            Text("플레이 길이").font(.subheadline.bold())
                            Picker("마디 수",selection:$game.settings.bars) { ForEach([2,4,8],id:\.self) { Text("\($0)마디").tag($0) } }.pickerStyle(.segmented)
                                .onChange(of:game.settings.bars) { _, bars in game.settings.startBar = min(game.settings.startBar,9-bars) }
                            Stepper("\(game.settings.startBar)–\(game.settings.startBar+game.settings.bars-1)마디 구간",value:$game.settings.startBar,in:1...(9-game.settings.bars))
                            if let message = game.importMessage { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                    }
                    Card {
                        VStack(alignment:.leading,spacing:18) {
                            HStack { Text("플레이 감각").font(.headline); Spacer(); Text("♩ = \(Int(game.settings.bpm))").font(.title3.bold().monospacedDigit()).foregroundStyle(SORITheme.violet) }
                            Slider(value:$game.settings.bpm,in:40...180,step:2) { Text("BPM") }
                            Text("BPM은 4분음표 기준이에요. 6/8·9/8·12/8은 점4분음표 비트로 느껴요.").font(.caption).foregroundStyle(.secondary)
                            Divider()
                            if game.settings.mode == .memory {
                                Stepper("마디 사이 \(game.settings.gapBeats)비트",value:$game.settings.gapBeats,in:0...8)
                                Text("한 마디씩 모두 들은 뒤 복원해요. 입력 시간은 무제한이고, 마디를 채우면 바로 넘어가요.").font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
                            } else {
                                Stepper("입력 시간 · \(game.settings.inputBars)마디",value:$game.settings.inputBars,in:1...4)
                                Toggle("일찍 완성하면 다음 박에 진행",isOn:$game.settings.advanceEarly)
                                Text("선율 1마디 → 비트 1마디 → 입력. 정해진 시간이 지나면 미입력 음을 남기고 다음 마디로 이어져요.").font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
                            }
                        }
                    }
                }
                HStack {
                    VStack(alignment:.leading,spacing:5) { Label("가로 화면 · 양손으로 가볍게",systemImage:"ipad.landscape").font(.subheadline.bold()); Text("건반은 언제나 소리가 나요. 입력 단계에서 누른 음만 기록해요. 붙임줄과 쉼표는 자동으로 채워져요.").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button { Task { await game.start() } } label: { Label("\(game.settings.mode.title) 시작",systemImage:"play.fill") }.buttonStyle(PrimaryButton()).disabled(game.questions.isEmpty || game.working)
                }
                attribution
            }.padding(32).frame(maxWidth:1240).frame(maxWidth:.infinity)
        }
    }
    private func modeCard(_ mode: MelodyMode, icon: String, description: String, detail: String) -> some View {
        let selected = game.settings.mode == mode
        return Button { game.settings.mode = mode } label: {
            HStack(spacing:18) {
                Image(systemName:icon).font(.system(size:32)).frame(width:60,height:60).background(.white.opacity(0.7),in:RoundedRectangle(cornerRadius:16))
                VStack(alignment:.leading,spacing:5) { Text(mode.title).font(.title2.bold()); Text(description).font(.subheadline.bold()); Text(detail).font(.caption).foregroundStyle(.secondary) }
                Spacer(); Image(systemName:selected ? "checkmark.circle.fill" : "circle").font(.title2)
            }.padding(22).frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(SORITheme.ink)
                .background(selected ? SORITheme.soft : .white,in:RoundedRectangle(cornerRadius:22))
                .overlay(RoundedRectangle(cornerRadius:22).stroke(selected ? SORITheme.violet : .clear,lineWidth:2))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var play: some View {
        GeometryReader { geometry in
            VStack(spacing:14) {
                HStack {
                    VStack(alignment:.leading,spacing:3) { Text("MELODY RUN / \(game.settings.mode.title)").font(.caption.bold()).tracking(2).foregroundStyle(SORITheme.violet); Text(game.question?.title ?? "").font(.headline).lineLimit(1) }
                    Spacer(); Pill(text:"\(game.measure) / \(game.round?.score.measures ?? 0)마디")
                    Pill(text:"♩ \(Int(game.settings.bpm))",icon:"metronome")
                    Button { game.paused ? game.resume() : game.pause() } label: { Image(systemName:game.paused ? "play.fill" : "pause.fill").frame(width:44,height:44).background(.white,in:Circle()) }.accessibilityLabel(game.paused ? "계속하기" : "일시 정지")
                    close
                }
                HStack(spacing:12) {
                    phasePill("듣기",icon:"ear",active:game.phase == .listen)
                    phasePill("비트",icon:"waveform",active:game.phase == .beat || game.phase == .countIn)
                    phasePill("입력",icon:"pianokeys",active:game.phase == .input)
                    Spacer()
                    if game.round != nil {
                        ForEach(0..<game.beatsPerBar,id:\.self) { index in
                            Circle().fill(game.pulse == index && !game.paused ? SORITheme.violet : SORITheme.violet.opacity(0.15)).frame(width:14,height:14)
                        }
                    }
                }
                VStack(alignment:.leading,spacing:4) {
                    HStack {
                        Text(game.label).font(.system(size:25,weight:.bold,design:.rounded))
                        Spacer()
                        if game.canEnter { Text("\(game.currentCount) / \(game.currentTotal)음").font(.title3.bold().monospacedDigit()).foregroundStyle(SORITheme.violet) }
                        if game.settings.mode == .groove { Text(String(format:"%.1f초",game.remainingSeconds)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    if game.settings.mode == .groove || game.phase != .input { ProgressView(value:min(1,max(0,game.progress))).padding(.top,5) }
                    if let round = game.round, let answers = game.answers {
                        let display = round.display(measure:game.measure,answers:answers.pitches)
                        MelodyStaff(score:display.0,fifths:round.source.fifths,clef:round.source.clef,pending:display.1)
                            .frame(maxWidth:.infinity,maxHeight:.infinity)
                    }
                }.padding(.horizontal,22).padding(.top,16).background(.white,in:RoundedRectangle(cornerRadius:20))
                    .overlay { if game.paused {
                        VStack(spacing:12) {
                            Text("잠시 쉬어가요").font(.title2.bold())
                            Text("입력은 유지돼요. 진행 중이던 듣기 구간부터 다시 이어집니다.").font(.subheadline)
                            Button("계속하기") { game.resume() }.buttonStyle(PrimaryButton(compact:true))
                        }.frame(maxWidth:.infinity,maxHeight:.infinity).background(.regularMaterial,in:RoundedRectangle(cornerRadius:20))
                    } }
                HStack(spacing:10) {
                    if let round = game.round {
                        ForEach(1...round.score.measures,id:\.self) { bar in
                            Button { game.selectBar(bar) } label: {
                                HStack(spacing:4) { Text("\(bar)"); if game.answers?.complete(bar) == true { Image(systemName:"checkmark").font(.caption2.bold()) } }
                                    .font(.subheadline.bold()).frame(minWidth:38,minHeight:36).padding(.horizontal,6)
                                    .foregroundStyle(bar == game.measure ? .white : SORITheme.violet)
                                    .background(bar == game.measure ? SORITheme.violet : SORITheme.soft,in:RoundedRectangle(cornerRadius:9))
                            }.buttonStyle(.plain).accessibilityLabel("\(bar)마디")
                        }
                    }
                    Spacer()
                    Text(game.phase == .input ? "회색 음표는 아직 비어 있어요" : "지금은 듣는 시간 · 건반은 연습만 돼요").font(.caption).foregroundStyle(.secondary)
                }
                MelodyPianoView(range:game.round?.keyboardRange ?? 60...84,enabled:!game.paused && !game.working,onDown:game.keyDown,onUp:game.keyUp)
                    .frame(height:max(190,min(290,geometry.size.height*0.34)))
                HStack(spacing:14) {
                    Button { game.undo() } label: { Label("한 음 취소",systemImage:"delete.left") }.buttonStyle(.bordered).disabled(!game.canEnter)
                    Button("이 마디 지우기") { game.clearBar() }.buttonStyle(.bordered).disabled(!game.canEnter)
                    Spacer()
                    if game.settings.mode == .memory { Text("시간제한 없음").font(.caption).foregroundStyle(.secondary) }
                    Button { game.finish() } label: { Label(game.allEntered ? "정답 제출" : "여기까지 제출",systemImage:"checkmark") }.buttonStyle(PrimaryButton(compact:true)).disabled(game.paused)
                }
            }.padding(.horizontal,24).padding(.vertical,16)
        }
    }
    private func phasePill(_ text: String, icon: String, active: Bool) -> some View {
        Label(text,systemImage:icon).font(.subheadline.bold()).padding(.horizontal,18).padding(.vertical,9)
            .foregroundStyle(active ? .white : SORITheme.ink.opacity(0.5))
            .background(active ? SORITheme.violet : .white,in:Capsule())
    }
    private var result: some View {
        ScrollView {
            if let round = game.round, let answers = game.answers {
                let result = answers.result
                VStack(alignment:.leading,spacing:24) {
                    HStack {
                        SectionCaption(eyebrow:result.accuracy == 100 ? "PERFECT MELODY!" : "NICE RUN!",title:result.accuracy == 100 ? "멜로디를 완벽하게 되찾았어요" : "다시 들으면, 더 선명해져요",subtitle:"리듬은 그대로, 음높이만 비교한 결과예요. 옥타브도 정확히 맞아야 해요.")
                        Spacer(); close
                    }
                    HStack(spacing:20) {
                        resultMetric("음높이 정확도","\(result.accuracy)%",icon:"scope")
                        resultMetric("점수","\(result.points)",icon:"sparkles")
                        resultMetric("최고 콤보","\(result.bestCombo)",icon:"flame.fill")
                    }
                    HStack(spacing:12) {
                        Button { game.replay(user:false) } label: { Label("원본 선율",systemImage:"play.fill") }.buttonStyle(.borderedProminent)
                        Button { game.replay(user:true) } label: { Label("내 연주",systemImage:"play.fill") }.buttonStyle(.bordered)
                        if let playing = game.replaying { Button { game.stopReplay() } label: { Label("\(playing) 정지",systemImage:"stop.fill") }.buttonStyle(.bordered) }
                        Spacer()
                        Button("설정") { game.setup() }.buttonStyle(.bordered)
                        Button("재도전") { Task { await game.start() } }.buttonStyle(.bordered)
                        Button("다음 문제") { game.randomize(); Task { await game.start() } }.buttonStyle(PrimaryButton(compact:true))
                    }
                    Text("\(result.correct) / \(round.targets.count)음 정답 · 미입력은 오답 · 붙임줄로 이어진 음은 한 번만 입력하고 채점해요").font(.subheadline).foregroundStyle(.secondary)
                    ForEach(1...round.score.measures,id:\.self) { bar in
                        resultBar(bar,round:round,answers:answers)
                    }
                    attribution
                }.padding(32).frame(maxWidth:1240).frame(maxWidth:.infinity)
            }
        }
    }
    private func resultMetric(_ title: String, _ value: String, icon: String) -> some View {
        Card { VStack(alignment:.leading,spacing:12) { Label(title,systemImage:icon).font(.subheadline).foregroundStyle(.secondary); Text(value).font(.system(size:42,weight:.bold,design:.rounded)).foregroundStyle(SORITheme.violet) } }
    }
    private func resultBar(_ bar: Int, round: MelodyRound, answers: MelodyAnswers) -> some View {
        let expected = round.display(measure:bar,answers:answers.pitches,reveal:true)
        let actual = round.display(measure:bar,answers:answers.pitches)
        let indices = round.targetIndices(measure:bar)
        let correct = indices.filter { answers.pitches[$0] == round.targets[$0].midi }.count
        return Card {
            VStack(alignment:.leading,spacing:8) {
                HStack {
                    Text("\(bar+game.settings.startBar-1)마디").font(.headline)
                    Pill(text:indices.isEmpty ? "자동 연결" : "\(correct) / \(indices.count)음")
                    Spacer()
                    Button { game.replay(user:false,measure:bar) } label: { Label("원본",systemImage:"play.circle") }
                    Button { game.replay(user:true,measure:bar) } label: { Label("내 연주",systemImage:"play.circle") }
                }
                VStack(alignment:.leading,spacing:6) {
                    VStack(alignment:.leading,spacing:0) { Text("원본").font(.caption).foregroundStyle(.secondary); MelodyStaff(score:expected.0,fifths:round.source.fifths,clef:round.source.clef) }
                    VStack(alignment:.leading,spacing:0) { Text("내 입력 · 틀린 음은 빨간색").font(.caption).foregroundStyle(.secondary); MelodyStaff(score:actual.0,fifths:round.source.fifths,clef:round.source.clef,pending:actual.1,incorrect:actual.2) }
                }
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:8) {
                        ForEach(Array(indices.enumerated()),id:\.element) { number,index in
                            let right = answers.pitches[index] == round.targets[index].midi
                            Text("\(number+1). \(MelodyRound.noteName(round.targets[index].midi)) → \(MelodyRound.noteName(answers.pitches[index]))")
                                .font(.caption.weight(.medium)).padding(9).foregroundStyle(right ? SORITheme.green : .red)
                                .background((right ? SORITheme.green : Color.red).opacity(0.08),in:RoundedRectangle(cornerRadius:8))
                        }
                    }
                }
            }
        }
    }
    private var attribution: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                Text("문제: The Trained Ear · Andre Mount · CC BY-SA 4.0").font(.caption)
                if let raw = game.question?.sourceURL, let url = URL(string:raw), url.scheme == "https" { Link("문제 출처",destination:url).font(.caption) }
                Link("라이선스",destination:URL(string:"https://creativecommons.org/licenses/by-sa/4.0/")!).font(.caption)
            }
            DisclosureGroup("출처와 변경 내역") {
                Text("원본 MusicXML의 음높이·리듬·조성·박자를 유지하고 레이아웃·가사 등 게임에 사용하지 않는 정보를 생략했어요. 문제 XML과 목록은 CC BY-SA 4.0으로 제공돼요. 직접 추가한 파일은 해당 파일의 출처와 이용조건을 따릅니다.").font(.caption).padding(.top,6)
                if let url = Bundle.main.url(forResource:"melody-source-license",withExtension:"txt"), let text = try? String(contentsOf:url,encoding:.utf8) { Text(text).font(.caption2).textSelection(.enabled).padding(.top,6) }
            }.font(.caption)
        }.foregroundStyle(.secondary)
    }
}

struct MelodyStaff: View {
    let score: MusicScore
    let fifths: Int
    let clef: String
    var pending: Set<Int> = []
    var incorrect: Set<Int> = []
    var body: some View {
        Canvas { context,size in NativeScoreRenderer(singleMeasure:true,keyFifths:fifths,clef:clef,pending:pending,incorrect:incorrect).render(score,context:&context,size:size) }
            .aspectRatio(1330.0/280,contentMode:.fit).background(.white)
            .accessibilityLabel("\(score.symbols.filter { $0.midi != nil }.count)음의 리듬 악보, \(pending.count)음 미입력")
    }
}

private struct MelodyQuestionPicker: View {
    @ObservedObject var game: MelodyRunModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var filtered: [MelodyQuestion] {
        game.questions.filter { query.isEmpty || "\($0.title) \($0.key) \($0.beats)/\($0.beatType)".localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            List(filtered) { question in
                Button { game.selection = question.id; dismiss() } label: {
                    HStack {
                        VStack(alignment:.leading,spacing:6) { Text(question.title).font(.headline); Text("\(question.key) · \(question.beats)/\(question.beatType) · \(question.noteCount)음 · \(MelodyRound.noteName(question.lowestMidi))–\(MelodyRound.noteName(question.highestMidi))").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); if game.selection == question.id { Image(systemName:"checkmark.circle.fill") }
                    }.padding(.vertical,5)
                }.foregroundStyle(SORITheme.ink)
            }.searchable(text:$query,prompt:"제목, 조성, 박자로 검색")
                .navigationTitle("선율 고르기 · \(filtered.count)개")
                .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("닫기") { dismiss() } } }
        }.tint(SORITheme.violet)
    }
}
