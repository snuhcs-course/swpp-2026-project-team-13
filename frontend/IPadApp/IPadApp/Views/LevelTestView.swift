import SwiftUI

/// First-Exam level test: intro (with skip), per-stage result and offer, and the first rating.
/// Each stage itself uses the regular Exam intro, writing and grading screens.
struct LevelTestView: View {
    @ObservedObject var model: AppModel
    @State private var confirmingSkip = false

    private var phase: LevelTestPhase {
        // A stage just submitted here is newer than the cached server progress.
        if let record = model.session, let snapshot = record.attempt.levelTestStage, record.attempt.status == "submitted",
           model.levelTest?.stages.first(where: { $0.attemptId == record.id })?.grade == nil {
            return .grading(stage:snapshot.stage)
        }
        return model.levelTest?.phase ?? .none
    }
    private var title: String {
        switch phase {
        case .intro: return StudyMode.exam.title
        case .rating: return "레벨 테스트 완료"
        default: return "레벨 테스트"
        }
    }
    private var plainBackground: Bool {
        switch phase { case .intro, .rating: return true; default: return false }
    }

    var body: some View {
        VStack(spacing:0) {
            LevelTestHeader(title:title) { model.navigate(.main) }
            content.frame(maxWidth:.infinity, maxHeight:.infinity)
        }
        .foregroundStyle(SolfegeTheme.ink)
        .background(plainBackground ? Color.white : SolfegeTheme.background)
        .overlay {
            if confirmingSkip {
                LevelTestSkipConfirmation(rating:model.levelTest?.skipRating ?? 0,
                                          skip: { confirmingSkip = false; Task { await model.skipLevelTest() } },
                                          cancel: { confirmingSkip = false })
            }
        }
        .task(id:model.pollGeneration) { await model.pollLevelTest() }
        .accessibilityIdentifier("level-test")
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .intro:
            LevelTestIntro(busy:model.busy, start: { Task { await model.startLevelTestStage() } }, skip: { confirmingSkip = true })
        case .grading(let stage):
            LevelTestStageScreen {
                LevelTestScoreCard(stage:stage, grade:nil, passGrade:passGrade, grading:model.session?.grading, details:nil)
                LevelTestGradingCard(grading:model.session?.grading, busy:model.busy) { Task { await model.retryGrading() } }
            }
        case .offer(let stage, let grade):
            LevelTestStageScreen {
                LevelTestScoreCard(stage:stage, grade:grade, passGrade:passGrade, grading:nil, details:details)
                LevelTestOfferCard(nextStage:stage+1, busy:model.busy,
                                   next: { Task { await model.startLevelTestStage() } },
                                   stop: { Task { await model.finishLevelTest() } })
            }
        case .ended(let stage, let grade, _):
            LevelTestStageScreen {
                LevelTestScoreCard(stage:stage, grade:grade, passGrade:passGrade, grading:nil, details:details)
                LevelTestEndCard(busy:model.busy) { Task { await model.finishLevelTest() } }
            }
        case .rating(let rating):
            LevelTestRatingView(rating:rating) { model.navigate(.examSelection) }
        case .none:
            ProgressView()
        }
    }
    private var passGrade: Int { model.levelTest?.passGrade ?? 80 }
    private var details: () -> Void { { Task { await model.openLevelTestResult() } } }
}

// MARK: Shared pieces

private enum LevelTestPalette {
    static let successSoft = Color(red:0.902, green:0.949, blue:0.925)   // #E6F2EC
    static let dangerSoft = Color(red:0.984, green:0.918, blue:0.906)    // #FBEAE7
    static let headerRule = Color(red:0.933, green:0.929, blue:0.961)    // #EEEDF5
    static let inkShadow = Color(red:0.055, green:0.067, blue:0.125)     // #0E1120
}

private struct LevelTestHeader: View {
    let title: String
    let home: () -> Void
    var body: some View {
        HStack {
            Button(action:home) {
                HStack(spacing:6) { Image(systemName:"chevron.left").font(.system(size:17, weight:.semibold)); Text("홈") }
                    .font(.system(size:17)).frame(minHeight:44)
            }.buttonStyle(.plain).foregroundStyle(SolfegeTheme.violet)
                .frame(width:140, alignment:.leading).accessibilityIdentifier("level-test-home")
            Spacer()
            Text(title).font(.system(size:20, weight:.bold)).accessibilityAddTraits(.isHeader)
            Spacer()
            Color.clear.frame(width:140, height:1)
        }
        .padding(.horizontal,28).frame(height:64)
        .background(Color.white)
        .overlay(alignment:.bottom) { Rectangle().fill(LevelTestPalette.headerRule).frame(height:1) }
    }
}

