import SwiftUI

private struct PracticeMeasureSelection: Identifiable { let id: Int }

struct ResultView: View {
    @ObservedObject var model: AppModel
    @State private var selectedAnnotation: String?
    @State private var showOriginal = false
    @State private var selectedMeasure: PracticeMeasureSelection?
    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    SectionCaption(eyebrow:"YOUR LISTENING, IN NOTES",title:title,subtitle:model.session?.attempt.question.title ?? "")
                    if model.demo { DemoBadge() }
                    if model.session?.attempt.studyMode == .practice {
                        practiceResult
                    } else if let grading = model.session?.grading {
                        Text("AI가 제공하는 학습 참고용 평가입니다. 실제 필기와 정답 악보도 함께 확인해 주세요.").font(.footnote).foregroundStyle(.secondary)
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
                            Button { if let id = model.session?.attempt.question.id { Task { await model.choose(id,mode:.exam) } } } label: { Label("새 Exam 시작하기",systemImage:"arrow.clockwise") }.buttonStyle(PrimaryButton())
                        }
                    } else { messageCard("제출 결과를 확인해 주세요",detail:"새로고침으로 결과를 다시 불러올 수 있어요.",icon:"network") }
                    HStack {
                        Button("결과 새로고침") { Task { await model.refreshResult() } }.buttonStyle(.bordered)
                        Button(model.session?.attempt.question.collection == "classical" ? "클래식으로 돌아가기" : (model.session?.attempt.studyMode.title ?? "Practice") + "로 돌아가기") { model.navigate(model.resultLibraryScreen) }
                    }
                }.padding(24).frame(maxWidth:1100,alignment:.leading).frame(maxWidth:.infinity)
            }
            .task(id:model.pollGeneration) { await model.poll() }
            .onChange(of:model.session?.id) { _, _ in selectedAnnotation = nil; selectedMeasure = nil }
            .popover(item:$selectedMeasure) { selection in
                VStack(alignment:.leading,spacing:16) {
                    Text("\(selection.id)마디").font(.headline)
                    Text("여러 항목을 함께 선택할 수 있어요.").font(.caption).foregroundStyle(.secondary)
                    ForEach(SelfAssessmentErrorType.allCases) { type in
                        let checked = model.practiceErrors.first(where: { $0.measure == selection.id })?.types.contains(type.rawValue) == true
                        Button { model.togglePracticeError(measure:selection.id,type:type) } label: {
                            HStack { Text(type.title); Spacer(); Image(systemName:checked ? "checkmark.square.fill" : "square") }
                        }.buttonStyle(.bordered).accessibilityIdentifier("self-assess-type-\(type.rawValue)")
                    }
                    Button("닫기") { selectedMeasure = nil }.frame(maxWidth:.infinity)
                }.padding(20).frame(width:260).disabled(model.busy || model.session?.selfAssessmentSave != nil || model.practiceHasConflict)
                    .presentationCompactAdaptation(.popover)
            }
            .sheet(isPresented:$showOriginal) {
                NavigationStack {
                    ScrollView { if let image = model.submittedImage { Image(uiImage:image).resizable().scaledToFit().padding() } }
                        .navigationTitle("제출 원본").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement:.confirmationAction) { Button("닫기") { showOriginal = false } } }
                }
            }
        }
    }
    private var practiceResult: some View {
        VStack(alignment:.leading,spacing:20) {
            Text("정답과 내 악보를 비교하고, 내 악보에서 틀린 마디를 눌러 주세요.").font(.subheadline).foregroundStyle(.secondary)
            if let review = model.session?.selfAssessment {
                Card { VStack(alignment:.leading,spacing:10) {
                    Label(review.isCompleted && model.session?.practiceEdits == nil && model.session?.selfAssessmentSave == nil ? "자기채점 완료" : "마디별 자기채점",systemImage:"checkmark.square").font(.headline)
                    Text("오류를 표시한 마디 \(model.practiceErrors.count) / \(model.session?.attempt.question.measureCount ?? 8)").font(.subheadline)
                    if model.session?.practiceEdits != nil { Text("수정한 표시는 이 iPad에 보관되어 있어요. 저장 버튼으로 기록을 반영해 주세요.").font(.caption).foregroundStyle(.secondary) }
                } }
            }
            comparison(nil).id("score-comparison")
            if model.session?.selfAssessmentSave != nil {
                messageCard("저장 응답을 확인하지 못했어요",detail:"입력한 표시는 보관되어 있어요. 같은 내용으로 저장을 복구해 주세요.",icon:"arrow.clockwise")
                Button("자기채점 저장 복구") { Task { await model.savePracticeAssessment(completed:model.session?.selfAssessmentSave?.request.completed ?? false) } }.buttonStyle(PrimaryButton())
            } else if model.practiceHasConflict {
                messageCard("채점 기록이 변경됐어요",detail:"현재 iPad의 표시를 유지하거나 서버에 저장된 표시를 적용할 수 있어요.",icon:"arrow.triangle.2.circlepath")
                HStack {
                    Button("서버 표시 적용") { model.useServerPracticeAssessment() }.buttonStyle(.bordered)
                    Button("내 표시를 유지하고 다시 검토") { model.keepLocalPracticeEdits() }.buttonStyle(.bordered)
                }
            } else if let review = model.session?.selfAssessment {
                Text("표시하지 않은 마디는 오류를 발견하지 않은 마디로 저장돼요. 음정·리듬·기타는 중복 선택할 수 있어요.").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("임시 저장") { Task { await model.savePracticeAssessment(completed:false) } }.buttonStyle(.bordered)
                        .disabled(model.busy || model.session?.practiceEdits == nil || !model.practiceComparisonReady)
                    Button(model.practiceErrors.isEmpty ? "오류 표시 없이 채점 완료" : "채점 완료") { Task { await model.savePracticeAssessment(completed:true) } }.buttonStyle(PrimaryButton())
                        .disabled(model.busy || !model.practiceComparisonReady || (review.isCompleted && model.session?.practiceEdits == nil))
                }
                Button { if let id = model.session?.attempt.question.id { Task { await model.choose(id,mode:.practice) } } } label: { Label("새 Practice 시작하기",systemImage:"arrow.clockwise") }.buttonStyle(.bordered)
            } else { Text("자기채점 기록을 불러오지 못했어요. 결과 새로고침으로 다시 시도해 주세요.").font(.subheadline) }
        }
    }
    private func comparison(_ grading: Grading?) -> some View {
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
                CompactAnswerView(image:image,layout:layout,annotation:grading?.annotations.first(where: { $0.id == selectedAnnotation }),
                    measureErrors:model.practiceErrors,reviewMode:model.session?.attempt.studyMode == .practice,
                    selectedMeasure:selectedMeasure?.id,
                    onMeasureTap:model.session?.attempt.studyMode == .practice && model.session?.selfAssessment != nil && model.session?.selfAssessmentSave == nil && !model.practiceHasConflict ? { measure in selectedMeasure = PracticeMeasureSelection(id:measure) } : nil)
                    .clipShape(RoundedRectangle(cornerRadius:12))
            } else { Text("제출 이미지를 불러오는 중이에요.").font(.subheadline).foregroundStyle(.secondary) }
        }
    }
    private var title: String {
        if model.session?.attempt.studyMode == .practice { return "Practice · 정답과 비교하기" }
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
            TimelineView(.periodic(from:.now,by:1)) { _ in if let start = model.waitingSince, Date().timeIntervalSince(start) >= 60 { Text("분석이 계속되고 있어요. 연습 기록에서 나중에 다시 확인할 수 있어요.").font(.subheadline).foregroundStyle(SolfegeTheme.violet) } }
        } }
    }
    private func stage(_ value:String) -> String { ["pending":"분석 대기 중","recognizing":"필기를 읽는 중","grading":"음정과 리듬을 확인하는 중","feedback":"피드백을 준비하는 중"][value] ?? "분석 진행 중" }
    private func completed(_ g: Grading) -> some View {
        Card { HStack(alignment:.center,spacing:32) {
            VStack(alignment:.leading,spacing:8) { Text("AI 종합 평가").font(.subheadline).foregroundStyle(.secondary); HStack(alignment:.firstTextBaseline,spacing:4) { Text(g.score.map(String.init) ?? "—").font(.system(size:64,weight:.bold,design:.rounded)).foregroundStyle(SolfegeTheme.violet); Text("/ 100").foregroundStyle(.secondary) } }
            Spacer()
            VStack(alignment:.leading,spacing:22) { accuracy("음정 평가",g.pitchAccuracy); accuracy("리듬 평가",g.rhythmAccuracy) }.frame(maxWidth:330)
        } }
    }
    private func accuracy(_ title:String,_ value:Double?) -> some View {
        VStack(alignment:.leading,spacing:8) { HStack { Text(title).font(.subheadline); Spacer(); Text(value.map { String(format:"%.1f%%",$0) } ?? "—").font(.subheadline.bold()) }; ProgressView(value:min(100,max(0,value ?? 0)),total:100).tint(SolfegeTheme.violet) }
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
    var measureErrors: [MeasureError] = []
    var reviewMode = false
    var selectedMeasure: Int? = nil
    var onMeasureTap: ((Int) -> Void)? = nil
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
                            if reviewMode {
                                ForEach(crop.measureRegions(layout:layout)) { region in
                                    let error = measureErrors.first(where: { $0.measure == region.id })
                                    let color: Color = selectedMeasure == region.id ? SolfegeTheme.violet : error == nil ? .gray : .red
                                    Button { onMeasureTap?(region.id) } label: {
                                        RoundedRectangle(cornerRadius:5).fill(color.opacity(error == nil ? 0.02 : 0.07))
                                            .overlay(RoundedRectangle(cornerRadius:5).stroke(color.opacity(error == nil ? 0.35 : 0.85),lineWidth:error == nil ? 1 : 2))
                                            .overlay(alignment:.topLeading) {
                                                Text("\(region.id)" + (error.map { " · " + $0.label } ?? ""))
                                                    .font(.caption2.weight(.semibold)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.65)
                                                    .padding(4).background(.white.opacity(0.9),in:RoundedRectangle(cornerRadius:4)).padding(3)
                                            }
                                    }.buttonStyle(.plain).disabled(onMeasureTap == nil)
                                        .frame(width:CGFloat(region.bounds.width)*proxy.size.width,height:CGFloat(region.bounds.height)*proxy.size.height)
                                        .position(x:CGFloat(region.bounds.x+region.bounds.width/2)*proxy.size.width,y:CGFloat(region.bounds.y+region.bounds.height/2)*proxy.size.height)
                                        .accessibilityLabel("\(region.id)마디 · " + (error?.label ?? "오류 미표시"))
                                        .accessibilityIdentifier("self-assess-measure-\(region.id)")
                                }
                            }
                        } }
                }
            }
        }.background(.white)
    }
}
