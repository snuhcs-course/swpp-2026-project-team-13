import SwiftUI

struct HomeView: View {
    @ObservedObject var model: AppModel
    @State private var showKeys = false
    private var levelQuestions: [QuestionSummary] {
        guard let level = model.selectedPracticeLevel else { return [] }
        return model.questions.filter { $0.practiceLevel == level }
    }
    private var visibleQuestions: [QuestionSummary] {
        model.practiceFilter.apply(to: levelQuestions, completedQuestionIDs: model.completedPracticeQuestionIDs)
    }
    var body: some View {
        GeometryReader { geometry in
            let margin: CGFloat = geometry.size.width >= 1000 ? 48 : 24
            let width = min(1180, geometry.size.width) - 2 * margin
            let compact = width < 700
            VStack(spacing: 0) {
                navigation
                VStack(spacing: 24) {
                    filterBar(width: width, popoverHeight: min(600, max(320, geometry.size.height - 100)))
                    if model.pendingPracticeCreation {
                        Button("준비하던 문제 다시 열기") { Task { await model.recoverPending() } }.font(.subheadline)
                    }
                    if !model.connected {
                        ContentUnavailableView("학습 공간에 연결해 주세요", systemImage: "network")
                        Button("연결 설정") { model.navigate(.settings) }.buttonStyle(PrimaryButton())
                    } else if model.selectedPracticeLevel == nil {
                        ContentUnavailableView("난이도를 선택해 주세요", systemImage: "square.grid.3x3")
                        Button("난이도 선택") { model.navigate(.practiceLevels) }.buttonStyle(PrimaryButton())
                    } else {
                        VStack(spacing: 0) {
                            columnHeadings(width: width, compact: compact)
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(visibleQuestions) { question in
                                        Button { Task { await model.choose(question.id, mode: .practice) } } label: {
                                            PracticeBankRow(question: question,
                                                completed: model.completedPracticeQuestionIDs.contains(question.id),
                                                width: width, compact: compact)
                                        }.buttonStyle(.plain)
                                            .accessibilityIdentifier("practice-question-\(question.id.uuidString.lowercased())")
                                    }
                                    if visibleQuestions.isEmpty { emptyState.padding(.vertical, 48) }
                                }
                            }.refreshable { await model.refreshLibrary(destination: .practiceQuestions) }
                        }
                    }
                }.padding(.horizontal, margin).padding(.top, 24).padding(.bottom, 20).frame(maxHeight: .infinity, alignment: .top)
            }.frame(maxWidth: 1180).frame(maxWidth: .infinity).background(.white)
        }.foregroundStyle(SolfegeTheme.ink).accessibilityIdentifier("practice-question-bank")
    }
    private var navigation: some View {
        ZStack {
            Text(model.selectedPracticeLevel.map { "Practice · \($0.title)" } ?? "Practice")
                .font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
            HStack {
                Button { model.navigate(.practiceLevels) } label: {
                    HStack(spacing: 6) { Image(systemName: "chevron.left"); Text("난이도 선택") }.frame(minHeight: 44)
                }.accessibilityIdentifier("practice-bank-back")
                Spacer()
                Button { } label: {
                    Text("?").font(.system(size: 19, weight: .medium)).frame(width: 38, height: 38)
                        .overlay(Circle().stroke(SolfegeTheme.keyEdge.opacity(0.65), lineWidth: 1))
                        .frame(width: 44, height: 44)
                }.accessibilityLabel("튜토리얼 준비 중").accessibilityIdentifier("practice-bank-help")
            }.font(.system(size: 16)).foregroundStyle(SolfegeTheme.violet)
        }.padding(.horizontal, 28).frame(height: 72)
    }
    private func filterBar(width: CGFloat, popoverHeight: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { filters(width: width, height: popoverHeight); Spacer(minLength: 24); completedToggle }
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) { filters(width: width, height: popoverHeight) }
                HStack { Spacer(); completedToggle }
            }
        }
    }
    private func filters(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 12) {
            Menu {
                Picker("박자", selection: $model.practiceFilter.meter) {
                    Text("전체").tag(TimeSignature?.none)
                    ForEach(QuestionFilter.meterOptions(in: levelQuestions), id: \.self) { meter in
                        Text(meter.label).tag(TimeSignature?.some(meter))
                    }
                }
            } label: { PracticeFilterLabel(title: "박자", value: model.practiceFilter.meter?.label ?? "전체", active: model.practiceFilter.meter != nil) }
                .accessibilityIdentifier("practice-filter-meter")
            Button { showKeys = true } label: {
                PracticeFilterLabel(title: "조성", value: model.practiceFilter.keySelection.label, active: model.practiceFilter.keySelection != .all)
            }.buttonStyle(.plain).accessibilityIdentifier("practice-filter-key")
                .popover(isPresented: $showKeys, arrowEdge: .top) {
                    PracticeKeyFilterView(selection: $model.practiceFilter.keySelection, questions: levelQuestions,
                        width: min(472, max(280, width)), height: height) { showKeys = false }
                        .presentationCompactAdaptation(.popover)
                }
            Menu {
                Picker("난이도 정렬", selection: $model.practiceFilter.sortOrder) {
                    ForEach(QuestionFilter.SortOrder.allCases) { order in
                        Text(order == .ascending ? "난이도 낮은순" : "난이도 높은순").tag(order)
                    }
                }
            } label: { PracticeFilterLabel(title: "난이도", value: model.practiceFilter.sortOrder.label, active: false) }
                .accessibilityIdentifier("practice-filter-sort")
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var completedToggle: some View {
        Toggle(isOn: $model.practiceFilter.showCompleted) { Text("완료된 문제 표시하기").font(.system(size: 14)) }
            .toggleStyle(PracticeCheckboxStyle()).fixedSize()
            .accessibilityIdentifier("practice-show-completed")
    }
    private func columnHeadings(width: CGFloat, compact: Bool) -> some View {
        HStack(spacing: 12) {
            if compact { Text("문제"); Spacer(); Text("난이도") }
            else {
                let columns = PracticeBankColumns(width: width)
                Text("문제").frame(width: columns.title, alignment: .leading)
                Text("조성").frame(width: columns.key, alignment: .leading)
                Text("박자").frame(width: columns.meter, alignment: .leading)
                Text("템포").frame(width: columns.tempo, alignment: .leading)
                Text("난이도").frame(width: columns.score, alignment: .trailing)
                Color.clear.frame(width: 20, height: 1)
            }
        }.font(.system(size: 13)).foregroundStyle(SolfegeTheme.muted)
            .padding(.horizontal, 24).frame(height: 36)
            .overlay(alignment: .bottom) { Rectangle().fill(SolfegeTheme.keyEdge.opacity(0.65)).frame(height: 1) }
    }
    @ViewBuilder private var emptyState: some View {
        if levelQuestions.isEmpty {
            ContentUnavailableView("등록된 문제가 없어요", systemImage: "music.note")
        } else if !model.practiceFilter.showCompleted && levelQuestions.allSatisfy({ model.completedPracticeQuestionIDs.contains($0.id) }) {
            ContentUnavailableView("이 레벨의 문제를 모두 풀었어요", systemImage: "checkmark.circle")
            Button("완료된 문제 보기") { model.practiceFilter.showCompleted = true }.buttonStyle(.bordered)
        } else {
            ContentUnavailableView("조건에 맞는 문제가 없어요", systemImage: "line.3.horizontal.decrease.circle")
            Button("필터 초기화") { model.practiceFilter.keySelection = .all; model.practiceFilter.meter = nil }
                .buttonStyle(.bordered).accessibilityIdentifier("practice-filter-reset")
        }
    }
}

