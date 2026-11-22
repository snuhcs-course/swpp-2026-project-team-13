import SwiftUI
import AVFoundation

private struct ExamReplayControlAnchors: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) { value.append(contentsOf:nextValue()) }
}
private struct ExamReplayControlFrames: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value.append(contentsOf:nextValue()) }
}

/// Two scores on the left, one compact score/coaching card on the right.
struct ExamResultView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var audio = PracticeReviewPlayback()
    @State private var playbackTask: Task<Void,Never>?
    @State private var selectedAnnotation: String?
    @State private var showingFeedback = false
    @State private var replayControlFrames: [CGRect] = []

    private var grading: Grading? { model.session?.grading }
    private var reference: (UIImage,PracticeReviewGeometry?)? {
        guard let q = model.session?.attempt.question else { return nil }
        if model.demo, let local = PracticeReferenceAssets.reference(for:q) { return (local.image,local.geometry) }
        return model.correctScoreImage.map { ($0,q.correctScore?.geometry) }
    }
    private var selectedMeasure: Int? { grading?.annotations.first { $0.id == selectedAnnotation }?.measure }
    private var marks: [ReferenceAnnotation] { (grading?.referenceAnnotations ?? []).filter(\.isValid) }
    private var coachingText: String {
        if let coach = grading?.feedback?.coach {
            return [coach.headline,coach.detail].filter { !$0.isEmpty }.joined(separator:"\n")
        }
        // Older results remain readable without exposing a long recommendations list.
        return grading?.feedback?.summary ?? ""
    }
    var body: some View {
        GeometryReader { proxy in
            VStack(spacing:20) {
                header
                if proxy.size.width >= 840 && !dynamicTypeSize.isAccessibilitySize {
                    HStack(alignment:.top,spacing:24) {
                        comparison.frame(maxWidth:.infinity,maxHeight:.infinity)
                        resultCard.frame(width:min(320,proxy.size.width*0.28))
                    }.frame(maxHeight:.infinity)
                } else {
                    ScrollView { VStack(spacing:20) { comparison.frame(height:460); resultCard } }
                }
            }.padding(24)
        }
        .background(SolfegeTheme.background)
        .overlayPreferenceValue(ExamReplayControlAnchors.self) { anchors in
            GeometryReader { proxy in
                Color.clear.preference(key:ExamReplayControlFrames.self,value:anchors.map { proxy[$0] })
                    .allowsHitTesting(false)
            }
        }
        .onPreferenceChange(ExamReplayControlFrames.self) { replayControlFrames = $0 }
        .coordinateSpace(name:"exam-review-surface")
        .contentShape(Rectangle())
        .simultaneousGesture(SpatialTapGesture(coordinateSpace:.named("exam-review-surface")).onEnded { event in
            // Replay controls perform their own play/stop action. A parent tap
            // must not cancel the clip that a reference measure just started.
            guard audio.isPlaying || playbackTask != nil,
                  !replayControlFrames.contains(where:{ $0.contains(event.location) }) else { return }
            stop()
        })
        .task(id:model.pollGeneration) { await model.poll() }
        .onChange(of:model.session?.id) { _,_ in stop(release:true); selectedAnnotation = nil }
        .onChange(of:scenePhase) { _,phase in if phase != .active { stop(release:true) } }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.interruptionNotification).receive(on:RunLoop.main)) { _ in stop(release:true) }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.mediaServicesWereResetNotification).receive(on:RunLoop.main)) { _ in stop(release:true) }
        .onReceive(NotificationCenter.default.publisher(for:.AVAudioEngineConfigurationChange).receive(on:RunLoop.main)) { audio.configurationChanged($0) }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.routeChangeNotification).receive(on:RunLoop.main)) { notification in
            if let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               AVAudioSession.RouteChangeReason(rawValue:raw) == .oldDeviceUnavailable { stop(release:true) }
        }
        .onDisappear { stop(release:true) }
        .accessibilityIdentifier("exam-review-screen")
    }
    private var header: some View {
        ZStack {
            Text("시험 결과").font(.system(size:22,weight:.bold)).foregroundStyle(SolfegeTheme.ink)
            HStack {
                Button { stop(release:true); model.navigate(.main) } label: { Label("홈",systemImage:"chevron.left") }
                    .accessibilityIdentifier("result-leave")
                Spacer()
                if model.demo { DemoBadge() }
            }
        }.frame(height:40)
    }
    private var comparison: some View {
        VStack(spacing:8) {
            HStack {
                Text("정답 악보").font(.subheadline.weight(.semibold))
                Spacer(minLength:8)
                if reference?.1?.isValid == true { Text("마디를 눌러 재생").font(.caption).foregroundStyle(SolfegeTheme.muted) }
                Button {
                    if audio.isPlaying || playbackTask != nil { stop() } else { play() }
                } label: {
                    let playing = audio.isPlaying || playbackTask != nil
                    Label(playing ? "정지" : "전체 다시듣기",systemImage:playing ? "stop.fill" : "arrow.clockwise").font(.subheadline)
                }.buttonStyle(.bordered).disabled(model.mainScore == nil)
                    .accessibilityIdentifier("exam-review-replay")
                    .anchorPreference(key:ExamReplayControlAnchors.self,value:.bounds) { [$0] }
            }
            referenceScore.frame(maxHeight:.infinity)
            Divider().padding(.vertical,6)
            HStack { Text("내 악보").font(.subheadline.weight(.semibold)); Spacer() }
            submittedScore.frame(maxHeight:.infinity)
        }.padding(20).foregroundStyle(SolfegeTheme.ink)
            .background(.white,in:RoundedRectangle(cornerRadius:18))
    }
    @ViewBuilder private var referenceScore: some View {
        if let (image,geometry) = reference {
            if let geometry, geometry.isValid {
                ExamScoreImage(image:image,geometry:geometry,marks:marks,selectedMeasure:audio.measure,selectedAnnotation:$selectedAnnotation,onMeasureTap:{ play(measure:$0) },onAnnotationTap:{ stop() })
            } else { Image(uiImage:image).resizable().scaledToFit() }
        } else if model.session?.attempt.question.correctScore == nil, let score = model.mainScore {
            ScoreView(score:score)
        } else { loadingScore(model.correctScoreError) }
    }
    @ViewBuilder private var submittedScore: some View {
        if let image = model.submittedImage, let sheet = model.session?.attempt.question.sheetLayout {
            // Preserve the student's original handwriting; only crop the whitespace.
            ExamScoreImage(image:image,geometry:PracticeReviewGeometry(sheet:sheet),marks:[],selectedMeasure:selectedMeasure,selectedAnnotation:$selectedAnnotation,onMeasureTap:nil,onAnnotationTap:{ stop() })
        } else { loadingScore(nil) }
    }
    private func loadingScore(_ message: String?) -> some View {
        VStack(spacing:10) {
            if let message { Text(message).font(.caption); Button("다시 불러오기") { Task { await model.refreshResult() } } }
            else { ProgressView() }
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private var resultCard: some View {
        VStack(alignment:.leading,spacing:22) {
            if let grading {
                switch grading.status {
                case "completed":
                    HStack(alignment:.center,spacing:12) {
                        HStack(alignment:.firstTextBaseline,spacing:4) {
                            Text(grading.score.map(String.init) ?? "—").font(.system(size:54,weight:.bold,design:.rounded)).monospacedDigit()
                            Text("점").font(.headline)
                        }
                        Spacer(minLength:0)
                        if let change = grading.ratingChange {
                            VStack(alignment:.trailing,spacing:6) {
                                Text("레이팅").font(.caption).foregroundStyle(SolfegeTheme.muted)
                                Text(String(format:"%.1f",change.after)).font(.headline).monospacedDigit()
                                Text(String(format:"%+.1f",change.delta)).font(.subheadline.weight(.semibold))
                                    .foregroundStyle(change.delta >= 0 ? SolfegeTheme.green : SolfegeTheme.danger)
                            }.accessibilityIdentifier("exam-rating-change")
                        }
                    }
                    Divider()
                    VStack(alignment:.leading,spacing:10) {
                        Text("AI 피드백").font(.caption.weight(.semibold)).foregroundStyle(SolfegeTheme.violet)
                        if !coachingText.isEmpty {
                            Button { showingFeedback = true } label: {
                                Text(coachingText).font(.system(size:16)).lineSpacing(5).lineLimit(3)
                                    .multilineTextAlignment(.leading).frame(maxWidth:.infinity,alignment:.leading)
                            }.buttonStyle(.plain).accessibilityLabel(coachingText)
                                .popover(isPresented:$showingFeedback) { Text(coachingText).font(.body).padding(20).frame(maxWidth:340).presentationCompactAdaptation(.popover) }
                        }
                        FeedbackRatingButton(model:model,grading:grading)
                    }
                case "queued", "processing":
                    Text(grading.stage == "feedback" ? "피드백을 정리하고 있어요" : "답안을 살펴보고 있어요").font(.headline)
                    Text("채점이 끝나면 새 레이팅에 맞춰 문제를 추천해요.").font(.subheadline).foregroundStyle(SolfegeTheme.muted)
                case "failed":
                    Text("채점을 완료하지 못했어요").font(.headline)
                    Text(grading.failure?.message ?? "결과를 다시 확인해 주세요.").font(.subheadline)
                default:
                    Text(grading.feedback?.summary ?? "결과를 다시 확인해 주세요.").font(.subheadline)
                }
            } else {
                Text("결과를 불러오지 못했어요").font(.headline)
                Button("다시 불러오기") { Task { await model.refreshResult() } }.buttonStyle(.bordered)
            }
            nextAction.padding(.top,12)
        }.padding(24).foregroundStyle(SolfegeTheme.ink)
            .frame(maxWidth:.infinity,alignment:.leading)
            .background(SolfegeTheme.soft,in:RoundedRectangle(cornerRadius:18))
    }
    @ViewBuilder private var nextAction: some View {
        if grading?.canRetry == true {
            Button { stop(release:true); Task { await model.retryGrading() } } label: {
                Text("채점 다시 시도").frame(maxWidth:.infinity)
            }.buttonStyle(ExamResultActionStyle()).disabled(model.busy)
                .accessibilityIdentifier("exam-retry-grading")
        } else {
            Button {
                guard model.canChooseNextExam, !model.busy else { return }
                stop(release:true); Task { await model.startRecommendedExam() }
            } label: {
                HStack(spacing:8) {
                    if grading?.isPending == true {
                        ProgressView().controlSize(.small).tint(SolfegeTheme.muted)
                            .accessibilityHidden(true)
                    }
                    Text(grading?.isPending == true ? "채점 중" : model.session?.attempt.levelTestStage != nil ? "레벨 테스트로 돌아가기" : "다음 시험 고르기")
                }.frame(maxWidth:.infinity)
            }.buttonStyle(ExamResultActionStyle()).disabled(model.busy || !model.canChooseNextExam)
                .accessibilityHint(grading?.isPending == true ? "채점과 레이팅 반영이 끝나면 새 시험을 고를 수 있어요." : "")
                .accessibilityIdentifier("next-exam")
        }
    }
    private func play(measure: Int? = nil) {
        guard let score = model.mainScore, let attempt = model.session?.attempt, scenePhase == .active else { return }
        let range = measure.map { PracticeReviewRange(from:$0,through:$0) } ?? .full
        let voice = model.selectedVoice
        playbackTask?.cancel()
        playbackTask = Task {
            defer { if !Task.isCancelled { playbackTask = nil } }
            guard !Task.isCancelled, model.session?.id == attempt.id, model.screen == .result else { return }
            do { try await audio.play(score:score,range:range,bpm:attempt.playbackPlan.tempoBpm,voice:voice) }
            catch is CancellationError { }
            catch { audio.shutdown(); model.error = error.localizedDescription }
        }
    }
    private func stop(release: Bool = false) {
        playbackTask?.cancel(); playbackTask = nil
        if release { audio.shutdown() } else { audio.stop() }
    }
}

private struct ExamResultActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size:16,weight:.semibold))
            .padding(.horizontal,24).padding(.vertical,16)
            .foregroundStyle(isEnabled ? Color.white : SolfegeTheme.muted)
            .background(isEnabled ? SolfegeTheme.violet.opacity(configuration.isPressed ? 0.7 : 1) : Color.gray.opacity(0.16),in:RoundedRectangle(cornerRadius:12))
    }
}

