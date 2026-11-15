import SwiftUI

// Approved Practice entry and 3 × 3 level grid in the shared Figma file.
struct PracticeEntryView: View {
    @ObservedObject var model: AppModel
    @State private var showHelp = false
    var body: some View {
        GeometryReader { geometry in
            let margin: CGFloat = geometry.size.width >= 700 ? 48 : 24
            let height = max(620, geometry.size.height - 72)
            VStack(spacing: 0) {
                PracticeNavigationBar(title: "Practice", backTitle: "홈", back: { model.navigate(.main) }, help: { showHelp = true })
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let record = model.resumablePractice {
                            resume(record).padding(.bottom, 26)
                        }
                        if model.pendingPracticeCreation {
                            Button("준비하던 문제 다시 열기") { Task { await model.recoverPending() } }
                                .font(.subheadline).padding(.bottom, 18)
                        }
                        Text("새로 연습하기").font(.system(size: 17, weight: .medium)).padding(.bottom, 16)
                        Button { model.navigate(.practiceLevels) } label: {
                            VStack(alignment: .leading) {
                                HStack {
                                    Text("Level 1–9").font(.system(size: 17, weight: .medium))
                                    Spacer()
                                    Image(systemName: "arrow.right").font(.system(size: 26))
                                }
                                Spacer()
                                Text("난이도 선택").font(.system(size: 38, weight: .bold))
                            }.padding(36).frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: min(model.resumablePractice == nil ? 420 : 358, height - 300))
                                .foregroundStyle(.white).contentShape(Rectangle())
                        }.buttonStyle(PracticeCardStyle(raised: true)).accessibilityIdentifier("practice-open-levels")
                        Spacer(minLength: 28)
                        Button { model.navigate(.classical) } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "pianokeys").font(.system(size: 28)).foregroundStyle(SolfegeTheme.muted).frame(width: 36)
                                Text("클래식").font(.system(size: 17, weight: .medium))
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 20)).foregroundStyle(SolfegeTheme.violet)
                            }.padding(.horizontal, 4).frame(minHeight: 80)
                                .overlay(alignment: .top) { Rectangle().fill(SolfegeTheme.keyEdge.opacity(0.65)).frame(height: 1) }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("practice-open-classical")
                    }.padding(.horizontal, margin).padding(.top, 24).padding(.bottom, 28)
                        .frame(minHeight: height, alignment: .topLeading)
                }.scrollBounceBehavior(.basedOnSize)
            }.frame(maxWidth: 1180).frame(maxWidth: .infinity).background(.white)
        }
        .foregroundStyle(SolfegeTheme.ink)
        .sheet(isPresented: $showHelp) { PracticeTutorialView { showHelp = false } }
        .accessibilityIdentifier("practice-entry")
    }
    private func resume(_ record: SessionRecord) -> some View {
        Button { Task { await model.open(record) } } label: {
            HStack(spacing: 16) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { resumeTitle; resumeDetail(record) }
                    VStack(alignment: .leading, spacing: 6) { resumeTitle; resumeDetail(record) }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 20)).foregroundStyle(SolfegeTheme.violet)
            }.frame(minHeight: 64).contentShape(Rectangle())
                .overlay(alignment: .bottom) { Rectangle().fill(SolfegeTheme.keyEdge.opacity(0.65)).frame(height: 1) }
        }.buttonStyle(.plain).accessibilityIdentifier("practice-resume")
    }
    private var resumeTitle: some View {
        Text("풀던 문제 이어서 하기").font(.system(size: 15, weight: .medium)).foregroundStyle(SolfegeTheme.muted)
    }
    private func resumeDetail(_ record: SessionRecord) -> some View {
        Text(record.attempt.question.title).font(.system(size: 16, weight: .medium)).lineLimit(1)
    }
}

