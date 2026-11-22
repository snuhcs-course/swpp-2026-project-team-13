import SwiftUI

private struct TutorialScopeKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    var tutorialScope: String? {
        get { self[TutorialScopeKey.self] }
        set { self[TutorialScopeKey.self] = newValue }
    }
}
@MainActor enum TutorialHistory {
    static func store(scope: String?) -> TutorialProgressStore? {
        guard let local = try? LocalStore(scope: scope ?? "tutorial-offline-demo") else { return nil }
        return TutorialProgressStore(root: local.root)
    }
    static func hasSeen(_ kind: TutorialKind, scope: String?) -> Bool { store(scope: scope)?.hasSeen(kind) ?? false }
    static func finish(_ kind: TutorialKind, scope: String?) { try? store(scope: scope)?.markSeen(kind) }
}
struct TutorialHelpButton: View {
    var label = "게임 방법"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "questionmark.circle").font(.system(size: 25))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(SolfegeTheme.violet).accessibilityLabel(label)
    }
}
enum TutorialTarget: Hashable {
    case start, replay, keyboard, firstKey, notation, choices, tie, submit
    case progress, timer, tools, next, playPause, undo, erase
    case rhythmTapTile, rhythmDragTile, dropSlot, tieStart, tieEnd
}
struct TutorialStep {
    let target: TutorialTarget
    let title: String
    let message: String
}
extension TutorialKind {
    var introduction: String {
        switch self {
        case .echoDragon: return "드래곤이 노래하는 두 음의 간격을 듣고,\n다른 시작음에서 같은 음정으로 연주해요."
        case .memoryRun: return "두 마디 선율을 기억하고,\n건반으로 다시 연주해요."
        case .rhythmPuzzle: return "두 마디를 듣고,\n리듬 조각을 골라 악보를 완성해요."
        case .exam: return "들은 선율을 빈 오선에 적어요.\nPractice는 직접, Exam은 AI가 채점해요."
        }
    }
    var steps: [TutorialStep] {
        switch self {
        case .echoDragon: return [
            .init(target: .start, title: "먼저 들어볼까요?", message: "시작을 누르면 드래곤이 노래해요.\n두 음 사이의 간격을 들어보세요."),
            .init(target: .replay, title: "다시 들어도 괜찮아요", message: "간격이 헷갈리면 여러 번 다시 들어보세요."),
            .init(target: .firstKey, title: "다른 음높이에서 따라해요", message: "표시된 건반부터 눌러요.\n누른 건반은 색이 바뀌어요."),
            .init(target: .keyboard, title: "같은 음정으로 답해요", message: "드래곤과 같은 방향·간격으로\n두 번째 음을 눌러요."),
            .init(target: .submit, title: "드래곤에게 답해볼까요?", message: "제출을 누르면 내가 연주한 두 음이 나와요.\n드래곤의 반응을 확인해보세요.")
        ]
        case .memoryRun: return [
            .init(target: .start, title: "두 마디를 기억해요", message: "시작을 누르고 선율을 들어보세요.\n두 마디가 연속해서 나와요."),
            .init(target: .replay, title: "필요하면 다시 들어요", message: "왼쪽은 선율만, 오른쪽은\n예비박과 함께 다시 들어요."),
            .init(target: .keyboard, title: "들은 음을 채워보세요", message: "건반을 누르면 악보가 순서대로 채워져요.\n들은 음높이를 차례대로 눌러보세요."),
            .init(target: .notation, title: "입력한 음을 고쳐보세요", message: "되돌리기나 지우개로 고쳐보세요.\n마디를 고르면 그곳부터 다시 입력할 수 있어요."),
            .init(target: .submit, title: "입력이 끝났다면", message: "제출하고 결과를 확인해요.\n틀렸다면 같은 화면에서 고쳐보세요.")
        ]
        case .rhythmPuzzle: return [
            .init(target: .start, title: "리듬에 귀를 기울여요", message: "예비박 다음에 두 마디가 나와요.\n리듬의 흐름을 들어보세요."),
            .init(target: .replay, title: "필요하면 다시 들어요", message: "왼쪽은 선율만, 오른쪽은\n예비박과 함께 다시 들어요."),
            .init(target: .choices, title: "조각을 넣어보세요", message: "터치로 하나, 드래그로 하나 넣어보세요."),
            .init(target: .notation, title: "입력된 리듬 조각도 옮길 수 있어요", message: "조각을 터치하면 지워져요.\n드래그해서 다른 칸으로 옮기거나,\n악보 밖으로 끌어내 지울 수도 있어요."),
            .init(target: .tie, title: "이어지는 음은 타이로", message: "타이를 켜고, 두 조각을 손가락으로 이어줘요."),
            .init(target: .submit, title: "리듬을 완성했다면", message: "제출하고 결과를 확인해요.\n틀렸다면 고쳐서 다시 도전해 보세요.")
        ]
        case .exam: return Self.writingSteps(mode: .exam)
        }
    }
    static func writingSteps(mode: StudyMode) -> [TutorialStep] {
        [
            .init(target: .progress, title: "구간별로 들어요", message: "스케일 다음에 구간별 연주가 이어져요.\n지금 진행 중인 구간을 확인해요."),
            .init(target: .timer, title: "남은 필기 시간을 확인해요", message: "필기 시간에는 남은 시간이 표시돼요.\n시간이 끝나면 다음 구간으로 넘어가요."),
            .init(target: .tools, title: "쓰고, 고쳐보세요", message: "펜과 지우개를 골라 악보에 적어요.\n점을 누르면 펜 굵기를 바꿀 수 있어요."),
            .init(target: .notation, title: "들은 선율을 적어요", message: "Apple Pencil로 빈 오선에 악보를 적어요."),
            .init(target: mode == .practice ? .playPause : .progress,
                  title: mode == .practice ? "연습은 잠깐 멈출 수 있어요" : "Exam은 정해진 순서대로",
                  message: mode == .practice ? "Practice에서는 일시정지하거나,\n진행 막대의 구간을 눌러 다시 들을 수 있어요." : "Exam에서는 구간을 되돌리거나\n재생을 직접 일시정지할 수 없어요."),
            .init(target: .next, title: "필기를 마쳤다면", message: "필기 시간에는 다음 구간으로 넘어갈 수 있어요.\n이 버튼은 Practice와 Exam 모두 사용할 수 있어요."),
            .init(target: .submit, title: mode == .practice ? "정답과 직접 비교해요" : "답안을 제출해요",
                  message: mode == .practice ? "Practice에서는 정답과 내 악보를 비교하고,\n틀린 마디를 직접 표시해요." : "Exam에서는 AI가 채점하고 피드백을 줘요.\n제출 후에는 답안을 수정할 수 없어요.")
        ]
    }
}
struct TutorialAnchors: PreferenceKey {
    static var defaultValue: [TutorialTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TutorialTarget: Anchor<CGRect>], nextValue: () -> [TutorialTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
extension View {
    func tutorialTarget(_ target: TutorialTarget) -> some View {
        transformAnchorPreference(key: TutorialAnchors.self, value: .bounds) { value, anchor in value[target] = anchor }
    }
    func writingTutorial(isPresented: Bool, mode: StudyMode, initialPage: Int = 0, done: @escaping () -> Void) -> some View {
        allowsHitTesting(!isPresented).accessibilityHidden(isPresented)
            .overlayPreferenceValue(TutorialAnchors.self) { anchors in
                if isPresented { WritingTutorialGuide(mode: mode, anchors: anchors, initialPage: initialPage, done: done) }
            }
    }
}
private struct SpotlightMask: Shape {
    let holes: [CGRect]
    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        // Nested highlights must not cancel each other under even-odd fill.
        let outer = holes.enumerated().filter { i, r in
            !holes.enumerated().contains { j, other in j != i && other.contains(r) && (other != r || j < i) }
        }.map(\.element)
        for hole in outer { p.addRoundedRect(in: hole, cornerSize: CGSize(width: 12, height: 12)) }
        return p
    }
}
private func tutorialRects(_ keys: [TutorialTarget], anchors: [TutorialTarget: Anchor<CGRect>], proxy: GeometryProxy) -> [CGRect] {
    let visible = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 5, dy: 5)
    return keys.compactMap { key in
        guard let anchor = anchors[key] else { return nil }
        let rect = proxy[anchor].insetBy(dx: -5, dy: -5).intersection(visible)
        return rect.isNull || rect.isEmpty ? nil : rect
    }
}

