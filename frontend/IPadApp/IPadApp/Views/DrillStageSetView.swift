import SwiftUI

struct DrillSetProgress: View {
    let results: [DrillRoundResult?]
    let index: Int
    var body: some View {
        HStack(spacing:7) {
            ForEach(results.indices,id:\.self) { i in
                Capsule().fill(results[i].map { $0.correct ? SolfegeTheme.green : SolfegeTheme.danger } ?? SolfegeTheme.violet.opacity(i==index ? 0.35 : 0.12))
                    .frame(height:7)
                    .overlay { if let result=results[i] {
                        Image(systemName:result.correct ? "checkmark" : "minus").font(.system(size:6,weight:.bold)).foregroundStyle(.white)
                    } }
                    .accessibilityLabel("\(i+1)번 " + (results[i].map { $0.correct ? "정답" : "다시 연습" } ?? (i==index ? "진행 중" : "아직 안 푼 문제")))
            }
            Text("\(min(index+1,results.count))/\(results.count)").font(.caption.monospacedDigit()).padding(.leading,7)
        }.accessibilityElement(children:.combine)
    }
}

struct DrillStageSetView: View {
    let stage: DrillStage
    let connection: RhythmConnection?
    let mastered: () -> Void
    let exit: () -> Void
    @StateObject private var session: DrillStageSession
    @Environment(\.scenePhase) private var phase
    init(stage: DrillStage,set: DrillStageSet,version: String,root: URL,connection: RhythmConnection?,mastered: @escaping () -> Void,exit: @escaping () -> Void) {
        self.stage=stage; self.connection=connection; self.mastered=mastered; self.exit=exit
        _session=StateObject(wrappedValue:DrillStageSession(set:set,version:version,root:root))
    }
    var body: some View {
        ZStack {
            if session.error != nil { VStack(spacing:20) { Text(session.error ?? ""); Button("계단으로",action:exit) } }
            else if session.summary { summary }
            else { question.id(session.attempt.index) }
        }.onChange(of:session.summary) { _, value in if value && session.attempt.mastered { mastered() } }
            .onAppear { if session.summary && session.attempt.mastered { mastered() } }
            .onChange(of:phase) { _, value in session.active(value == .active) }
            .onDisappear { session.echoAudio.stop() }
    }
    private var context: DrillStageContext {
        DrillStageContext(stage:stage,question:session.round,index:session.attempt.index,results:session.attempt.results,
            report:session.report,next:session.next,exit:exit)
    }
    @ViewBuilder private var question: some View {
        switch stage.game {
        case .memoryRun: MelodyRunView(connection:connection,stage:context)
        case .rhythmPuzzle: RhythmPuzzleView(connection:connection,stage:context)
        case .echoDragon: EchoFollowView(stage:context,audio:session.echoAudio)
        }
    }
    private var summary: some View {
        VStack(spacing:28) {
            HStack { Text(stage.game.title).font(.title2.bold()); StageChip(stage:stage); Spacer(); Button(action:exit) { Image(systemName:"xmark").frame(width:44,height:44) }.accessibilityLabel("계단으로") }
            DrillSetProgress(results:session.attempt.results,index:session.attempt.index)
            Spacer()
            Text(session.attempt.mastered ? "스테이지 클리어!" : "끝까지 풀었어요").font(.largeTitle.bold())
            Text("\(session.attempt.results.filter { $0?.correct == true }.count)/\(session.attempt.results.count)문제 정답").font(.title3).foregroundStyle(SolfegeTheme.muted)
            if !session.attempt.mastered { Text("붉은 칸의 문제를 다시 연습해 보세요.").foregroundStyle(SolfegeTheme.muted) }
            Spacer()
            HStack(spacing:16) { Button("다시 도전") { session.restart() }.buttonStyle(.bordered); Button("계단으로",action:exit).buttonStyle(PrimaryButton()) }
        }.padding(28).background(SolfegeTheme.background)
    }
}
