import SwiftUI
import AVFoundation

struct EchoIntervalStageView: View {
    let stage: DrillStage
    let mastered: () -> Void
    let exit: () -> Void
    @StateObject private var game: EchoIntervalStageModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tutorialScope) private var tutorialScope
    @State private var help = false
    @State private var visible = false
    @State private var confirmingExit = false
    @State private var continueAfterHelp = false
    init(stage: DrillStage, model: EchoIntervalStageModel? = nil, mastered: @escaping () -> Void, exit: @escaping () -> Void) {
        self.stage=stage; self.mastered=mastered; self.exit=exit
        _game=StateObject(wrappedValue:model ?? EchoIntervalStageModel(stage:EchoIntervalStage.forStair(stage.number) ?? EchoIntervalStage(1)))
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing:14) {
                header
                progress
                EchoDragonCharacter(phase:game.phase,noteOn:game.soundingNote != nil)
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
                    .overlay(alignment:.bottom) {
                        if game.phase == .completed || game.phase == .failed {
                            Text(game.phase == .completed ? "스테이지 클리어!" : "하트를 모두 사용했어요")
                                .font(.system(size:25,weight:.bold)).padding(.horizontal,20).padding(.vertical,10)
                                .background(.regularMaterial,in:Capsule()).offset(y:6)
                        }
                    }
                HStack {
                    Text(game.startReminder ? "표시된 첫 음부터 눌러주세요." : "")
                        .font(.subheadline.weight(.medium)).foregroundStyle(SolfegeTheme.violet)
                    Spacer()
                    EchoDragonHearts(remaining:game.run.hearts)
                }.frame(height:32)
                keyboard.frame(height:min(185,max(130,geometry.size.height*0.25)))
                actions.frame(height:54)
            }.frame(maxWidth:1000).padding(.horizontal,28).padding(.vertical,20)
                .frame(maxWidth:.infinity,maxHeight:.infinity)
        }
        .background(SolfegeTheme.background.ignoresSafeArea()).tint(SolfegeTheme.violet)
        .preferredColorScheme(.light)
        .task { visible=true; if !TutorialHistory.hasSeen(.echoDragon, scope: tutorialScope) { openTutorial() } }
        .onChange(of:game.phase) { _, phase in if phase == .completed { mastered() } }
        .onChange(of:scenePhase) { _, phase in
            if phase != .active { game.suspend() }
            else if visible && !help && !confirmingExit && !continueAfterHelp { game.resume() }
        }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.interruptionNotification).receive(on:RunLoop.main)) { note in
            if let raw=note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               AVAudioSession.InterruptionType(rawValue:raw) == .ended {
                if visible && !help && !confirmingExit && !continueAfterHelp { game.resume() }
            } else { game.suspend() }
        }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.mediaServicesWereResetNotification).receive(on:RunLoop.main)) { _ in game.suspend() }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.routeChangeNotification).receive(on:RunLoop.main)) { note in
            if let raw=note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               AVAudioSession.RouteChangeReason(rawValue:raw) == .oldDeviceUnavailable { game.suspend() }
        }
        .onDisappear { visible=false; game.suspend() }
        .alert("정말 종료하시겠습니까?",isPresented:$confirmingExit) {
            Button("계속하기",role:.cancel) { game.resume() }
            Button("종료",role:.destructive) { game.suspend(); exit() }
        } message: { Text("진행 상황이 저장되지 않습니다. 정말 종료하시겠습니까?") }
        .alert("소리를 재생하지 못했어요",isPresented:Binding(get:{game.error != nil},set:{if !$0 {game.error=nil}})) {
            Button("다시 시도") { game.error=nil; game.resume() }
        } message: { Text(game.error ?? "") }
        .allowsHitTesting(!help)
        .overlay {
            if help { TutorialWalkthrough(kind: .echoDragon) { game.finishTutorial(); help=false } }
            else if continueAfterHelp {
                VStack(spacing: 18) {
                    Text("준비되면 이어서 해요").font(.title3.bold())
                    Button("계속하기") { continueAfterHelp=false; game.resume() }.buttonStyle(PrimaryButton())
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.regularMaterial)
            }
        }
    }
    private var header: some View {
        ZStack {
            Text(game.run.stage.title).font(.system(size:28,weight:.bold))
                .lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal,185)
                .accessibilityIdentifier("echo-stage-topic")
            HStack {
                VStack(alignment:.leading,spacing:3) {
                    Text("Echo Dragon").font(.system(size:19,weight:.bold))
                    Text("Stage \(game.run.stage.number)").font(.subheadline).foregroundStyle(SolfegeTheme.muted)
                }
                Spacer()
                if !game.run.complete && !game.run.failed {
                    TutorialHelpButton(action: openTutorial)
                }
                Button {
                    game.suspend()
                    if game.run.complete || game.run.failed { exit() } else { confirmingExit=true }
                } label: { Image(systemName:"xmark").font(.title3).frame(width:44,height:44) }
                    .accessibilityLabel("완료하기")
            }
        }.frame(height:58)
    }
    private var progress: some View {
        let results: [DrillRoundResult?] = game.run.solved.indices.map { i in
            if game.run.errors[i] > 0 { return DrillRoundResult(accuracy:0,revealed:false,elapsedMs:0) }
            guard game.run.solved[i] else { return nil }
            return DrillRoundResult(accuracy:100,revealed:false,elapsedMs:0)
        }
        return DrillSetProgress(results:results,index:game.run.index)
    }
    private var keyboard: some View {
        let question=game.run.question
        return MelodyPianoView(range:question.keyboardRange,enabled:game.canEnter,solfege:true,
            reference:question.replyStart,onDown:game.keyDown,onUp:game.keyUp)
            .overlay {
                EchoPianoSelection(range:question.keyboardRange,selected:Set(game.inputs),
                    playing:game.phase == .answerPlayback ? game.soundingNote : nil)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .accessibilityIdentifier("echo-answer-keyboard")
    }
    private var actions: some View {
        HStack(spacing:18) {
            if !game.run.failed && !game.run.complete {
                Button { game.listen() } label: { Image(systemName:"arrow.counterclockwise").font(.title3).frame(width:48,height:48) }
                    .disabled(!game.hasStarted || !game.canListen).accessibilityLabel("드래곤 다시 듣기")
                Button { game.undo() } label: { Image(systemName:"arrow.uturn.backward").font(.title3).frame(width:48,height:48) }
                    .disabled(!game.canEnter || game.inputs.isEmpty).accessibilityLabel("한 음 취소")
            }
            Spacer()
            if game.run.failed || game.run.complete {
                Button("완료하기") { game.suspend(); exit() }.buttonStyle(PrimaryButton())
            } else if !game.hasStarted {
                Button("시작") { game.start() }.buttonStyle(PrimaryButton())
                    .accessibilityIdentifier("echo-start")
            } else if game.phase == .happy {
                Button("다음") { game.next() }.buttonStyle(PrimaryButton()).accessibilityIdentifier("echo-next")
            } else {
                Button { game.submit() } label: {
                    HStack(spacing:8) {
                        if game.phase == .answerPlayback { ProgressView().tint(.white) }
                        Text(game.phase == .answerPlayback ? "듣는 중" : "제출")
                    }.frame(minWidth:110)
                }.buttonStyle(PrimaryButton()).disabled(!game.canSubmit)
                    .opacity(game.canSubmit || game.phase == .answerPlayback ? 1 : 0.45)
                    .accessibilityIdentifier("echo-submit")
            }
        }
    }
    private func openTutorial() {
        continueAfterHelp = game.hasStarted
        game.suspendForTutorial(); help = true
    }
}

