import SwiftUI

struct ResultView: View {
    @ObservedObject var model: AppModel
    @State private var selectedAnnotation: String?
    @State private var showOriginal = false
    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    SectionCaption(eyebrow:"YOUR LISTENING, IN NOTES",title:title,subtitle:model.session?.attempt.question.title ?? "")
                    if model.session?.attempt.gradingMode == "demo" { DemoBadge() }
                    else { Text("AI가 제공하는 학습 참고용 평가입니다. 실제 필기와 정답 악보도 함께 확인해 주세요.").font(.footnote).foregroundStyle(.secondary) }
                    if let grading = model.session?.grading {
                        switch grading.status {
                        case "queued", "processing": pending(grading)
                        case "completed": completed(grading)
                        case "needs_review": messageCard("필기를 한 번 더 확인해 주세요",detail:grading.feedback?.summary ?? "인식이 불확실해 점수를 계산하지 않았어요.",icon:"pencil.and.outline")
                        case "failed":
                            messageCard("분석을 완료하지 못했어요",detail:grading.failure?.message ?? "결과를 확인할 수 없습니다.",icon:"exclamationmark.arrow.triangle.2.circlepath")
                            if grading.canRetry { Button("같은 답안으로 채점 재시도") { Task { await model.retryGrading() } }.buttonStyle(PrimaryButton()) }
                        default: messageCard("지원하지 않는 결과 상태예요",detail:grading.status,icon:"questionmark.circle")
                        }
                        comparison(grading).id("score-comparison")
                        if !grading.isPending {
                            if let feedback = grading.feedback {
                                Card { VStack(alignment:.leading,spacing:12) {
                                    Label("다음 연습을 위한 힌트",systemImage:"lightbulb").font(.headline)
                                    Text(feedback.summary).lineSpacing(5)
                                    ForEach(feedback.recommendations,id:\.self) { Text("• " + $0).font(.subheadline).foregroundStyle(.secondary) }
                                } }
                            }
                            if !grading.annotations.isEmpty {
                                Text("피드백을 누르면 해당 마디를 표시해요. 음표 순서는 쉼표를 포함하며, 표시는 마디 범위입니다.").font(.caption).foregroundStyle(.secondary)
                                ForEach(grading.annotations) { annotation in
                                    Button { withAnimation { selectedAnnotation = selectedAnnotation == annotation.id ? nil : annotation.id; scroll.scrollTo("score-comparison",anchor:.top) } } label: {
                                        HStack(alignment:.top,spacing:12) {
                                            Image(systemName:annotation.type == "recognition_uncertain" ? "questionmark.circle" : "music.note").foregroundStyle(annotationColor(annotation))
                                            VStack(alignment:.leading,spacing:5) {
                                                Text(annotation.categoryLabel + " · " + annotation.locationLabel).font(.caption.bold())
                                                Text(annotation.message).font(.subheadline).multilineTextAlignment(.leading)
                                            }
                                            Spacer(minLength:0)
                                        }.padding(12).background(selectedAnnotation == annotation.id ? annotationColor(annotation).opacity(0.08) : Color.clear).clipShape(RoundedRectangle(cornerRadius:10))
                                    }.buttonStyle(.plain)
                                }
                            }
                            Button { if let id = model.session?.attempt.question.id { Task { await model.choose(id) } } } label: { Label("새 응시로 다시 연습하기",systemImage:"arrow.clockwise") }.buttonStyle(PrimaryButton())
                        }
                    } else { messageCard("제출 결과를 확인해 주세요",detail:"새로고침으로 결과를 다시 불러올 수 있어요.",icon:"network") }
                    HStack {
                        Button("결과 새로고침") { Task { await model.refreshResult() } }.buttonStyle(.bordered)
                        Button("연습실로 돌아가기") { model.navigate(.home) }
                    }
                }.padding(24).frame(maxWidth:1100,alignment:.leading).frame(maxWidth:.infinity)
            }
            .task(id:model.pollGeneration) { await model.poll() }
            .sheet(isPresented:$showOriginal) {
                NavigationStack {
                    ScrollView { if let image = model.submittedImage { Image(uiImage:image).resizable().scaledToFit().padding() } }
                        .navigationTitle("제출 원본").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement:.confirmationAction) { Button("닫기") { showOriginal = false } } }
                }
            }
        }
    }
    private func comparison(_ grading: Grading) -> some View {
        VStack(alignment:.leading,spacing:12) {
            Label("정답 악보",systemImage:"music.note.list").font(.headline)
            if let image = model.correctScoreImage {
                Image(uiImage:image).resizable().scaledToFit().padding(.vertical,8).background(.white).clipShape(RoundedRectangle(cornerRadius:12))
            } else if let score = model.mainScore, model.session?.attempt.question.correctScore == nil {
                ScoreView(score:score).clipShape(RoundedRectangle(cornerRadius:12))
            } else { Text(model.correctScoreError ?? "정답 악보를 불러오는 중이에요.").font(.subheadline).foregroundStyle(.secondary) }
            Divider().padding(.vertical,4)
            HStack {
                Label("내 악보",systemImage:"pencil.tip").font(.headline)
                Spacer()
                Button("제출 원본 전체 보기") { showOriginal = true }.font(.caption).disabled(model.submittedImage == nil)
            }
            if let image = model.submittedImage, let layout = model.session?.attempt.question.sheetLayout {
                CompactAnswerView(image:image,layout:layout,annotation:grading.annotations.first(where: { $0.id == selectedAnnotation }))
                    .clipShape(RoundedRectangle(cornerRadius:12))
            } else { Text("제출 이미지를 불러오는 중이에요.").font(.subheadline).foregroundStyle(.secondary) }
        }
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
            VStack(alignment:.leading,spacing:8) { Text("AI 종합 평가").font(.subheadline).foregroundStyle(.secondary); HStack(alignment:.firstTextBaseline,spacing:4) { Text(g.score.map(String.init) ?? "—").font(.system(size:64,weight:.bold,design:.rounded)).foregroundStyle(SORITheme.violet); Text("/ 100").foregroundStyle(.secondary) } }
            Spacer()
            VStack(alignment:.leading,spacing:22) { accuracy("음정 평가",g.pitchAccuracy); accuracy("리듬 평가",g.rhythmAccuracy) }.frame(maxWidth:330)
        } }
    }
    private func accuracy(_ title:String,_ value:Double?) -> some View {
        VStack(alignment:.leading,spacing:8) { HStack { Text(title).font(.subheadline); Spacer(); Text(value.map { String(format:"%.1f%%",$0) } ?? "—").font(.subheadline.bold()) }; ProgressView(value:min(100,max(0,value ?? 0)),total:100).tint(SORITheme.violet) }
    }
    private func messageCard(_ title:String,detail:String,icon:String) -> some View {
        Card { VStack(alignment:.leading,spacing:16) { Label(title,systemImage:icon).font(.title3.bold()); Text(detail).font(.subheadline).foregroundStyle(.secondary).lineSpacing(5) } }
    }
}

