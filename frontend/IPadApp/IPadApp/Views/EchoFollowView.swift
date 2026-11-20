import SwiftUI
import AVFoundation

struct EchoFollowView: View {
    let stage: DrillStageContext
    @StateObject private var game: EchoFollowModel
    @Environment(\.scenePhase) private var phase
    @State private var help = false
    @State private var visible = false
    @AppStorage("echo-follow-tutorial-v1") private var tutorialSeen = false
    init(stage: DrillStageContext,audio: MelodyRunAudio) {
        self.stage=stage; _game=StateObject(wrappedValue:EchoFollowModel(question:stage.question,audio:audio))
    }
    var body: some View {
        ScrollView { VStack(spacing:14) {
            HStack {
                Text("Echo Dragon").font(.title2.bold()); StageChip(stage:stage.stage); Spacer()
                Button { game.stop(); help=true } label: { Image(systemName:"questionmark.circle").frame(width:44,height:44) }.accessibilityLabel("게임 방법")
                Button { game.stop(); stage.exit() } label: { Image(systemName:"xmark").frame(width:44,height:44) }.accessibilityLabel("계단으로")
            }
            DrillSetProgress(results:stage.results,index:stage.index)
            HStack(spacing:28) {
                Image(systemName:"lizard.fill").font(.system(size:48)).foregroundStyle(SolfegeTheme.green)
                    .scaleEffect(game.playing ? 1.05 : 1).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:12) {
                    Text(game.playing ? "드래곤이 노래해요" : game.result != nil ? game.message : "들은 두 음을 따라 눌러요").font(.title2.bold())
                    Text("시작음 \(MelodyRound.noteName(game.notes.first ?? 60))").foregroundStyle(SolfegeTheme.muted)
                }
                Spacer(minLength:0)
            }.padding(18).frame(maxWidth:.infinity).background(.white,in:RoundedRectangle(cornerRadius:18))
            HStack(spacing:16) {
                ForEach(0..<2,id:\.self) { i in
                    VStack(spacing:8) {
                        Text("\(i+1)번째 음").font(.caption).foregroundStyle(SolfegeTheme.muted)
                        Text(game.result?.revealed == true ? MelodyRound.noteName(game.notes[i]) : game.inputs.indices.contains(i) ? MelodyRound.noteName(game.inputs[i]) : "—")
                            .font(.title2.bold()).frame(maxWidth:.infinity,minHeight:40)
                    }.padding(12).background(SolfegeTheme.soft,in:RoundedRectangle(cornerRadius:12))
                }
            }
            if game.result == nil && !game.message.isEmpty { Text(game.message).foregroundStyle(SolfegeTheme.danger) }
            MelodyPianoView(range:game.range,enabled:game.canEnter,solfege:true,reference:game.notes.first,onDown:game.keyDown,onUp:game.keyUp)
                .frame(height:180).frame(maxWidth:900)
            HStack(spacing:16) {
                Button(game.playing ? "정지" : "다시 듣기",systemImage:game.playing ? "stop.fill" : "play.fill") { game.playing ? game.stop() : game.listen() }.buttonStyle(.bordered)
                if game.result == nil {
                    Button("한 음 취소",systemImage:"arrow.uturn.backward") { game.undo() }.buttonStyle(.bordered).disabled(!game.canEnter || game.inputs.isEmpty)
                    Button("정답 보고 넘기기") { game.reveal() }.font(.subheadline).disabled(game.playing)
                }
                Spacer()
                if game.result != nil { Button(stage.nextTitle) { game.stop(); stage.next() }.buttonStyle(PrimaryButton()) }
                else { Button("제출") { game.submit() }.buttonStyle(PrimaryButton()).disabled(!game.canEnter || game.inputs.count != 2) }
            }
        }.padding(24) }.background(SolfegeTheme.background).tint(SolfegeTheme.violet)
            .task { if tutorialSeen { game.listen() } else { help=true } }
            .onAppear { visible=true }
            .onChange(of:game.result) { _, value in if let value { stage.report(value) } }
            .onChange(of:phase) { _, value in if value != .active { game.suspend() } }
            .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.interruptionNotification).receive(on:RunLoop.main)) { _ in game.suspend() }
            .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.mediaServicesWereResetNotification).receive(on:RunLoop.main)) { _ in game.suspend(); game.audio.stop() }
            .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.routeChangeNotification).receive(on:RunLoop.main)) { note in
                if let raw=note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                   AVAudioSession.RouteChangeReason(rawValue:raw) == .oldDeviceUnavailable { game.stop() }
            }
            .onDisappear { visible=false; game.stop() }
            .sheet(isPresented:$help,onDismiss:{ tutorialSeen=true; if visible && phase == .active && !game.heard && game.result == nil { game.listen() } }) {
                VStack(spacing:24) {
                    Text("들은 두 음을 그대로 따라 해요").font(.title2.bold())
                    HStack(spacing:30) { Label("두 음 듣기",systemImage:"ear"); Image(systemName:"arrow.right"); Label("건반 두 번 누르기",systemImage:"hand.tap") }
                    Text("표시된 시작음을 참고하세요. 첫 음도 직접 눌러야 해요.").foregroundStyle(SolfegeTheme.muted)
                    MelodyPianoView(range:60...72,enabled:false,solfege:true,reference:60,onDown:{_ in},onUp:{_ in}).frame(height:160)
                    Button("계속하기") { help=false }.buttonStyle(PrimaryButton())
                }.padding(32).presentationDetents([.large])
            }
            .alert("확인이 필요해요",isPresented:Binding(get:{game.error != nil},set:{if !$0 {game.error=nil}})) { Button("확인") { game.error=nil } } message: { Text(game.error ?? "") }
    }
}