struct TutorialCoachCard: View {
    let page: Int; let count: Int; let title: String; let message: String
    var task: String? = nil
    var canAdvance = true
    var readOnly = false
    let previous: () -> Void; let next: () -> Void; let skip: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(page == 0 ? "Tutorial" : "\(page) / \(count)")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(SolfegeTheme.violet)
                Spacer()
                Button("건너뛰기", action: skip).font(.subheadline).frame(minHeight: 36).accessibilityIdentifier("tutorial-skip")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if readOnly { Label("버튼 위치 안내", systemImage: "eye").font(.caption.weight(.semibold)).foregroundStyle(SolfegeTheme.violet) }
                    Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text(message).font(.body).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                    if let task { Text(task).font(.subheadline.weight(.semibold)).foregroundStyle(canAdvance ? SolfegeTheme.green : SolfegeTheme.violet).accessibilityIdentifier("tutorial-task") }
                    if readOnly { Text("안내 중에는 조작과 시간이 잠시 멈춰요.").font(.caption).foregroundStyle(SolfegeTheme.muted) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.scrollBounceBehavior(.basedOnSize).frame(maxHeight: .infinity)
            HStack {
                Button("이전", action: previous).disabled(page == 0).frame(minWidth: 48, minHeight: 44)
                Spacer()
                Button(page == count ? "안내 끝내기" : "다음", action: next)
                    .buttonStyle(PrimaryButton(compact: true)).disabled(!canAdvance)
                    .accessibilityIdentifier("tutorial-next")
            }
        }.padding(20).background(.white, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 5).foregroundStyle(SolfegeTheme.ink)
    }
}

