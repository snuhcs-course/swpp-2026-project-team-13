import SwiftUI

struct ResultView: View {
    @ObservedObject var model: AppModel
    @State private var tab = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                SectionCaption(eyebrow:"YOUR LISTENING, IN NOTES", title: title, subtitle: model.session?.attempt.question.title ?? "")
                if model.session?.attempt.gradingMode == "demo" { DemoBadge() }
                if let grading = model.session?.grading {
                    switch grading.status {
                    case "queued", "processing": pending(grading)
                    case "completed": completed(grading)
                    case "needs_review": messageCard("필기를 한 번 더 확인해 주세요", detail: grading.feedback?.summary ?? "필기 인식이 불확실해 점수를 계산하지 않았어요.", icon:"pencil.and.outline")
                    case "failed":
                        messageCard("분석을 완료하지 못했어요", detail: grading.failure?.message ?? "서버에서 결과를 확인할 수 없습니다.", icon:"exclamationmark.arrow.triangle.2.circlepath")
                        if grading.canRetry { Button("같은 답안으로 채점 재시도") { Task { await model.retryGrading() } }.buttonStyle(PrimaryButton()) }
                    default: messageCard("지원하지 않는 결과 상태예요", detail:"상태: \(grading.status). 앱과 서버 버전을 확인해 주세요.",icon:"questionmark.circle")
                    }
                    if !grading.isPending {
                        if let feedback = grading.feedback {
                            Card { VStack(alignment:.leading,spacing:12) { Label("다음 연습을 위한 힌트",systemImage:"lightbulb").font(.headline); Text(feedback.summary).lineSpacing(5); ForEach(feedback.recommendations,id:\.self) { Text("• " + $0).font(.subheadline).foregroundStyle(.secondary) } } }
                        }
                        Picker("악보 보기", selection:$tab) { Text("제출한 답안").tag(0); Text("정답 악보").tag(1) }.pickerStyle(.segmented)
                        if tab == 0 {
                            if let image = model.submittedImage { AnnotatedAnswerView(image:image,annotations:grading.annotations).clipShape(RoundedRectangle(cornerRadius:16)) }
                            else { messageCard("제출 이미지가 아직 준비되지 않았어요",detail:"결과 새로고침으로 이미지를 다시 불러올 수 있어요.",icon:"photo") }
                            ForEach(grading.annotations) { a in
                                Label { VStack(alignment:.leading,spacing:5) { Text(a.measure.map { "\($0)마디" } ?? "위치 확인 필요").font(.caption.bold()); Text(a.message).font(.subheadline) } } icon: { Image(systemName:a.type == "recognition_uncertain" ? "questionmark.circle" : "pencil.tip.crop.circle").foregroundStyle(a.type == "recognition_uncertain" ? .orange : .red) }
                            }
                        } else if let score = model.mainScore { ScoreView(score:score).clipShape(RoundedRectangle(cornerRadius:16)) }
                        Button { if let id = model.session?.attempt.question.id { Task { await model.choose(id) } } } label: { Label("새 응시로 다시 연습하기",systemImage:"arrow.clockwise") }.buttonStyle(PrimaryButton())
                    }
                } else { messageCard("제출 결과를 확인해 주세요", detail:"결과를 불러오는 중 오류가 있었다면 새로고침할 수 있어요.",icon:"network") }
                HStack {
                    Button("결과 새로고침") { Task { await model.refreshResult() } }.buttonStyle(.bordered)
                    Button("연습실로 돌아가기") { model.navigate(.home) }
                }
            }.padding(32).frame(maxWidth:1100,alignment:.leading).frame(maxWidth:.infinity)
        }
        .task(id:model.pollGeneration) { await model.poll() }
    }
    private var title: String {
        switch model.session?.grading?.status {
        case "completed": return "오늘의 연습 결과"
        case "needs_review": return "필기 확인이 필요해요"
        case "failed": return "분석이 잠시 멈췄어요"
        default: return "답안을 살펴보고 있어요"
        }
    }
    private func pending(_ g: Grading) -> some View {
        Card { VStack(alignment:.leading,spacing:20) {
            HStack { ProgressView(); Text(g.status == "queued" ? "분석을 기다리고 있어요" : stage(g.stage)).font(.title3.bold()) }
            Text("답안은 안전하게 제출되었어요. 이 화면을 나가도 분석은 계속됩니다.").font(.subheadline).foregroundStyle(.secondary)
            TimelineView(.periodic(from:.now,by:1)) { _ in if let start = model.waitingSince, Date().timeIntervalSince(start) >= 60 { Text("분석이 계속되고 있어요. 연습 기록에서 나중에 다시 확인할 수 있어요.").font(.subheadline).foregroundStyle(SORITheme.violet) } }
        } }
    }
    private func stage(_ value:String) -> String { ["pending":"분석 대기 중","recognizing":"필기를 읽는 중","grading":"음정과 리듬을 확인하는 중","feedback":"피드백을 준비하는 중"][value] ?? "분석 진행 중" }
    private func completed(_ g: Grading) -> some View {
        Card { HStack(alignment:.center,spacing:32) {
            VStack(alignment:.leading,spacing:8) { Text("종합 점수").font(.subheadline).foregroundStyle(.secondary); HStack(alignment:.firstTextBaseline,spacing:4) { Text(g.score.map(String.init) ?? "—").font(.system(size:64,weight:.bold,design:.rounded)).foregroundStyle(SORITheme.violet); Text("/ 100").foregroundStyle(.secondary) } }
            Spacer()
            VStack(alignment:.leading,spacing:22) { accuracy("음정 정확도",g.pitchAccuracy); accuracy("리듬 정확도",g.rhythmAccuracy) }.frame(maxWidth:330)
        } }
    }
    private func accuracy(_ title:String,_ value:Double?) -> some View {
        VStack(alignment:.leading,spacing:8) { HStack { Text(title).font(.subheadline); Spacer(); Text(value.map { String(format:"%.1f%%",$0) } ?? "—").font(.subheadline.bold()) }; ProgressView(value:min(100,max(0,value ?? 0)),total:100).tint(SORITheme.violet) }
    }
    private func messageCard(_ title:String,detail:String,icon:String) -> some View {
        Card { VStack(alignment:.leading,spacing:16) { Label(title,systemImage:icon).font(.title3.bold()); Text(detail).font(.subheadline).foregroundStyle(.secondary).lineSpacing(5) } }
    }
}
struct AnnotatedAnswerView: View {
    let image:UIImage; let annotations:[Annotation]
    var body: some View {
        Image(uiImage:image).resizable().aspectRatio(2660.0/1692,contentMode:.fit)
            .overlay { GeometryReader { proxy in
                ForEach(annotations) { a in if let b=a.bbox, b.isValid {
                    RoundedRectangle(cornerRadius:5).stroke(a.type == "recognition_uncertain" ? Color.orange : .red,lineWidth:2)
                        .background((a.type == "recognition_uncertain" ? Color.orange : .red).opacity(0.07))
                        .frame(width:b.width*proxy.size.width,height:b.height*proxy.size.height)
                        .position(x:(b.x+b.width/2)*proxy.size.width,y:(b.y+b.height/2)*proxy.size.height)
                        .accessibilityLabel(a.message)
                } }
            } }
    }
}