private struct PracticeFilterLabel: View {
    let title: String; let value: String; let active: Bool
    var body: some View {
        HStack(spacing: 16) {
            Text("\(title) · \(value)").font(.system(size: 15, weight: .medium))
            Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(SolfegeTheme.muted)
        }.foregroundStyle(active ? SolfegeTheme.violet : SolfegeTheme.ink)
            .padding(.horizontal, 18).frame(height: 46)
            .background(active ? SolfegeTheme.soft : SolfegeTheme.field, in: RoundedRectangle(cornerRadius: 12))
    }
}
private struct PracticeCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18, weight: .regular)).foregroundStyle(configuration.isOn ? SolfegeTheme.violet : SolfegeTheme.muted)
                configuration.label.foregroundStyle(SolfegeTheme.ink)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(configuration.isOn ? "선택됨" : "선택 안 됨")
    }
}
private struct PracticeBankColumns {
    let title: CGFloat; let key: CGFloat; let meter: CGFloat; let tempo: CGFloat; let score: CGFloat
    init(width: CGFloat) {
        let scale = max(0, width - 48 - 60 - 20) / 956
        title = 330 * scale; key = 220 * scale; meter = 116 * scale; tempo = 144 * scale; score = 146 * scale
    }
}
private struct PracticeBankRow: View {
    let question: QuestionSummary; let completed: Bool; let width: CGFloat; let compact: Bool
    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { title; Spacer(minLength: 12); score; chevron }
                    HStack(spacing: 24) { key; meter; tempo }
                }
            } else {
                let columns = PracticeBankColumns(width: width)
                HStack(spacing: 12) {
                    title.frame(width: columns.title, alignment: .leading)
                    key.frame(width: columns.key, alignment: .leading)
                    meter.frame(width: columns.meter, alignment: .leading)
                    tempo.frame(width: columns.tempo, alignment: .leading)
                    score.frame(width: columns.score, alignment: .trailing)
                    chevron.frame(width: 20)
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, compact ? 20 : 0)
            .frame(minHeight: 84).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(SolfegeTheme.keyEdge.opacity(0.65)).frame(height: 1) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityDescription)
    }
    private var accessibilityDescription: String {
        let tempo = question.tempo ?? TempoDefaults.setting(for: question.timeSignature)
        let difficulty = question.difficultyScore.map { String(format: "%.1f", $0) } ?? "미정"
        let parts = [question.title, completed ? "완료" : "", question.keySignature.label,
                     question.timeSignature.label, tempo.label, "난이도 " + difficulty]
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
    private var title: some View {
        HStack(spacing: 12) {
            Text(question.title).font(.system(size: 18, weight: .medium)).foregroundStyle(SolfegeTheme.ink).lineLimit(1).minimumScaleFactor(0.8)
            if completed {
                Label("완료", systemImage: "checkmark").font(.system(size: 12, weight: .medium)).foregroundStyle(SolfegeTheme.green)
                    .padding(.horizontal, 8).padding(.vertical, 5).background(SolfegeTheme.soft, in: RoundedRectangle(cornerRadius: 7)).fixedSize()
            }
        }
    }
    private var key: some View { Text(question.keySignature.label).font(.system(size: 19, weight: .medium)).foregroundStyle(SolfegeTheme.ink).lineLimit(1).minimumScaleFactor(0.75) }
    private var meter: some View { Text(question.timeSignature.label).font(.system(size: 21, weight: .medium)).foregroundStyle(SolfegeTheme.ink) }
    private var tempo: some View { PracticeTempoMark(setting: question.tempo ?? TempoDefaults.setting(for: question.timeSignature)) }
    private var score: some View { Text(question.difficultyScore.map { String(format: "%.1f", $0) } ?? "—").font(.system(size: 25, weight: .medium)).monospacedDigit().foregroundStyle(SolfegeTheme.violet) }
    private var chevron: some View { Image(systemName: "chevron.right").font(.system(size: 17)).foregroundStyle(SolfegeTheme.violet) }
}

