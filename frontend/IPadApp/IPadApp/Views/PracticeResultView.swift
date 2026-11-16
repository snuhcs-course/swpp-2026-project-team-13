import SwiftUI
import AVFoundation

private struct ReviewMeasureAnchors: PreferenceKey {
    static var defaultValue: [Int:Anchor<CGRect>] = [:]
    static func reduce(value: inout [Int:Anchor<CGRect>], nextValue: () -> [Int:Anchor<CGRect>]) {
        value.merge(nextValue(),uniquingKeysWith:{ _,new in new })
    }
}

struct PracticeResultView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var audio = PracticeReviewPlayback()
    @State private var selectedMeasure: Int?
    @State private var autoplayAttempt: UUID?
    @State private var manualPlayback = false
    @State private var showingSaveRecovery = false

    private var reference: (image: UIImage, geometry: PracticeReviewGeometry?)? {
        guard let q = model.session?.attempt.question else { return nil }
        if let local = PracticeReferenceAssets.reference(for:q) { return (local.image,local.geometry) }
        return model.correctScoreImage.map { ($0,q.correctScore?.geometry) }
    }
    private var ready: Bool {
        let referenceReady = reference != nil || (model.session?.attempt.question.correctScore == nil && model.mainScore != nil)
        return referenceReady && model.submittedImage != nil && model.mainScore != nil
    }
    private var editingEnabled: Bool {
        !model.busy && model.session?.selfAssessment != nil && model.session?.selfAssessmentSave == nil && !model.practiceHasConflict
    }
    var body: some View {
        VStack(spacing:12) {
            header
            HStack {
                Text("내 악보에서 틀린 마디를 선택해주세요.").font(.subheadline).foregroundStyle(SolfegeTheme.ink)
                Spacer()
                Button { manualPlayback = true; play() } label: {
                    Label("전체 다시듣기",systemImage:"arrow.clockwise").font(.subheadline)
                }.buttonStyle(.bordered).disabled(!ready).accessibilityIdentifier("practice-review-replay")
            }
            VStack(spacing:12) {
                scorePanel(title:"정답 악보",reference:true)
                scorePanel(title:"내 악보",reference:false)
            }.frame(maxHeight:.infinity)
            footer
        }
        .padding(.horizontal,24).padding(.vertical,12).background(.white)
        .overlayPreferenceValue(ReviewMeasureAnchors.self) { anchors in
            GeometryReader { proxy in
                if let selectedMeasure, let anchor = anchors[selectedMeasure] {
                    let rect = proxy[anchor]
                    let frame = PracticeReviewPopover.frame(anchor:BBox(x:Double(rect.minX),y:Double(rect.minY),width:Double(rect.width),height:Double(rect.height)),
                        width:228,height:204,containerWidth:Double(proxy.size.width),containerHeight:Double(proxy.size.height))
                    Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { self.selectedMeasure = nil }
                    errorPicker(measure:selectedMeasure)
                        .frame(width:CGFloat(frame.width),height:CGFloat(frame.height))
                        .background(.white,in:RoundedRectangle(cornerRadius:14))
                        .overlay(RoundedRectangle(cornerRadius:14).stroke(SolfegeTheme.keyEdge.opacity(0.6)))
                        .shadow(color:.black.opacity(0.12),radius:15,y:4)
                        .position(x:CGFloat(frame.x+frame.width/2),y:CGFloat(frame.y+frame.height/2))
                }
            }
        }
        .task(id:"\(model.session?.id.uuidString ?? "")-\(ready)") {
            guard ready, let id = model.session?.id, autoplayAttempt != id, !manualPlayback, scenePhase == .active else { return }
            autoplayAttempt = id
            do { try await Task.sleep(for:.milliseconds(700)); try Task.checkCancellation() } catch { return }
            guard !manualPlayback, scenePhase == .active, model.screen == .result, model.session?.id == id else { return }
            play()
        }
        .onChange(of:model.session?.id) { _,_ in selectedMeasure = nil; manualPlayback = false; audio.stop() }
        .onChange(of:scenePhase) { _,phase in if phase != .active { manualPlayback = true; audio.stop() } }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.interruptionNotification).receive(on:RunLoop.main)) { _ in manualPlayback = true; audio.stop() }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.mediaServicesWereResetNotification).receive(on:RunLoop.main)) { _ in manualPlayback = true; audio.stop() }
        .onReceive(NotificationCenter.default.publisher(for:.AVAudioEngineConfigurationChange).receive(on:RunLoop.main)) { audio.configurationChanged($0) }
        .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.routeChangeNotification).receive(on:RunLoop.main)) { notification in
            if let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               AVAudioSession.RouteChangeReason(rawValue:reason) == .oldDeviceUnavailable { manualPlayback = true; audio.stop() }
        }
        .onDisappear { audio.stop() }
        .sheet(isPresented:$showingSaveRecovery) { saveRecovery }
        .accessibilityIdentifier("practice-review-screen")
    }
    private var header: some View {
        ZStack {
            Text("정답과 비교하기").font(.system(size:22,weight:.bold)).foregroundStyle(SolfegeTheme.ink)
            HStack {
                Button { audio.stop(); selectedMeasure = nil; model.leavePracticeReview() } label: {
                    Label(model.dailyPracticeItem == nil ? "Practice" : "오늘의 트레이닝",systemImage:"chevron.left").labelStyle(.titleAndIcon)
                }.disabled(model.busy).accessibilityIdentifier("result-leave")
                Spacer()
                Text(model.session?.attempt.question.title ?? "").font(.subheadline).foregroundStyle(SolfegeTheme.muted).lineLimit(1).frame(maxWidth:260,alignment:.trailing)
            }
        }.frame(height:40)
    }
    private func scorePanel(title: String, reference isReference: Bool) -> some View {
        VStack(alignment:.leading,spacing:3) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(SolfegeTheme.ink)
                Spacer()
                if isReference, reference?.geometry?.isValid == true { Text("마디를 눌러 재생").font(.caption).foregroundStyle(SolfegeTheme.muted) }
            }.padding(.horizontal,16).padding(.top,12)
            if isReference, let reference {
                if let geometry = reference.geometry, geometry.isValid {
                    ReviewScoreImage(image:reference.image,geometry:geometry,errors:[],selected:audio.measure,review:false) { measure in
                        manualPlayback = true; play(measure:measure)
                    }.disabled(model.mainScore == nil)
                } else {
                    // An unfamiliar server may still provide the older PNG-only contract.
                    Image(uiImage:reference.image).resizable().scaledToFit().padding(8).frame(maxWidth:.infinity,maxHeight:.infinity)
                }
            } else if isReference, model.session?.attempt.question.correctScore == nil, let score = model.mainScore {
                ScoreView(score:score).frame(maxWidth:.infinity,maxHeight:.infinity).clipped()
            } else if !isReference, let image = model.submittedImage, let sheet = model.session?.attempt.question.sheetLayout {
                ReviewScoreImage(image:image,geometry:PracticeReviewGeometry(sheet:sheet),errors:model.practiceErrors,selected:selectedMeasure,review:true) { measure in
                    guard editingEnabled else { return }
                    selectedMeasure = selectedMeasure == measure ? nil : measure
                }
            } else {
                VStack(spacing:8) {
                    if !model.busy && model.session?.attempt.status == "submitted" {
                        Text(isReference ? "정답 악보를 불러오지 못했어요." : "내 악보를 불러오지 못했어요.").font(.caption).foregroundStyle(.secondary)
                        Button("다시 불러오기") { Task { await model.refreshResult() } }.buttonStyle(.bordered)
                    } else { ProgressView() }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity)
        .background(.white,in:RoundedRectangle(cornerRadius:16))
        .overlay(RoundedRectangle(cornerRadius:16).stroke(SolfegeTheme.keyEdge.opacity(0.65)))
    }
    private var footer: some View {
        VStack(spacing:12) {
            Divider()
            HStack {
                Text("\(model.practiceErrors.count)개 마디 표시").font(.subheadline).foregroundStyle(SolfegeTheme.muted)
                Spacer()
                Button { Task { await complete() } } label: { Text("채점 완료").frame(width:180) }
                    .buttonStyle(PrimaryButton())
                    .disabled(model.busy || !ready || model.session?.selfAssessment == nil)
                    .opacity(model.busy || !ready || model.session?.selfAssessment == nil ? 0.45 : 1)
                    .accessibilityIdentifier("practice-review-complete")
            }
        }
    }
    private func errorPicker(measure: Int) -> some View {
        VStack(alignment:.leading,spacing:5) {
            HStack {
                Text("\(measure)마디").font(.subheadline.bold())
                Spacer()
                Button { selectedMeasure = nil } label: { Image(systemName:"xmark").font(.caption).padding(8) }.accessibilityLabel("닫기")
            }
            ForEach(SelfAssessmentErrorType.allCases) { type in
                let checked = model.practiceErrors.first(where: { $0.measure == measure })?.types.contains(type.rawValue) == true
                Button { model.togglePracticeError(measure:measure,type:type) } label: {
                    HStack { Text(type.title); Spacer(); if checked { Image(systemName:"checkmark") } }
                        .font(.subheadline).padding(.horizontal,10).frame(height:36)
                        .foregroundStyle(checked ? SolfegeTheme.violet : SolfegeTheme.ink)
                        .background(checked ? SolfegeTheme.soft : .clear,in:RoundedRectangle(cornerRadius:8))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!editingEnabled).accessibilityIdentifier("self-assess-type-\(type.rawValue)")
            }
        }.padding(14)
    }
    private var saveRecovery: some View {
        VStack(alignment:.leading,spacing:20) {
            Text(model.practiceHasConflict ? "채점 기록이 변경됐어요" : "채점 기록을 저장하지 못했어요").font(.title3.bold())
            Text("선택한 표시는 보관되어 있어요.").foregroundStyle(.secondary)
            if model.practiceHasConflict {
                Button("서버 표시 적용") { model.useServerPracticeAssessment(); showingSaveRecovery = false }.buttonStyle(.bordered)
                Button("내 표시 유지") { model.keepLocalPracticeEdits(); showingSaveRecovery = false }.buttonStyle(.bordered)
            } else {
                Button("다시 저장하기") { showingSaveRecovery = false; Task { await complete() } }.buttonStyle(PrimaryButton())
            }
            Button("닫기") { showingSaveRecovery = false }
        }.padding(28).presentationDetents([.medium])
    }
    private func play(measure: Int? = nil) {
        guard let score = model.mainScore, let attempt = model.session?.attempt else { return }
        do { try audio.play(score:score,measure:measure,bpm:attempt.playbackPlan.tempoBpm,voice:model.selectedVoice) }
        catch { audio.stop(); model.error = error.localizedDescription }
    }
    private func complete() async {
        selectedMeasure = nil; audio.stop(); manualPlayback = true
        if model.practiceHasConflict { showingSaveRecovery = true; return }
        if await model.finishPracticeAssessment() { audio.stop() }
        else if model.practiceHasConflict { showingSaveRecovery = true }
    }
}