private struct EchoDragonCharacter: View {
    let phase: EchoIntervalPhase
    let noteOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var began = Date()
    private var imageName: String {
        switch phase {
        case .singing: return noteOn ? "echo-dragon-singing" : "echo-dragon-waiting"
        case .puzzled,.failed: return "echo-dragon-puzzled"
        case .happy,.completed: return "echo-dragon-happy"
        default: return "echo-dragon-waiting"
        }
    }
    private var description: String {
        switch phase {
        case .singing: return "드래곤이 두 음을 노래하고 있어요"
        case .answerPlayback: return "내가 입력한 두 음을 차례로 듣고 있어요"
        case .puzzled: return "음정이 달라서 드래곤이 고개를 갸웃해요. 다시 입력해 보세요"
        case .failed: return "세 번 틀려서 스테이지가 끝났어요"
        case .happy: return "같은 음정이에요. 드래곤이 기뻐해요"
        case .completed: return "10문제를 모두 맞혀서 스테이지를 클리어했어요"
        default: return "드래곤이 대답을 기다려요. 표시된 첫 음에서 같은 간격으로 연주하세요"
        }
    }
    var body: some View {
        TimelineView(.animation(minimumInterval:1.0/30,paused:reduceMotion)) { context in
            let elapsed=context.date.timeIntervalSince(began)
            let wave=reduceMotion ? 0 : sin(elapsed*(phase == .singing ? 10 : 2.2))
            let celebrating=phase == .happy || phase == .completed
            Image(imageName).resizable().scaledToFit()
                .scaleEffect(1 + wave*(phase == .singing ? 0.012 : 0.004),anchor:.bottom)
                .rotationEffect(.degrees(phase == .puzzled && !reduceMotion ? 2*sin(elapsed*3) : 0),anchor:.bottom)
                .offset(y:reduceMotion ? 0 : celebrating ? -abs(sin(min(elapsed,1.5)*7))*8*(elapsed<1.5 ? 1 : 0) : wave*2)
                .padding(.vertical,12)
        }.onChange(of:phase) { _, _ in began=Date() }
            .accessibilityElement(children:.ignore).accessibilityLabel(description)
            .accessibilityIdentifier("echo-dragon-character")
    }
}