// Render the beat symbol as a vector so missing musical Unicode glyphs cannot
// turn the tempo into a square. Dotted compound-meter beats retain their dot.
private struct PracticeTempoMark: View {
    let setting: TempoSetting
    private var half: Bool { setting.beatUnit == "half" || setting.beatUnit == "dotted_half" }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if half { HalfNoteShape().fill(SolfegeTheme.ink, style: FillStyle(eoFill: true)) }
                else { StaffGlyphShape(glyph: .quarterNote).fill(SolfegeTheme.ink) }
            }.frame(width: 8.5, height: 25).alignmentGuide(.firstTextBaseline) { $0.height - 3 }
            if setting.beatUnit.hasPrefix("dotted_") { Text("·").font(.system(size: 21, weight: .bold)) }
            Text("= \(setting.bpm)").font(.system(size: 20, weight: .medium)).monospacedDigit()
        }.foregroundStyle(SolfegeTheme.ink).lineLimit(1).minimumScaleFactor(0.75)
    }
    private struct HalfNoteShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.addEllipse(in: CGRect(x: 0, y: rect.height * 0.72, width: rect.width, height: rect.height * 0.28))
            path.addEllipse(in: CGRect(x: rect.width * 0.17, y: rect.height * 0.79, width: rect.width * 0.66, height: rect.height * 0.14))
            path.addRect(CGRect(x: rect.width * 0.85, y: 0, width: rect.width * 0.15, height: rect.height * 0.86))
            return path
        }
    }
}