/// A filled button that sits on a darker ledge and sinks into it when pressed.
private struct LevelTestRaisedButton: ButtonStyle {
    var fill = SolfegeTheme.violet
    var ledge = SolfegeTheme.deepViolet
    var radius: CGFloat = 14
    var depth: CGFloat = 4
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius:radius).fill(isEnabled ? fill : SolfegeTheme.disabledText))
            .offset(y:configuration.isPressed ? depth : 0)
            .background(RoundedRectangle(cornerRadius:radius).fill(isEnabled ? ledge : SolfegeTheme.disabledText).offset(y:depth))
            .padding(.bottom,depth)
    }
}

private struct LevelTestStageScreen<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(spacing:20) { content }
                .frame(maxWidth:760)
                .padding(.horizontal,40).padding(.vertical,32)
                .frame(maxWidth:.infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
    }
}

// MARK: Intro

private struct LevelTestIntro: View {
    let busy: Bool
    let start: () -> Void
    let skip: () -> Void
    var body: some View {
        ScrollView {
            VStack(spacing:40) {
                VStack(spacing:22) {
                    ZStack {
                        Circle().fill(SolfegeTheme.soft).frame(width:132, height:132)
                        HStack(spacing:8) {
                            ForEach(Array([30.0, 52, 72, 52, 30].enumerated()), id:\.offset) { _, height in
                                Capsule().fill(SolfegeTheme.violet).frame(width:9, height:height)
                            }
                        }
                    }.accessibilityHidden(true)
                    Text("LEVEL TEST").font(.system(size:13, weight:.heavy)).tracking(2.4).foregroundStyle(SolfegeTheme.violet)
                    Text("레벨 테스트를 한번 해볼까요?").font(.system(size:40, weight:.heavy)).multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text("청음 문제를 풀어보면 지금 실력에 맞는 레이팅에서 Exam을 시작할 수 있어요.")
                        .font(.system(size:18)).lineSpacing(4).foregroundStyle(SolfegeTheme.muted)
                        .multilineTextAlignment(.center).frame(maxWidth:560)
                }
                VStack(spacing:8) {
                    Button(action:start) {
                        HStack(spacing:10) { Text("레벨 테스트 시작"); Image(systemName:"chevron.right").font(.system(size:16, weight:.bold)) }
                            .font(.system(size:18, weight:.bold)).frame(width:360, height:58)
                    }.buttonStyle(LevelTestRaisedButton()).disabled(busy)
                        .accessibilityIdentifier("level-test-start")
                    Button(action:skip) {
                        Text("건너뛰기").font(.system(size:16, weight:.medium)).underline()
                            .frame(minWidth:160, minHeight:48)
                    }.buttonStyle(.plain).foregroundStyle(SolfegeTheme.muted).disabled(busy)
                        .accessibilityIdentifier("level-test-skip")
                }
            }
            .padding(40).frame(maxWidth:.infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
    }
}

private struct LevelTestSkipConfirmation: View {
    let rating: Double
    let skip: () -> Void
    let cancel: () -> Void
    private var ratingText: String { String(format:"%.1f", rating) }
    var body: some View {
        ZStack {
            SolfegeTheme.ink.opacity(0.48).ignoresSafeArea()
                .onTapGesture(perform:cancel).accessibilityHidden(true)
            VStack(alignment:.leading, spacing:14) {
                ZStack {
                    Circle().fill(LevelTestPalette.dangerSoft).frame(width:52, height:52)
                    Image(systemName:"exclamationmark.triangle").font(.system(size:24, weight:.semibold)).foregroundStyle(SolfegeTheme.danger)
                }.accessibilityHidden(true)
                Text("레벨 테스트를 건너뛸까요?").font(.system(size:22, weight:.heavy)).accessibilityAddTraits(.isHeader)
                (Text("건너뛰면 레이팅이 ") + Text(ratingText).bold().foregroundStyle(SolfegeTheme.danger)
                    + Text("부터 시작해요. 레벨 테스트는 다시 볼 수 없고, 시험을 보면서 레이팅을 올려야 해요."))
                    .font(.system(size:15)).lineSpacing(5).foregroundStyle(SolfegeTheme.muted)
                    .fixedSize(horizontal:false, vertical:true)
                HStack {
                    Text("시작 레이팅").font(.system(size:14, weight:.medium)).foregroundStyle(SolfegeTheme.softInk)
                    Spacer()
                    Text(ratingText).font(.system(size:26, weight:.heavy)).monospacedDigit().foregroundStyle(SolfegeTheme.danger)
                }
                .padding(.horizontal,18).padding(.vertical,14)
                .background(SolfegeTheme.field, in:RoundedRectangle(cornerRadius:14))
                .accessibilityElement(children:.combine)
                Button(action:skip) {
                    Text("건너뛰기").font(.system(size:16, weight:.bold)).foregroundStyle(.white)
                        .frame(maxWidth:.infinity, minHeight:52)
                        .background(SolfegeTheme.danger, in:RoundedRectangle(cornerRadius:12))
                }.buttonStyle(.plain).padding(.top,6).accessibilityIdentifier("level-test-skip-confirm")
                Button(action:cancel) {
                    Text("레벨 테스트 볼게요").font(.system(size:16, weight:.bold)).foregroundStyle(SolfegeTheme.violet)
                        .frame(maxWidth:.infinity, minHeight:44)
                }.buttonStyle(.plain)
            }
            .foregroundStyle(SolfegeTheme.ink)
            .padding(.horizontal,28).padding(.top,30).padding(.bottom,18)
            .frame(width:420)
            .background(Color.white, in:RoundedRectangle(cornerRadius:24))
            .shadow(color:LevelTestPalette.inkShadow.opacity(0.28), radius:30, y:24)
            .accessibilityAddTraits(.isModal)
        }
    }
}

// MARK: Stage result

private struct LevelTestScoreCard: View {
    let stage: Int
    let grade: Int?
    let passGrade: Int
    let grading: Grading?
    let details: (() -> Void)?
    var body: some View {
        VStack(alignment:.leading, spacing:22) {
            HStack {
                Text(LevelTestTier.stageTitle(stage)).font(.system(size:16, weight:.bold)).foregroundStyle(SolfegeTheme.softInk)
                Spacer()
                badge
            }
            if let grade {
                HStack(alignment:.firstTextBaseline, spacing:6) {
                    Text("\(grade)").font(.system(size:112, weight:.heavy)).tracking(-4).monospacedDigit()
                    Text("점").font(.system(size:26, weight:.bold))
                }
                .accessibilityElement(children:.combine).accessibilityIdentifier("level-test-score")
            } else {
                HStack(spacing:14) {
                    if grading?.status != "failed" { ProgressView().controlSize(.large) }
                    Text(grading?.status == "failed" ? "채점을 완료하지 못했어요" :
                            grading?.stage == "feedback" ? "피드백을 정리하고 있어요" : "채점 중이에요")
                        .font(.system(size:28, weight:.bold))
                }.frame(height:112, alignment:.leading)
            }
            LevelTestThresholdBar(grade:grade, passGrade:passGrade)
            if let details {
                Button(action:details) {
                    HStack(spacing:6) { Text("채점 결과 자세히 보기"); Image(systemName:"chevron.right").font(.system(size:12, weight:.semibold)) }
                        .font(.system(size:15, weight:.medium)).frame(minHeight:44)
                }.buttonStyle(.plain).foregroundStyle(SolfegeTheme.violet)
                    .accessibilityIdentifier("level-test-details")
            }
        }
        .padding(.horizontal,40).padding(.top,36).padding(.bottom,details == nil ? 36 : 24)
        .frame(maxWidth:.infinity, alignment:.leading)
        .background(Color.white, in:RoundedRectangle(cornerRadius:24))
    }
    @ViewBuilder private var badge: some View {
        if let grade, grade >= passGrade {
            Label("기준 \(passGrade)점 통과", systemImage:"checkmark")
                .font(.system(size:14, weight:.bold)).foregroundStyle(SolfegeTheme.green)
                .padding(.horizontal,14).padding(.vertical,8)
                .background(LevelTestPalette.successSoft, in:Capsule())
        } else if let grade {
            Text("기준 \(passGrade)점까지 \(passGrade-grade)점")
                .font(.system(size:14, weight:.bold)).foregroundStyle(SolfegeTheme.softInk)
                .padding(.horizontal,14).padding(.vertical,8)
                .background(SolfegeTheme.field, in:Capsule())
        }
    }
}

private struct LevelTestThresholdBar: View {
    let grade: Int?
    let passGrade: Int
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let pass = width*CGFloat(passGrade)/100
            ZStack(alignment:.topLeading) {
                Capsule().fill(SolfegeTheme.soft).frame(height:12)
                Capsule().fill(SolfegeTheme.violet).frame(width:width*CGFloat(grade ?? 0)/100, height:12)
                Rectangle().fill(SolfegeTheme.ink).frame(width:2, height:24).offset(x:pass-1, y:-6)
                Text("0").offset(y:22)
                Text("기준 \(passGrade)").fontWeight(.bold).foregroundStyle(SolfegeTheme.ink)
                    .fixedSize().frame(width:80).offset(x:pass-40, y:22)
                Text("100").frame(width:width, alignment:.trailing).offset(y:22)
            }
            .font(.system(size:13)).foregroundStyle(SolfegeTheme.muted)
        }
        .frame(height:40)
        .accessibilityElement(children:.ignore)
        .accessibilityLabel(grade.map { "\($0)점, 기준 \(passGrade)점" } ?? "기준 \(passGrade)점")
    }
}