func annotationColor(_ annotation: Annotation) -> Color {
    switch annotation.type {
    case "notation_suggestion": return .teal
    case "notation_error", "recognition_uncertain": return .orange
    default: return .red
    }
}
struct CompactAnswerView: View {
    let image: UIImage
    let layout: SheetLayout
    let annotation: Annotation?
    var body: some View {
        VStack(spacing:8) {
            ForEach(AnswerSystemCrop.strips(layout:layout)) { crop in
                if let source = image.cgImage,
                   let row = source.cropping(to:CGRect(x:0,y:CGFloat(crop.bounds.y)*CGFloat(source.height),width:CGFloat(source.width),height:CGFloat(crop.bounds.height)*CGFloat(source.height)).integral) {
                    Image(uiImage:UIImage(cgImage:row)).resizable().scaledToFit()
                        .overlay { GeometryReader { proxy in
                            if let annotation, let box = annotation.bbox, let projected = crop.project(box) {
                                RoundedRectangle(cornerRadius:5).stroke(annotationColor(annotation),lineWidth:2)
                                    .background(annotationColor(annotation).opacity(0.06))
                                    .frame(width:CGFloat(projected.width)*proxy.size.width,height:CGFloat(projected.height)*proxy.size.height)
                                    .position(x:CGFloat(projected.x+projected.width/2)*proxy.size.width,y:CGFloat(projected.y+projected.height/2)*proxy.size.height)
                                    .accessibilityLabel(annotation.message)
                            }
                        } }
                }
            }
        }.background(.white)
    }
}