private struct EchoDragonHearts: View {
    let remaining: Int
    var body: some View {
        HStack(spacing:9) {
            ForEach(0..<3,id:\.self) { i in
                ZStack {
                    if i<remaining { EchoHeart().fill(Color(red:0.88,green:0.34,blue:0.40)) }
                    else { EchoHeart().stroke(SolfegeTheme.muted.opacity(0.45),style:StrokeStyle(lineWidth:1.8,lineCap:.round,dash:[2.5,3])) }
                }.frame(width:27,height:25)
            }
        }.accessibilityElement(children:.ignore).accessibilityLabel("남은 하트 \(remaining)개")
    }
}

private struct EchoHeart: Shape {
    func path(in rect: CGRect) -> Path {
        var path=Path()
        func p(_ x: CGFloat,_ y: CGFloat) -> CGPoint { CGPoint(x:rect.minX+x*rect.width,y:rect.minY+y*rect.height) }
        path.move(to:p(0.5,0.94))
        path.addCurve(to:p(0.08,0.45),control1:p(0.4,0.83),control2:p(0.08,0.65))
        path.addCurve(to:p(0.5,0.22),control1:p(-0.04,0.08),control2:p(0.32,-0.03))
        path.addCurve(to:p(0.92,0.45),control1:p(0.68,-0.03),control2:p(1.04,0.08))
        path.addCurve(to:p(0.5,0.94),control1:p(0.92,0.65),control2:p(0.6,0.83))
        path.closeSubpath(); return path
    }
}

// Echo-only highlights keep the common piano and both other games unchanged.
// White overlays occupy the unobscured lower key area, never cover black keys.
struct EchoPianoSelection: View {
    let range: ClosedRange<Int>
    let selected: Set<Int>
    let playing: Int?
    var body: some View {
        Canvas { context,size in
            for key in PianoGeometry(range:range).keys where selected.contains(key.midi) || playing == key.midi {
                let full=CGRect(x:key.x*Double(size.width),y:0,width:key.width*Double(size.width),height:key.height*Double(size.height))
                let rect=key.black ? full.insetBy(dx:3,dy:3) : CGRect(x:full.minX+3,y:full.height*0.65,width:full.width-6,height:full.height*0.35-3)
                let path=Path(roundedRect:rect,cornerRadius:5)
                let color=playing == key.midi ? SolfegeTheme.green : SolfegeTheme.violet
                context.fill(path,with:.color(color.opacity(playing == key.midi ? 0.5 : 0.24)))
                context.stroke(path,with:.color(color),lineWidth:2)
            }
        }
    }
}