private struct LevelTestOfferCard: View {
    let nextStage: Int
    let busy: Bool
    let next: () -> Void
    let stop: () -> Void
    private var last: Bool { nextStage >= LevelTestTier.all.count }
    var body: some View {
        HStack(spacing:24) {
            VStack(alignment:.leading, spacing:6) {
                Text(last ? "LAST STEP" : "NEXT STEP").font(.system(size:12, weight:.heavy)).tracking(2).foregroundStyle(SolfegeTheme.violet)
                Text(last ? "훌륭해요! 마지막으로 고급 문제도 풀어볼까요?" : "잘 풀었어요! 중간 난이도에도 도전해볼까요?")
                    .font(.system(size:21, weight:.heavy)).fixedSize(horizontal:false, vertical:true)
                Text(last ? "가장 어려운 단계예요. 끝나면 바로 결과를 보여드려요." : "한 문제만 더 풀면 첫 레이팅을 더 정확하게 잡을 수 있어요.")
                    .font(.system(size:14)).foregroundStyle(SolfegeTheme.softInk).fixedSize(horizontal:false, vertical:true)
            }.frame(maxWidth:.infinity, alignment:.leading)
            VStack(spacing:6) {
                Button(action:next) {
                    HStack(spacing:8) {
                        Text("\(LevelTestTier.forStage(nextStage)?.name ?? "다음") 문제 풀기")
                        Image(systemName:"chevron.right").font(.system(size:14, weight:.bold))
                    }
                    .font(.system(size:16, weight:.bold)).padding(.horizontal,22).frame(minHeight:48)
                }
                .buttonStyle(LevelTestRaisedButton(fill:last ? SolfegeTheme.ink : SolfegeTheme.violet,
                                                   ledge:last ? LevelTestPalette.inkShadow : SolfegeTheme.deepViolet,
                                                   radius:12, depth:3))
                .accessibilityIdentifier("level-test-next")
                Button(action:stop) {
                    Text("여기서 마치기").font(.system(size:15, weight:.bold)).padding(.horizontal,16).frame(minHeight:44)
                }.buttonStyle(.plain).foregroundStyle(SolfegeTheme.softInk)
                    .accessibilityIdentifier("level-test-stop")
            }
            .fixedSize().disabled(busy)
        }
        .padding(.horizontal,28).padding(.vertical,24)
        .background(SolfegeTheme.soft, in:RoundedRectangle(cornerRadius:20))
    }
}

