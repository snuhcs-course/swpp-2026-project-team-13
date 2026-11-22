import SwiftUI

// The live writing screen and the pre-selection read-only guide use these exact
// layout components, rather than maintaining a second imitation of the screen.
struct WritingScreenLayout<Header: View, Warning: View, Tools: View, Sheet: View, Footer: View>: View {
    let header: Header; let warning: Warning; let tools: Tools; let sheet: Sheet; let footer: Footer
    init(@ViewBuilder header: () -> Header, @ViewBuilder warning: () -> Warning,
         @ViewBuilder tools: () -> Tools, @ViewBuilder sheet: () -> Sheet, @ViewBuilder footer: () -> Footer) {
        self.header = header(); self.warning = warning(); self.tools = tools(); self.sheet = sheet(); self.footer = footer()
    }
    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 28).padding(.top, 6).padding(.bottom, 12)
            warning
            tools.padding(.horizontal, 28).padding(.bottom, 12)
            sheet.padding(.horizontal, 28)
            footer.padding(.horizontal, 28).padding(.vertical, 16)
        }.background(SolfegeTheme.background.ignoresSafeArea())
    }
}

struct WritingScreenHeader<Meta: View, Progress: View, Clock: View>: View {
    let meta: Meta; let progress: Progress; let clock: Clock
    init(@ViewBuilder meta: () -> Meta, @ViewBuilder progress: () -> Progress, @ViewBuilder clock: () -> Clock) {
        self.meta = meta(); self.progress = progress(); self.clock = clock()
    }
    var body: some View {
        HStack(spacing: 20) {
            meta.fixedSize().frame(maxWidth: .infinity, alignment: .leading)
            progress.frame(minWidth: 360, idealWidth: 560, maxWidth: 560).layoutPriority(1)
            clock.fixedSize().frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct WritingQuestionMeta: View {
    let key: KeySignature
    let meter: TimeSignature
    let tempo: String
    var body: some View {
        HStack(spacing: 6) {
            chip(key.label); chip("\(meter.numerator)/\(meter.denominator)박자"); chip(tempo)
        }.accessibilityElement(children: .combine).accessibilityIdentifier("question-meta")
    }
    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .bold)).foregroundStyle(SolfegeTheme.ink)
            .padding(.horizontal, 11).padding(.vertical, 4).background(SolfegeTheme.soft, in: Capsule())
    }
}

struct WritingToolsRow: View {
    var erasing = false
    var penWidth: CGFloat = 2
    var canUndo = false
    var canRedo = false
    var pen: () -> Void = {}
    var erase: () -> Void = {}
    var chooseWidth: (CGFloat) -> Void = { _ in }
    var undo: () -> Void = {}
    var redo: () -> Void = {}
    private struct PenWidth { let width: CGFloat; let label: String; let dot: CGFloat }
    private static var widths: [PenWidth] {
        [.init(width: 1.5, label: "가는 펜", dot: 4), .init(width: 2, label: "보통 펜", dot: 8), .init(width: 4.5, label: "굵은 펜", dot: 16)]
    }
    var body: some View {
        HStack(spacing: 4) {
            tool("펜", icon: "pencil.tip", selected: !erasing, action: pen)
            tool("지우개", icon: "eraser", selected: erasing, action: erase)
            divider
            ForEach(Self.widths, id: \.width) { option in
                let selected = penWidth == option.width
                Button { chooseWidth(option.width) } label: {
                    Circle().fill(selected ? SolfegeTheme.deepViolet : SolfegeTheme.ink)
                        .frame(width: option.dot, height: option.dot).frame(width: 38, height: 38)
                        .background(selected ? SolfegeTheme.soft : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? SolfegeTheme.violet : .clear, lineWidth: 2))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(option.label)
                    .accessibilityAddTraits(selected ? .isSelected : []).accessibilityIdentifier("pen-width-\(option.width)")
            }
            divider
            Button(action: undo) { Image(systemName: "arrow.uturn.backward").frame(width: 36, height: 36) }
                .disabled(!canUndo).accessibilityLabel("실행 취소")
            Button(action: redo) { Image(systemName: "arrow.uturn.forward").frame(width: 36, height: 36) }
                .disabled(!canRedo).accessibilityLabel("다시 실행")
            Spacer(minLength: 0)
        }.font(.subheadline).foregroundStyle(SolfegeTheme.ink)
    }
    private var divider: some View {
        Rectangle().fill(SolfegeTheme.keyEdge).frame(width: 1, height: 22).padding(.horizontal, 6)
    }
    private func tool(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 14, weight: selected ? .bold : .regular))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(selected ? SolfegeTheme.soft : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).foregroundStyle(selected ? SolfegeTheme.deepViolet : SolfegeTheme.softInk)
    }
}