private struct ExamScoreImage: View {
    let image: UIImage
    let geometry: PracticeReviewGeometry
    let marks: [ReferenceAnnotation]
    let selectedMeasure: Int?
    @Binding var selectedAnnotation: String?
    let onMeasureTap: ((Int) -> Void)?
    let onAnnotationTap: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let strips = geometry.strips
            let total = strips.reduce(0.0) { $0+$1.bounds.height*Double(geometry.logicalHeight) }
            let width = max(0,min(Double(proxy.size.width),max(0,Double(proxy.size.height)-5)/max(1,total)*Double(geometry.logicalWidth)))
            VStack(spacing:5) {
                ForEach(strips) { crop in
                    if let source = image.cgImage, let row = source.cropping(to:CGRect(x:0,y:CGFloat(crop.bounds.y)*CGFloat(source.height),width:CGFloat(source.width),height:CGFloat(crop.bounds.height)*CGFloat(source.height)).integral) {
                        Image(uiImage:UIImage(cgImage:row)).resizable()
                            .frame(width:CGFloat(width),height:CGFloat(width*crop.bounds.height*Double(geometry.logicalHeight)/Double(geometry.logicalWidth)))
                            .overlay { overlay(crop:crop) }
                    }
                }
            }.position(x:proxy.size.width/2,y:proxy.size.height/2)
        }
    }
    private func overlay(crop: AnswerSystemCrop) -> some View {
        GeometryReader { proxy in
            let regions = crop.measureRegions(logicalWidth:geometry.logicalWidth,systems:geometry.systems)
            ForEach(regions) { region in
                Button { onMeasureTap?(region.id) } label: {
                    Rectangle().fill(SolfegeTheme.violet.opacity(selectedMeasure == region.id ? 0.07 : 0.001))
                }.buttonStyle(.plain).disabled(onMeasureTap == nil)
                    .anchorPreference(key:ExamReplayControlAnchors.self,value:.bounds) { onMeasureTap == nil ? [] : [$0] }
                    .frame(width:CGFloat(region.bounds.width)*proxy.size.width,height:proxy.size.height)
                    .position(x:CGFloat(region.bounds.x+region.bounds.width/2)*proxy.size.width,y:proxy.size.height/2)
                    .accessibilityLabel("\(region.id)마디 재생").accessibilityIdentifier("reference-measure-\(region.id)")
            }
            ForEach(marks.filter { mark in regions.contains { $0.id == mark.measure } }) { mark in
                markView(mark,crop:crop,size:proxy.size)
            }
        }
    }
    @ViewBuilder private func markView(_ mark: ReferenceAnnotation,crop: AnswerSystemCrop,size: CGSize) -> some View {
        if let box = crop.project(mark.bbox) {
            Canvas { context,_ in
                if mark.style == "measure" {
                    let rect = CGRect(x:CGFloat(box.x)*size.width,y:CGFloat(box.y)*size.height,width:CGFloat(box.width)*size.width,height:CGFloat(box.height)*size.height)
                    context.stroke(Path(roundedRect:rect,cornerRadius:5),with:.color(SolfegeTheme.danger),lineWidth:1.5)
                } else {
                    for glyph in mark.glyphs {
                        if mark.style == "glyph" {
                            let raw = RhythmInk.path(glyph.commands.map { RhythmVectorCommand(op:$0.op,values:$0.values) })
                            let transform = CGAffineTransform(a:size.width,b:0,c:0,d:size.height/CGFloat(crop.bounds.height),tx:0,ty:-CGFloat(crop.bounds.y)*size.height/CGFloat(crop.bounds.height))
                            context.fill(raw.applying(transform),with:.color(SolfegeTheme.danger))
                        } else if let projected = crop.project(glyph.bbox) {
                            let y = CGFloat(projected.y+projected.height)*size.height+4
                            var line = Path(); line.move(to:CGPoint(x:CGFloat(projected.x)*size.width-2,y:y))
                            line.addLine(to:CGPoint(x:CGFloat(projected.x+projected.width)*size.width+2,y:y))
                            context.stroke(line,with:.color(SolfegeTheme.danger),style:StrokeStyle(lineWidth:2,lineCap:.round))
                        }
                    }
                }
            }.allowsHitTesting(false)
            let target = targetBox(mark,crop:crop) ?? box
            Button { onAnnotationTap(); selectedAnnotation = mark.id; if mark.style == "measure" { onMeasureTap?(mark.measure) } } label: { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .frame(width:max(24,CGFloat(target.width)*size.width),height:max(28,CGFloat(target.height)*size.height))
                .position(x:CGFloat(target.x+target.width/2)*size.width,y:CGFloat(target.y+target.height/2)*size.height)
                .accessibilityLabel(mark.message).accessibilityIdentifier("exam-error-\(mark.id)")
                .popover(isPresented:Binding(get:{selectedAnnotation == mark.id},set:{ if !$0 { selectedAnnotation = nil } })) {
                    Text(mark.message).font(.body).padding(20).frame(maxWidth:320).presentationCompactAdaptation(.popover)
                }
        }
    }
    private func targetBox(_ mark: ReferenceAnnotation,crop: AnswerSystemCrop) -> BBox? {
        guard let first = mark.glyphs.first else { return nil }
        let x = mark.glyphs.map(\.bbox.x).min() ?? first.bbox.x
        let y = mark.glyphs.map(\.bbox.y).min() ?? first.bbox.y
        let right = mark.glyphs.map { $0.bbox.x+$0.bbox.width }.max() ?? x
        let bottom = mark.glyphs.map { $0.bbox.y+$0.bbox.height }.max() ?? y
        return crop.project(BBox(x:x,y:y,width:right-x,height:bottom-y))
    }
}