@MainActor struct TutorialWalkthrough: View {
    let kind: TutorialKind
    let done: () -> Void
    @StateObject private var session: MiniTutorialSession
    @Environment(\.tutorialScope) private var scope
    @Environment(\.dynamicTypeSize) private var typeSize
    init(kind: TutorialKind, initialPage: Int = 0, done: @escaping () -> Void) {
        self.kind = kind; self.done = done
        let value = MiniTutorialSession(kind: kind)
        value.showPage(min(kind.steps.count, max(0, initialPage)))
        _session = StateObject(wrappedValue: value)
    }
    var body: some View {
        Group {
            if kind == .exam { WritingTutorialPreview(initialPage: session.page, done: done) }
            else { minigame }
        }.tint(SolfegeTheme.violet).accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, finish).accessibilityIdentifier("tutorial-overlay-\(kind.rawValue)")
    }
    private var minigame: some View {
        GeometryReader { geometry in
            let layout = MiniTutorialLayout(viewport: geometry.size, largeText: typeSize.isAccessibilitySize)
            ZStack {
                TutorialDemoScreen(session: session, close: finish)
                    .frame(width: layout.game.width, height: layout.game.height)
                    .position(x: layout.game.midX, y: layout.game.midY)
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .overlayPreferenceValue(TutorialAnchors.self) { anchors in
                    GeometryReader { proxy in
                        let holes = tutorialRects(session.highlights, anchors: anchors, proxy: proxy)
                        ZStack(alignment: .topLeading) {
                            SpotlightMask(holes: holes).fill(.black.opacity(0.50), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                            ForEach(holes.indices, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.9), lineWidth: 2)
                                    .frame(width: holes[i].width, height: holes[i].height).position(x: holes[i].midX, y: holes[i].midY).allowsHitTesting(false)
                            }
                            gestureHint(anchors: anchors, proxy: proxy)
                            coach.frame(width: layout.coach.width, height: layout.coach.height)
                                .position(x: layout.coach.midX, y: layout.coach.midY)
                        }
                    }
                }
        }.background(SolfegeTheme.background)
    }
    private var coach: some View {
        let step = session.page > 0 ? kind.steps[session.page-1] : nil
        let message: String
        if kind == .rhythmPuzzle && session.page == 3 {
            message = !session.didTap ? "강조된 조각을 먼저 터치해보세요.\n그다음에는 직접 끌어놓아볼 거예요." : !session.didDrag ? "조각에 손가락을 대고,\n강조된 빈칸까지 끌어놓아보세요." : "터치하거나 끌어놓으면\n리듬 조각을 입력할 수 있어요."
        } else { message = step?.message ?? kind.introduction }
        return TutorialCoachCard(page: session.page, count: kind.steps.count, title: step?.title ?? kind.title, message: message,
                                 task: session.taskCaption, canAdvance: session.canAdvance,
                                 previous: { move(-1) }, next: { if session.page == kind.steps.count { finish() } else { move(1) } }, skip: finish)
    }
    @ViewBuilder private func gestureHint(anchors: [TutorialTarget: Anchor<CGRect>], proxy: GeometryProxy) -> some View {
        if kind == .rhythmPuzzle, session.page == 3, session.didTap, !session.didDrag,
           let start = anchors[.rhythmDragTile], let end = anchors[.dropSlot] {
            TutorialFingerCue(from: proxy[start].center, to: proxy[end].center, curved: false).id("rhythm-drop")
        } else if kind == .rhythmPuzzle, session.page == 5, session.tieMode, !session.didConnect,
                  let start = anchors[.tieStart], let end = anchors[.tieEnd] {
            TutorialFingerCue(from: proxy[start].center, to: proxy[end].center, curved: true).id("rhythm-tie")
        }
    }
    private func move(_ delta: Int) {
        if delta > 0 && !session.canAdvance { return }
        session.showPage(min(kind.steps.count, max(0, session.page+delta)))
    }
    private func finish() { TutorialHistory.finish(kind, scope: scope); done() }
}

