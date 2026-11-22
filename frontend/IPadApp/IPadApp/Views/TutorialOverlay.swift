import SwiftUI

private struct TutorialScopeKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct WritingTutorialHostKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var tutorialScope: String? {
        get { self[TutorialScopeKey.self] }
        set { self[TutorialScopeKey.self] = newValue }
    }
    var writingTutorialHosted: Bool {
        get { self[WritingTutorialHostKey.self] }
        set { self[WritingTutorialHostKey.self] = newValue }
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
struct TutorialStep {
    let target: TutorialTarget
    let title: String
    let message: String
    var footnote: String? = nil
}
extension TutorialKind {
    var introduction: String {
        switch self {
        case .echoDragon: return "드래곤이 노래하는 두 음의 간격을 듣고,\n다른 시작음에서 같은 음정으로 연주해요."
        case .memoryRun: return "두 마디 선율을 기억하고,\n건반으로 다시 연주해요."
        case .rhythmPuzzle: return "두 마디를 듣고,\n리듬 조각을 골라 악보를 완성해요."
        case .exam: return "8마디 단선율을 들으면서,\n빈 오선 악보를 완성해요."
        }
    }
    var steps: [TutorialStep] {
        switch self {
        case .echoDragon: return [
            .init(target: .start, title: "먼저 들어볼까요?", message: "시작을 누르면 드래곤이 노래해요.\n두 음 사이의 간격을 들어보세요."),
            .init(target: .replay, title: "다시 들어도 괜찮아요", message: "간격이 헷갈리면 여러 번 다시 들어보세요."),
            .init(target: .firstKey, title: "다른 음높이에서 따라해요", message: "표시된 건반부터 눌러요.\n누른 건반은 색이 바뀌어요."),
            .init(target: .keyboard, title: "같은 음정으로 답해요", message: "드래곤과 같은 음정으로\n두 번째 음을 눌러요."),
            .init(target: .submit, title: "드래곤에게 답해볼까요?", message: "제출을 눌러서 드래곤의 반응을 확인해보세요.")
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
            .init(target: .choices, title: "리듬 조각을 넣어보세요", message: ""),
            .init(target: .notation, title: "입력된 리듬 조각도 옮길 수 있어요", message: "조각을 터치하면 지워져요.\n드래그해서 다른 칸으로 옮기거나,\n악보 밖으로 끌어내 지울 수도 있어요."),
            .init(target: .tie, title: "이어지는 음은 타이로", message: "타이를 켜고, 두 조각을 손가락으로 이어줘요."),
            .init(target: .submit, title: "리듬을 완성했다면", message: "제출하고 결과를 확인해요.\n틀렸다면 고쳐서 다시 도전해 보세요.")
        ]
        case .exam: return Self.writingSteps(mode: .exam)
        }
    }
    static func writingSteps(mode: StudyMode) -> [TutorialStep] {
        [
            .init(target: .progress, title: "구간별로 들어요", message: "스케일을 들은 뒤,\n표시된 마디 구간을 순서대로 들어요."),
            .init(target: .timer, title: "남은 필기 시간을 확인해요", message: "각 구간 사이에는 20초의 필기 시간이 주어져요.\n시간이 끝나면 다음 구간으로 넘어가요.\n마지막 1~8마디 재생 후에는 제출 전까지 2분이 주어져요."),
            .init(target: .tools, title: "쓰고, 고쳐보세요", message: "펜과 지우개를 전환하거나,\n펜 굵기를 변경할 수 있어요.", footnote: "더블 탭으로도 펜/지우개 전환이 가능해요.\n(Apple Pencil Pro 또는 Apple Pencil 2세대)"),
            .init(target: .notation, title: "들은 선율을 적어요", message: "Apple Pencil로 빈 오선에 악보를 그려요."),
            .init(target: .progress, title: "Practice와 Exam의 차이",
                  message: "Practice 모드에서는 구간을 터치하면\n해당 구간으로 바로 넘어갈 수 있어요.\nExam 모드에서는 구간을 되돌리거나\n진행을 일시정지할 수 없어요."),
            .init(target: .next, title: "구간 대기를 건너뛰고 싶다면", message: "일찍 필기를 마쳤다면,\n바로 다음 구간으로 넘어갈 수 있어요."),
            .init(target: .submit, title: "답안을 제출해요", message: "제출 후에는 답안을 수정할 수 없어요.")
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
    func writingTutorial(isPresented: Bool, mode: StudyMode, initialPage: Int = 0, rootHost: Bool = false, done: @escaping () -> Void) -> some View {
        modifier(WritingTutorialModifier(isPresented: isPresented, mode: mode, initialPage: initialPage, rootHost: rootHost, done: done))
    }
}
private struct WritingTutorialModifier: ViewModifier {
    let isPresented: Bool; let mode: StudyMode; let initialPage: Int; let rootHost: Bool; let done: () -> Void
    @Environment(\.writingTutorialHosted) private var hosted
    @ViewBuilder func body(content: Content) -> some View {
        if hosted && !rootHost { content }
        else {
            content.allowsHitTesting(!isPresented).accessibilityHidden(isPresented)
                .overlayPreferenceValue(TutorialAnchors.self) { anchors in
                    if isPresented {
                        WritingTutorialGuide(mode: mode, anchors: anchors, initialPage: initialPage, done: done)
                            .ignoresSafeArea()
                    }
                }
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
    var footnote: String? = nil
    var compact = false
    let previous: () -> Void; let next: () -> Void; let skip: () -> Void
    var body: some View {
        Group {
            if compact {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) { counter; heading }
                        ScrollView { explanation }.scrollBounceBehavior(.basedOnSize)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 4) { skipButton; navigation }
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { counter; Spacer(); skipButton }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) { heading; explanation }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.scrollBounceBehavior(.basedOnSize).frame(maxHeight: .infinity)
                    navigation
                }
            }
        }.padding(.horizontal, compact ? 14 : 20).padding(.vertical, compact ? 8 : 20)
            .background(.white, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 5).foregroundStyle(SolfegeTheme.ink)
            .accessibilityIdentifier("tutorial-coach")
    }
    private var counter: some View {
        Text(page == 0 ? "Tutorial" : "\(page) / \(count)")
            .font(.subheadline.weight(.semibold)).foregroundStyle(SolfegeTheme.violet).fixedSize()
    }
    private var heading: some View {
        Text(title).font(compact ? .system(size: 20, weight: .bold) : .title2.bold()).accessibilityAddTraits(.isHeader)
    }
    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.isEmpty {
                Text(LocalizedStringKey(message)).font(compact ? .system(size: 16) : .body).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            if let task {
                Text(task).font(.subheadline.weight(.semibold)).foregroundStyle(SolfegeTheme.violet)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("tutorial-task")
            }
            if let footnote { Text(footnote).font(.caption).foregroundStyle(SolfegeTheme.muted).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var skipButton: some View {
        Button("건너뛰기", action: skip).buttonStyle(.plain)
            .font(.subheadline).frame(minHeight: 32).accessibilityIdentifier("tutorial-skip")
    }
    private var navigation: some View {
        HStack(spacing: 12) {
            Button("이전", action: previous).buttonStyle(.plain).disabled(page == 0).frame(minWidth: 44, minHeight: 44)
            if !compact { Spacer() }
            Button(page == count ? "안내 끝내기" : "다음", action: next)
                .buttonStyle(PrimaryButton(compact: true)).disabled(!canAdvance).accessibilityIdentifier("tutorial-next")
        }
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
    init(session: MiniTutorialSession, done: @escaping () -> Void) {
        self.kind = session.kind; self.done = done
        _session = StateObject(wrappedValue: session)
    }
    var body: some View {
        Group {
            if kind == .exam { WritingTutorialPreview(initialPage: session.page, done: done) }
            else { minigame }
        }.tint(SolfegeTheme.violet).accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, finish).accessibilityIdentifier("tutorial-overlay-\(kind.rawValue)")
    }
    private var minigame: some View {
        TutorialDemoScreen(session: session, close: finish)
                .overlayPreferenceValue(TutorialAnchors.self) { anchors in
                    GeometryReader { proxy in
                        let holes = tutorialRects(session.highlights, anchors: anchors, proxy: proxy)
                        let layout = TutorialPopupLayout(kind: kind, page: session.page, viewport: proxy.size,
                                                         anchors: anchors.mapValues { proxy[$0] }, largeText: typeSize.isAccessibilitySize)
                        ZStack(alignment: .topLeading) {
                            SpotlightMask(holes: holes).fill(.black.opacity(0.50), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                            ForEach(holes.indices, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.9), lineWidth: 2)
                                    .frame(width: holes[i].width, height: holes[i].height).position(x: holes[i].midX, y: holes[i].midY).allowsHitTesting(false)
                            }
                            gestureHint(anchors: anchors, proxy: proxy)
                            if layout.isResolved {
                                coach(compact: layout.compact)
                                    .frame(width: layout.frame.width, height: layout.frame.height)
                                    .position(x: layout.frame.midX, y: layout.frame.midY)
                                    .id(session.page).transition(.identity)
                                    .transaction { transaction in
                                        transaction.animation = nil; transaction.disablesAnimations = true
                                    }
                            }
                        }
                    }
                }
                .background(SolfegeTheme.background.ignoresSafeArea())
    }
    private func coach(compact: Bool) -> some View {
        let step = session.page > 0 ? kind.steps[session.page-1] : nil
        let message: String
        if kind == .rhythmPuzzle && session.page == 3 {
            message = session.didDrag ? "리듬 조각을 **터치하거나 끌어놓아서** 악보를 채워 보세요." : ""
        } else { message = step?.message ?? kind.introduction }
        return TutorialCoachCard(page: session.page, count: kind.steps.count, title: step?.title ?? kind.title, message: message,
                                 task: session.taskCaption, canAdvance: session.canAdvance, compact: compact,
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
                return value.target
            }
            let targets = page == 5 && mode == .practice ? [TutorialTarget.progress, .playPause] : target.map { [$0] } ?? []
            let holes = tutorialRects(targets, anchors: anchors, proxy: proxy)
            let layout = TutorialPopupLayout(kind: .exam, page: page, viewport: proxy.size,
                                             anchors: anchors.mapValues { proxy[$0] }, largeText: typeSize.isAccessibilitySize)
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle()).onTapGesture { }
                SpotlightMask(holes: holes).fill(.black.opacity(0.52), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                ForEach(holes.indices, id: \.self) { i in
                    let hole = holes[i]
                    RoundedRectangle(cornerRadius: 12).stroke(.white, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: hole.width, height: hole.height).position(x: hole.midX, y: hole.midY).allowsHitTesting(false)
                }
                if layout.isResolved {
                    TutorialCoachCard(page: page, count: steps.count, title: step?.title ?? "시험 모드",
                                      message: step?.message ?? TutorialKind.exam.introduction, footnote: step?.footnote,
                                      previous: { page = max(0, page-1) }, next: { if page == steps.count { finish() } else { page += 1 } }, skip: finish)
                        .frame(width: layout.frame.width, height: layout.frame.height).position(x: layout.frame.midX, y: layout.frame.midY)
                        .id(page).transition(.identity)
                        .transaction { transaction in
                            transaction.animation = nil; transaction.disablesAnimations = true
                        }
                }
            }
        }.accessibilityAddTraits(.isModal).accessibilityAction(.escape, finish).accessibilityIdentifier("tutorial-overlay-exam")
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