private struct PracticeKeyFilterView: View {
    @Binding var selection: QuestionFilter.KeySelection
    let questions: [QuestionSummary]; let width: CGFloat; let height: CGFloat; let done: () -> Void
    @State private var mode: Int
    @State private var draft: QuestionFilter.KeySelection
    init(selection: Binding<QuestionFilter.KeySelection>, questions: [QuestionSummary], width: CGFloat, height: CGFloat, done: @escaping () -> Void) {
        _selection = selection; self.questions = questions; self.width = width; self.height = height; self.done = done
        _draft = State(initialValue: selection.wrappedValue)
        if case .individual = selection.wrappedValue { _mode = State(initialValue: 1) }
        else { _mode = State(initialValue: 0) }
    }
    private var selectedKeys: Set<KeySignature> { if case .individual(let keys) = draft { return keys }; return [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("조성").font(.system(size: 18, weight: .bold)); Spacer(); Button("닫기", action: done).font(.subheadline) }
            Picker("조성 선택 방법", selection: $mode) {
                Text("조표 개수로 선택").tag(0); Text("조성 직접 선택").tag(1)
            }.pickerStyle(.segmented)
                .onChange(of: mode) { _, value in
                    if value == 1 { if case .individual = draft { } else { draft = .individual([]) } }
                    else { if case .individual = draft { draft = .all } }
                }
            ScrollView {
                VStack(spacing: mode == 0 ? 2 : 8) {
                    if mode == 0 { signatureOptions }
                    else { individualOptions }
                }
            }
            if mode == 0 {
                Text("샵·플랫 개수를 기준으로 장·단조를 함께 포함해요.").font(.caption).foregroundStyle(SolfegeTheme.muted)
            } else {
                Text("같은 줄은 같은 조표예요. 여러 조성을 선택할 수 있어요.").font(.caption).foregroundStyle(SolfegeTheme.muted)
                Button("적용") { selection = draft; done() }.buttonStyle(PrimaryButton(compact: true))
                    .frame(maxWidth: .infinity, alignment: .trailing).disabled(selectedKeys.isEmpty)
                    .accessibilityIdentifier("practice-key-apply")
            }
        }.padding(20).frame(width: width, height: height).background(.white).foregroundStyle(SolfegeTheme.ink)
    }
    private var signatureOptions: some View {
        VStack(spacing: 2) {
            signatureOption("전체", value: .all)
            let maximum = min(7, questions.map { abs($0.keySignature.fifths) }.max() ?? 0)
            ForEach(0...maximum, id: \.self) { count in
                signatureOption(count == 0 ? "다장조 · 가단조만" : "조표 \(count)개까지", value: .maximumAccidentals(count))
                    .disabled(!questions.contains { QuestionFilter.KeySelection.maximumAccidentals(count).includes($0.keySignature) })
            }
        }
    }
    private func signatureOption(_ label: String, value: QuestionFilter.KeySelection) -> some View {
        Button { selection = value; done() } label: {
            HStack {
                Text(label); Spacer(); if selection == value { Image(systemName: "checkmark") }
            }.font(.system(size: 15, weight: selection == value ? .medium : .regular))
                .foregroundStyle(selection == value ? SolfegeTheme.violet : SolfegeTheme.ink)
                .padding(.horizontal, 12).frame(minHeight: 42)
                .background(selection == value ? SolfegeTheme.soft : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private var individualOptions: some View {
        VStack(spacing: 8) {
            ForEach(QuestionFilter.keyGroups(in: questions)) { group in
                HStack(spacing: 10) {
                    Text(group.label).font(.caption).foregroundStyle(SolfegeTheme.muted).frame(width: width < 360 ? 60 : 82, alignment: .leading)
                    ForEach(group.keys, id: \.self) { key in
                        Button {
                            var keys = selectedKeys
                            if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
                            draft = .individual(keys)
                        } label: {
                            Text(key.label).font(.system(size: 15, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                                .foregroundStyle(selectedKeys.contains(key) ? SolfegeTheme.violet : SolfegeTheme.ink)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(selectedKeys.contains(key) ? SolfegeTheme.soft : SolfegeTheme.field, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityAddTraits(selectedKeys.contains(key) ? .isSelected : [])
                    }
                }
            }
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 24) {
            SectionCaption(eyebrow: "PRACTICE HISTORY", title: "연습 기록", subtitle: "이 iPad에 저장된 연습과 제출 결과를 확인하세요.")
            if model.history.isEmpty { ContentUnavailableView("첫 연습을 시작해 보세요", systemImage: "pencil.and.outline") }
            ForEach(model.history) { r in
                Button { Task { await model.open(r) } } label: {
                    Card { HStack {
                        VStack(alignment: .leading, spacing: 8) { Text(r.attempt.question.title).font(.headline); Text(r.attempt.createdAt, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            Text(r.attempt.studyMode.title).font(.caption.weight(.semibold)).foregroundStyle(SolfegeTheme.violet)
                            if r.attempt.gradingMode == "demo" { Text("데모 연습").font(.caption).foregroundStyle(SolfegeTheme.violet) }
                        }; Spacer()
                        if !model.canOpenHistoryRecord(r) { Pill(text: "교체된 연습") }
                        else if r.attempt.studyMode == .practice, r.attempt.status == "submitted" { Pill(text:r.selfAssessment?.isCompleted == true && r.practiceEdits == nil && r.selfAssessmentSave == nil ? "자기채점 완료" : "자기채점 중") }
                        else if r.grading?.status == "completed", let score = r.grading?.score { Text("\(score)점").font(.title2.bold()).foregroundStyle(SolfegeTheme.violet) }
                        else { Pill(text: r.attempt.status == "submitted" ? "결과 확인" : "이어서 연습") }
                        Image(systemName: "chevron.right")
                    } }
                }.buttonStyle(.plain).disabled(!model.canOpenHistoryRecord(r))
            }
        }.padding(32).frame(maxWidth: 1100).frame(maxWidth: .infinity) }
    }
}