@MainActor private struct WritingTutorialGuide: View {
    let mode: StudyMode
    let anchors: [TutorialTarget: Anchor<CGRect>]
    let done: () -> Void
    @State private var page = 0
    @Environment(\.tutorialScope) private var scope
    @Environment(\.dynamicTypeSize) private var typeSize
    private var steps: [TutorialStep] { TutorialKind.writingSteps(mode: mode) }
    init(mode: StudyMode, anchors: [TutorialTarget: Anchor<CGRect>], initialPage: Int, done: @escaping () -> Void) {
        self.mode = mode; self.anchors = anchors; self.done = done
        _page = State(initialValue: min(TutorialKind.writingSteps(mode: mode).count, max(0, initialPage)))
    }
    var body: some View {
        GeometryReader { proxy in
            let step = page > 0 ? steps[page-1] : nil
            let target = step.map { value -> TutorialTarget in
                if value.target == .submit && anchors[.submit] == nil && anchors[.start] != nil { return .start }
                if value.target == .next && anchors[.next] == nil { return .progress }
                return value.target
            }
            let holes = tutorialRects(target.map { [$0] } ?? [], anchors: anchors, proxy: proxy)
            let layout = TutorialBubbleLayout(viewport: proxy.size, target: holes.first, preferredHeight: typeSize.isAccessibilitySize ? 440 : 340)
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle()).onTapGesture { }
                SpotlightMask(holes: holes).fill(.black.opacity(0.52), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                if let hole = holes.first {
                    RoundedRectangle(cornerRadius: 12).stroke(.white, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: hole.width, height: hole.height).position(x: hole.midX, y: hole.midY).allowsHitTesting(false)
                    Label("위치 안내", systemImage: "eye.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(SolfegeTheme.deepViolet)
                        .padding(.horizontal, 9).padding(.vertical, 5).background(.white, in: Capsule())
                        .position(x: min(max(64, hole.midX), proxy.size.width-64), y: max(18, hole.minY-17)).allowsHitTesting(false)
                }
                TutorialCoachCard(page: page, count: steps.count, title: step?.title ?? "시험 모드",
                                  message: guidance(step), readOnly: true,
                                  previous: { page = max(0, page-1) }, next: { if page == steps.count { finish() } else { page += 1 } }, skip: finish)
                    .frame(width: layout.frame.width, height: layout.frame.height).position(x: layout.frame.midX, y: layout.frame.midY)
            }
        }.accessibilityAddTraits(.isModal).accessibilityAction(.escape, finish).accessibilityIdentifier("tutorial-overlay-exam")
    }
    private func guidance(_ step: TutorialStep?) -> String {
        guard let step else { return TutorialKind.exam.introduction }
        if step.target == .submit && anchors[.submit] == nil && anchors[.start] != nil {
            return "청음을 시작하면 같은 자리에\n답안 제출 버튼이 표시돼요."
        }
        if step.target == .next && anchors[.next] == nil {
            return "필기 시간에는 화면 아래의 다음 구간 버튼으로\n바로 다음 연주를 들을 수 있어요."
        }
        return step.message
    }
    private func finish() { TutorialHistory.finish(.exam, scope: scope); done() }
}
private extension CGRect { var center: CGPoint { CGPoint(x: midX, y: midY) } }
struct TutorialFingerCue: View {
    let from: CGPoint; let to: CGPoint; var curved = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var began = Date()
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/30, paused: reduceMotion)) { context in
            let elapsed = context.date.timeIntervalSince(began).truncatingRemainder(dividingBy: 2.6)
            let raw = reduceMotion ? 0.5 : min(1, max(0, (elapsed-0.35)/1.5))
            let t = raw*raw*(3-2*raw)
            let point = CGPoint(x: from.x+(to.x-from.x)*t, y: from.y+(to.y-from.y)*t + (curved ? sin(t * .pi)*22 : -sin(t * .pi)*12))
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: from)
                    path.addQuadCurve(to: to, control: CGPoint(x: (from.x+to.x)/2, y: (from.y+to.y)/2+(curved ? 44 : -24)))
                }.stroke(SolfegeTheme.violet.opacity(0.7), style: StrokeStyle(lineWidth: 2.5, dash: [5, 5]))
                Image(systemName: "hand.point.up.left.fill").font(.system(size: 30))
                    .foregroundStyle(.white).shadow(color: SolfegeTheme.deepViolet.opacity(0.6), radius: 3)
                    .position(x: point.x+9, y: point.y+15)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