private struct LevelTestEndCard: View {
    let busy: Bool
    let finish: () -> Void
    var body: some View {
        HStack(spacing:24) {
            VStack(alignment:.leading, spacing:6) {
                Text("LEVEL TEST 종료").font(.system(size:12, weight:.heavy)).tracking(2).foregroundStyle(SolfegeTheme.muted)
                Text("수고했어요! 레벨 테스트는 여기까지예요").font(.system(size:21, weight:.heavy)).fixedSize(horizontal:false, vertical:true)
            }.frame(maxWidth:.infinity, alignment:.leading)
            Button(action:finish) {
                HStack(spacing:8) { Text("결과 보기"); Image(systemName:"chevron.right").font(.system(size:14, weight:.bold)) }
                    .font(.system(size:16, weight:.bold)).padding(.horizontal,22).frame(minHeight:48)
            }
            .buttonStyle(LevelTestRaisedButton(radius:12, depth:3)).fixedSize().disabled(busy)
            .accessibilityIdentifier("level-test-finish")
        }
        .padding(.horizontal,28).padding(.vertical,24)
        .background(Color.white, in:RoundedRectangle(cornerRadius:20))
        .overlay(RoundedRectangle(cornerRadius:20).strokeBorder(SolfegeTheme.disabledFill, lineWidth:1.5))
    }
}

