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
    static func hasSeen(_ kind: TutorialKind, scope: String?) -> Bool {
        store(scope: scope)?.hasSeen(kind) ?? false
    }
    static func finish(_ kind: TutorialKind, scope: String?) {
        // A write failure only means the guide will be offered again next time.
        try? store(scope: scope)?.markSeen(kind)
    }
}

struct TutorialHelpButton: View {
    var label = "게임 방법"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 25, weight: .regular))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(SolfegeTheme.violet)
        .accessibilityLabel(label)
    }
}

enum TutorialTarget: Hashable {
    case start, replay, keyboard, firstKey, notation, choices, tie, submit
    case progress, timer, tools, next
}
struct TutorialStep {
    let target: TutorialTarget
    let title: String
    let message: String
}
extension TutorialKind {
    var introduction: String {
        switch self {
        case .echoDragon: return "드래곤이 노래하는 두 음의 간격을 듣고,\n다른 시작음에서 같은 간격으로 연주해요."
        case .memoryRun: return "두 마디 선율을 기억하고,\n건반으로 다시 연주해요."
        case .rhythmPuzzle: return "두 마디를 듣고,\n리듬 조각을 골라 악보를 완성해요."
        case .exam: return "음원을 듣고 빈 오선에 악보를 적어요.\n제출하면 AI 채점과 피드백을 받아요."
        }
    }
    var steps: [TutorialStep] {
        switch self {
        case .echoDragon: return [
            .init(target: .start, title: "먼저 들어볼까요?", message: "시작을 누르면 드래곤이 노래해요.\n두 음 사이의 간격을 들어보세요."),
            .init(target: .replay, title: "다시 들어도 괜찮아요", message: "간격이 헷갈리면 여러 번 다시 들어보세요."),
            .init(target: .firstKey, title: "표시된 첫 음부터", message: "표시된 건반부터 눌러요.\n누른 건반은 색이 바뀌어요."),
            .init(target: .keyboard, title: "같은 간격으로 답해요", message: "드래곤과 같은 방향·간격으로\n두 번째 음을 눌러요."),
            .init(target: .submit, title: "내 답을 들어보세요", message: "제출하면 내가 고른 두 음이 나와요.\n틀리면 하트가 하나 줄어요.")
        ]
        case .memoryRun: return [
            .init(target: .start, title: "두 마디를 기억해요", message: "시작을 누르고 선율을 들어보세요.\n두 마디가 연속해서 나와요."),
            .init(target: .replay, title: "필요하면 다시 들어요", message: "왼쪽은 선율만, 오른쪽은\n예비박과 함께 다시 들어요."),
            .init(target: .keyboard, title: "들은 음을 채워보세요", message: "건반을 누르면 음표가 순서대로 채워져요.\n들은 음높이를 차례대로 눌러보세요."),
            .init(target: .notation, title: "마디를 골라 고쳐요", message: "고치고 싶은 마디를 누르세요.\n새 음을 누르면 그 마디부터 다시 입력해요."),
            .init(target: .submit, title: "입력이 끝났다면", message: "제출하고 결과를 확인해요.\n틀렸다면 같은 화면에서 고쳐보세요.")
        ]
        case .rhythmPuzzle: return [
            .init(target: .start, title: "리듬에 귀를 기울여요", message: "예비박 다음에 두 마디가 나와요.\n리듬의 흐름을 들어보세요."),
            .init(target: .replay, title: "필요하면 다시 들어요", message: "왼쪽은 선율만, 오른쪽은\n예비박과 함께 다시 들어요."),
            .init(target: .choices, title: "조각을 넣어보세요", message: "누르면 빈칸에 순서대로 들어가요.\n원하는 칸으로 끌어놓을 수도 있어요."),
            .init(target: .notation, title: "넣은 조각도 옮길 수 있어요", message: "누르면 지워져요. 다른 칸으로 옮기거나\n악보 밖으로 끌어내 지울 수도 있어요."),
            .init(target: .tie, title: "이어지는 음은 타이로", message: "타이를 켜고, 이어줄 두 조각을\n차례로 눌러요."),
            .init(target: .submit, title: "리듬을 완성했다면", message: "제출하고 결과를 확인해요.\n틀렸다면 고쳐서 다시 도전해 보세요.")
        ]
        case .exam: return [
            .init(target: .progress, title: "구간별로 들어요", message: "스케일 다음에 구간별 연주가 이어져요.\n지금 진행 중인 구간을 확인해요."),
            .init(target: .timer, title: "지금은 필기 시간", message: "현재 구간의 남은 필기 시간이에요.\n시간이 끝나면 다음 구간으로 넘어가요."),
            .init(target: .tools, title: "쓰고, 고쳐보세요", message: "펜과 지우개를 골라 악보에 적어요.\n점을 누르면 펜 굵기를 바꿀 수 있어요."),
            .init(target: .notation, title: "들은 선율을 적어요", message: "Apple Pencil로 악보를 적어보세요.\n이 예시 화면의 필기는 저장되지 않아요."),
            .init(target: .next, title: "필기를 마쳤다면", message: "필기 시간에는 다음 구간으로 넘어갈 수 있어요.\n연주 중에는 기다려주세요."),
            .init(target: .submit, title: "마지막으로 확인해요", message: "답안을 제출하면 AI가 채점해요.\n제출 후에는 답안을 수정할 수 없어요.")
        ]
        }
    }
}