private struct ReviewScoreImage: View {
    let image: UIImage
    let geometry: PracticeReviewGeometry
    let errors: [MeasureError]
    let selected: Int?
    let review: Bool
    let onTap: (Int) -> Void
    var body: some View {
        GeometryReader { proxy in
            let strips = geometry.strips
            let rowsHeight = strips.reduce(0.0) { $0+$1.bounds.height*Double(geometry.logicalHeight) }
            let gap = 5.0
            let width = max(0,min(Double(proxy.size.width)-16,(Double(proxy.size.height)-gap)/max(1,rowsHeight)*Double(geometry.logicalWidth)))
            VStack(spacing:CGFloat(gap)) {
                ForEach(strips) { crop in
                    if let source = image.cgImage, let row = source.cropping(to:CGRect(x:0,y:CGFloat(crop.bounds.y)*CGFloat(source.height),width:CGFloat(source.width),height:CGFloat(crop.bounds.height)*CGFloat(source.height)).integral) {
                        Image(uiImage:UIImage(cgImage:row)).resizable()
                            .frame(width:CGFloat(width),height:CGFloat(width*crop.bounds.height*Double(geometry.logicalHeight)/Double(geometry.logicalWidth)))
                            .overlay { GeometryReader { rowProxy in
                                ForEach(crop.measureRegions(logicalWidth:geometry.logicalWidth,systems:geometry.systems)) { region in
                                    measureButton(region)
                                        .frame(width:CGFloat(region.bounds.width)*rowProxy.size.width,height:rowProxy.size.height)
                                        .position(x:CGFloat(region.bounds.x+region.bounds.width/2)*rowProxy.size.width,y:rowProxy.size.height/2)
                                }
                            } }
                    }
                }
            }.position(x:proxy.size.width/2,y:proxy.size.height/2)
        }
    }
    private func measureButton(_ region: AnswerMeasureRegion) -> some View {
        let marked = errors.contains(where: { $0.measure == region.id })
        let color = review && marked ? SolfegeTheme.danger : SolfegeTheme.violet
        return Button { onTap(region.id) } label: {
            Rectangle().fill(color.opacity(selected == region.id ? 0.09 : marked ? 0.045 : 0.001))
                .overlay { if selected == region.id || marked { RoundedRectangle(cornerRadius:6).stroke(color.opacity(0.8),lineWidth:1.2) } }
                .overlay(alignment:.topLeading) {
                    Text("\(region.id)").font(.system(size:11)).foregroundStyle(SolfegeTheme.muted).padding(.leading,4).padding(.top,2)
                }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(region.id)마디"+(review ? (marked ? " · 오류 표시됨" : " · 오류 선택") : " 재생"))
            .accessibilityIdentifier(review ? "self-assess-measure-\(region.id)" : "reference-measure-\(region.id)")
            .transformAnchorPreference(key:ReviewMeasureAnchors.self,value:.bounds) { value,anchor in
                if review { value[region.id] = anchor }
            }
    }
}