private struct LevelTestGradingCard: View {
    let grading: Grading?
    let busy: Bool
    let retry: () -> Void
    var body: some View {
        HStack(spacing:24) {
            Text(grading?.status == "failed" ? (grading?.failure?.message ?? "결과를 다시 확인해 주세요.") : "채점이 끝나면 다음 단계를 알려드려요.")
                .font(.system(size:15)).foregroundStyle(SolfegeTheme.softInk)
                .frame(maxWidth:.infinity, alignment:.leading)
            if grading?.canRetry == true {
                Button(action:retry) {
                    Text("채점 다시 시도").font(.system(size:16, weight:.bold)).padding(.horizontal,22).frame(minHeight:48)
                }.buttonStyle(LevelTestRaisedButton(radius:12, depth:3)).fixedSize().disabled(busy)
                    .accessibilityIdentifier("level-test-retry-grading")
            }
        }
        .padding(.horizontal,28).padding(.vertical,24)
        .background(SolfegeTheme.soft, in:RoundedRectangle(cornerRadius:20))
    }
}

// MARK: First rating

private struct LevelTestRatingView: View {
    let rating: Double
    let start: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0.0
    @State private var settled = false
    private static let countDuration = 2.8

    var body: some View {
        ScrollView {
            VStack(spacing:36) {
                ZStack {
                    Circle().fill(SolfegeTheme.soft).frame(width:420, height:420)
                        .scaleEffect(settled ? 1 : 0.86).opacity(settled ? 1 : 0)
                    VStack(spacing:4) {
                        Text("나의 첫 레이팅").font(.system(size:20, weight:.bold)).foregroundStyle(SolfegeTheme.softInk)
                        CountingRating(value:shown)
                            .font(.system(size:148, weight:.heavy)).tracking(-5).monospacedDigit()
                            .foregroundStyle(settled ? SolfegeTheme.violet : SolfegeTheme.ink)
                    }
                }
                .frame(width:420, height:420)
                .accessibilityElement(children:.ignore)
                .accessibilityLabel("나의 첫 레이팅 \(String(format:"%.1f", rating))")
                .accessibilityIdentifier("level-test-rating")
                VStack(spacing:22) {
                    Text("이 레이팅에 맞춰 시험 문제를 추천해 드려요.").font(.system(size:17)).foregroundStyle(SolfegeTheme.muted)
                    Button(action:start) {
                        HStack(spacing:10) { Text("시험 시작하기"); Image(systemName:"chevron.right").font(.system(size:16, weight:.bold)) }
                            .font(.system(size:18, weight:.bold)).frame(width:360, height:58)
                    }.buttonStyle(LevelTestRaisedButton())
                        .accessibilityIdentifier("level-test-start-exam")
                }
                .opacity(settled ? 1 : 0).offset(y:settled ? 0 : 12)
                .allowsHitTesting(settled).accessibilityHidden(!settled)
            }
            .padding(40).frame(maxWidth:.infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
        .task(id:rating) { await play() }
    }

    /// Shoots up, then crawls through the last decimals before stopping on the rating.
    private func play() async {
        shown = 0; settled = false
        if reduceMotion { shown = rating; settled = true; return }
        try? await Task.sleep(for:.milliseconds(450))
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration:Self.countDuration)) { shown = rating }
        try? await Task.sleep(for:.seconds(Self.countDuration))
        withAnimation(.spring(response:0.55, dampingFraction:0.62)) { settled = true }
    }
}

/// Re-renders its one-decimal text on every animation frame of `value`.
private struct CountingRating: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View { Text(String(format:"%.1f", value)) }
}