private struct TutorialAnchors: PreferenceKey {
    static var defaultValue: [TutorialTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TutorialTarget: Anchor<CGRect>], nextValue: () -> [TutorialTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
extension View {
    func tutorialTarget(_ target: TutorialTarget) -> some View {
        transformAnchorPreference(key: TutorialAnchors.self, value: .bounds) { value, anchor in value[target] = anchor }
    }
}
private struct SpotlightMask: Shape {
    let hole: CGRect?
    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        if let hole { p.addRoundedRect(in: hole, cornerSize: CGSize(width: 16, height: 16)) }
        return p
    }
}

// All four guides use this component. The demo underneath owns only temporary
// local state: it cannot submit an attempt, consume lives or write game records.
struct TutorialWalkthrough: View {
    let kind: TutorialKind
    var runningExam = false
    let done: () -> Void
    @Environment(\.tutorialScope) private var scope
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var page: Int
    init(kind: TutorialKind, runningExam: Bool = false, initialPage: Int = 0, done: @escaping () -> Void) {
        self.kind = kind; self.runningExam = runningExam; self.done = done
        _page = State(initialValue: min(kind.steps.count, max(0, initialPage)))
    }
    private var step: TutorialStep? { page > 0 ? kind.steps[page-1] : nil }
    var body: some View {
        TutorialDemoScreen(kind: kind, target: step?.target, close: finish)
            .overlayPreferenceValue(TutorialAnchors.self) { anchors in
                GeometryReader { proxy in
                    let visible = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 8, dy: 8)
                    let hole = step.flatMap { anchors[$0.target] }.map { proxy[$0].insetBy(dx: -7, dy: -7).intersection(visible) }
                    let layout = TutorialBubbleLayout(viewport: proxy.size, target: hole, preferredHeight: typeSize.isAccessibilitySize ? 420 : 300)
                    ZStack(alignment: .topLeading) {
                        SpotlightMask(hole: hole).fill(.black.opacity(0.52), style: FillStyle(eoFill: true))
                            .contentShape(SpotlightMask(hole: hole), eoFill: true)
                            .onTapGesture { }
                            .accessibilityHidden(true)
                        if let hole {
                            TutorialPointer(bubble: layout.frame, target: hole).fill(.white)
                                .allowsHitTesting(false).accessibilityHidden(true)
                            RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.9), lineWidth: 2)
                                .frame(width: hole.width, height: hole.height).position(x: hole.midX, y: hole.midY)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                        bubble
                            .frame(width: layout.frame.width, height: layout.frame.height)
                            .position(x: layout.frame.midX, y: layout.frame.midY)
                    }
                }
            }
            .background(SolfegeTheme.background).tint(SolfegeTheme.violet)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, finish)
            .accessibilityIdentifier("tutorial-overlay-\(kind.rawValue)")
    }
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(page == 0 ? kind.title : "\(page) / \(kind.steps.count)")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(SolfegeTheme.violet)
                Spacer()
                Button("건너뛰기", action: finish).font(.subheadline).frame(minHeight: 44)
                    .accessibilityIdentifier("tutorial-skip")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(step?.title ?? kind.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text(step?.message ?? kind.introduction).font(.body).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                    if runningExam {
                        Text("실제 시험 시간은 계속 흘러요.").font(.caption).foregroundStyle(SolfegeTheme.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.scrollBounceBehavior(.basedOnSize).frame(maxHeight: .infinity)
            HStack {
                Button("이전") { move(-1) }.disabled(page == 0).frame(minWidth: 48, minHeight: 44)
                Spacer()
                Button(page == kind.steps.count ? "안내 끝내기" : "다음") {
                    if page == kind.steps.count { finish() } else { move(1) }
                }.buttonStyle(PrimaryButton(compact: true)).accessibilityIdentifier("tutorial-next")
            }
        }
        .padding(22).background(.white, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 6)
        .foregroundStyle(SolfegeTheme.ink)
    }
    private func move(_ offset: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { page += offset }
    }
    private func finish() { TutorialHistory.finish(kind, scope: scope); done() }
}
private struct TutorialPointer: Shape {
    let bubble: CGRect
    let target: CGRect
    func path(in rect: CGRect) -> Path {
        var p = Path()
        if bubble.intersects(target) { return p }
        if bubble.minY >= target.maxY {
            let x = min(max(target.midX, bubble.minX+24), bubble.maxX-24)
            p.move(to: CGPoint(x: x-9, y: bubble.minY+1)); p.addLine(to: CGPoint(x: x, y: bubble.minY-11)); p.addLine(to: CGPoint(x: x+9, y: bubble.minY+1))
        } else if bubble.maxY <= target.minY {
            let x = min(max(target.midX, bubble.minX+24), bubble.maxX-24)
            p.move(to: CGPoint(x: x-9, y: bubble.maxY-1)); p.addLine(to: CGPoint(x: x, y: bubble.maxY+11)); p.addLine(to: CGPoint(x: x+9, y: bubble.maxY-1))
        } else {
            let y = min(max(target.midY, bubble.minY+24), bubble.maxY-24)
            let x = bubble.minX >= target.maxX ? bubble.minX : bubble.maxX
            let tip = bubble.minX >= target.maxX ? x-11 : x+11
            p.move(to: CGPoint(x: x, y: y-9)); p.addLine(to: CGPoint(x: tip, y: y)); p.addLine(to: CGPoint(x: x, y: y+9))
        }
        p.closeSubpath(); return p
    }
}