struct PracticeLevelSelectionView: View {
    @ObservedObject var model: AppModel
    @State private var showHelp = false
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        GeometryReader { geometry in
            let columns = geometry.size.width >= 700 ? 3 : 2
            let margin: CGFloat = geometry.size.width >= 700 ? 48 : 24
            let rows = columns == 3 ? 3 : 5
            let cardHeight = typeSize.isAccessibilitySize ? 204 : min(204, max(145, (geometry.size.height - 144 - CGFloat(rows - 1) * 18) / CGFloat(rows)))
            VStack(spacing: 0) {
                PracticeNavigationBar(title: "난이도 선택", backTitle: "Practice", back: { model.navigate(.home) }, help: { showHelp = true })
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: columns), spacing: 18) {
                        ForEach(PracticeLevel.allCases) { level in
                            Button { model.selectPracticeLevel(level) } label: {
                                VStack(alignment: .leading) {
                                    HStack {
                                        Text("LEVEL").font(.system(size: 12, weight: .medium)).foregroundStyle(SolfegeTheme.muted)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.system(size: 20)).foregroundStyle(SolfegeTheme.violet)
                                    }
                                    Spacer()
                                    Text("\(level.number)").font(.system(size: 48, weight: .medium))
                                }.padding(.horizontal, 28).padding(.vertical, 24)
                                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: cardHeight)
                                    .contentShape(RoundedRectangle(cornerRadius: 20))
                            }.buttonStyle(PracticeCardStyle()).accessibilityLabel("Level \(level.number)")
                                .accessibilityIdentifier("practice-level-\(level.rawValue)")
                        }
                    }.padding(.horizontal, margin).padding(.vertical, 36)
                }.scrollBounceBehavior(.basedOnSize)
            }.frame(maxWidth: 1180).frame(maxWidth: .infinity).background(.white)
        }
        .foregroundStyle(SolfegeTheme.ink)
        .sheet(isPresented: $showHelp) { PracticeTutorialView { showHelp = false } }
        .accessibilityIdentifier("practice-level-selection")
    }
}

private struct PracticeNavigationBar: View {
    let title: String
    let backTitle: String
    let back: () -> Void
    let help: () -> Void
    var body: some View {
        ZStack {
            Text(title).font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
            HStack {
                Button(action: back) {
                    HStack(spacing: 6) { Image(systemName: "chevron.left"); Text(backTitle) }.frame(minHeight: 44)
                }.accessibilityIdentifier("practice-back")
                Spacer()
                Button(action: help) {
                    Text("?").font(.system(size: 19, weight: .medium)).frame(width: 38, height: 38)
                        .overlay(Circle().stroke(SolfegeTheme.keyEdge.opacity(0.65), lineWidth: 1))
                        .frame(width: 44, height: 44)
                }.accessibilityLabel("연습 모드 안내").accessibilityIdentifier("practice-help")
            }.font(.system(size: 16)).foregroundStyle(SolfegeTheme.violet)
        }.padding(.horizontal, 28).frame(height: 72)
    }
}

private struct PracticeCardStyle: ButtonStyle {
    var raised = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: raised ? 24 : 20)
        return configuration.label
            .background(raised ? SolfegeTheme.violet : configuration.isPressed ? SolfegeTheme.keyPressed : .white, in: shape)
            .overlay { if !raised { shape.stroke(SolfegeTheme.keyEdge.opacity(0.65), lineWidth: 1) } }
            .shadow(color: raised ? SolfegeTheme.deepViolet : .clear, radius: 0, y: configuration.isPressed ? 1 : 5)
            .offset(y: raised && configuration.isPressed && !reduceMotion ? 4 : 0)
    }
}

struct PracticeTutorialView: View {
    let done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack { Text("연습 모드").font(.title2.bold()); Spacer(); Button("닫기", action: done) }
            Label("난이도를 고르고 문제를 선택하세요.", systemImage: "square.grid.3x3")
            Label("선율을 듣고 Apple Pencil로 악보를 적으세요.", systemImage: "pencil.tip")
            Label("정답과 비교하며 틀린 마디를 직접 표시하세요.", systemImage: "checkmark.square")
            Text("풀던 문제는 하나만 이어서 할 수 있어요. 새 연습을 시작하면 이전 문제를 대신해요.")
                .font(.subheadline).foregroundStyle(SolfegeTheme.muted)
            Button("확인", action: done).buttonStyle(PrimaryButton()).frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(32).foregroundStyle(SolfegeTheme.ink)
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}