struct WritingSheetFrame<Sheet: View>: View {
    let displayHeight: Int
    @ViewBuilder var sheet: (CGFloat) -> Sheet
    var body: some View {
        GeometryReader { proxy in
            let width = max(0, min(proxy.size.width, proxy.size.height*1330/Double(displayHeight)))
            sheet(width).frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }
}

struct WritingScreenFooter<Actions: View>: View {
    var frozen = false
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack(spacing: 8) {
            Label(frozen ? "현재 답안 고정 · 제출 복구 가능" : "이 iPad에 필기 자동 저장", systemImage: frozen ? "lock" : "checkmark.icloud")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            actions()
        }
    }
}

// Offline rendering fixture for the test gallery. Production help is only
// opened over ExamView; entry, library and ready screens never present this.
@MainActor struct WritingTutorialPreview: View {
    var mode: StudyMode = .exam
    var initialPage = 0
    let done: () -> Void
    private static let question: Question? = {
        let questions: [Question]? = try? DemoContent.decode("catalog", forceSmall: true)
        return questions?.first
    }()
    private static let template: UIImage? = {
        guard let q = question, let data = try? Bundled.data(q.sheetLayout.id, ext: "pngdata") else { return nil }
        return UIImage(data: data)
    }()
    private var cursor: PlaybackCursor { PlaybackCursor(index: 1, phase: "gap", remainingWaitMs: 20000) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
                Spacer(); Text("시험 모드").font(.system(size: 20, weight: .bold)); Spacer()
                TutorialHelpButton(label: "시험 모드 안내", action: {})
            }.padding(.horizontal, 28).frame(height: 44)
            WritingScreenLayout {
                WritingScreenHeader {
                    if let q = Self.question {
                        WritingQuestionMeta(key: q.keySignature, meter: q.timeSignature, tempo: "♩ = 80")
                    }
                } progress: {
                    SegmentProgressBar(cursor: cursor).tutorialTarget(.progress)
                } clock: {
                    WritingTimer(cursor: cursor, plan: nil, isPlaying: false).tutorialTarget(.timer)
                }
            } warning: { EmptyView() } tools: {
                WritingToolsRow().tutorialTarget(.tools)
            } sheet: {
                WritingSheetFrame(displayHeight: Self.question?.sheetLayout.displayHeight ?? 846) { width in
                    if let image = Self.template {
                        Image(uiImage: image).resizable().frame(width: width, height: width*846/1330)
                            .frame(height: width*CGFloat(Self.question?.sheetLayout.displayHeight ?? 846)/1330, alignment: .top)
                            .clipped().background(.white).clipShape(RoundedRectangle(cornerRadius: 16))
                            .tutorialTarget(.notation)
                    }
                }
            } footer: {
                WritingScreenFooter {
                    if mode == .practice {
                        Button {} label: { Label("일시 정지", systemImage: "pause.fill") }.buttonStyle(SecondaryActionButton()).tutorialTarget(.playPause)
                    }
                    Button {} label: { Label("다음 구간", systemImage: "forward.end.fill") }.buttonStyle(SecondaryActionButton()).frame(width: 150).tutorialTarget(.next)
                    Button("답안 제출", action: {}).buttonStyle(PrimaryButton()).frame(width: 150).tutorialTarget(.submit)
                }
            }
        }.background(SolfegeTheme.background.ignoresSafeArea())
            .writingTutorial(isPresented: true, mode: mode, initialPage: initialPage, done: done)
    }
}
