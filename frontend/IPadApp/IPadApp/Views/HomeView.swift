import SwiftUI

struct HomeView: View {
    @ObservedObject var model: AppModel
    private let mode = StudyMode.practice
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment:.leading,spacing:6) {
                    Text(model.selectedPracticeLevel.map { "\(mode.title) · \($0.title)" } ?? mode.title).font(.system(size:34,weight:.bold)).foregroundStyle(SolfegeTheme.ink).accessibilityAddTraits(.isHeader)
                    Text(mode.detail).font(.system(size:16)).foregroundStyle(SolfegeTheme.muted)
                }
                if !model.connected {
                    Card { VStack(alignment: .leading, spacing: 16) {
                        Label("학습 공간에 연결해 주세요", systemImage: "network")
                        Text("설정에서 로컬 데모를 시작하거나 개발 서버와 토큰을 연결할 수 있어요.").font(.subheadline).foregroundStyle(.secondary)
                        Button("연결 설정 열기") { model.navigate(.settings) }.buttonStyle(PrimaryButton())
                    } }
                } else {
                    if model.pendingCreation { Button { Task { await model.recoverPending() } } label: { Label("응답을 받지 못한 연습 생성 요청 복구", systemImage: "arrow.clockwise") }.buttonStyle(.bordered) }
                    if let unfinished = model.history.first(where: { $0.attempt.studyMode == mode && model.isUnfinished($0) }) {
                        Card { HStack {
                            VStack(alignment: .leading, spacing: 6) { Text(mode.title + " 이어서 하기").font(.headline); Text(unfinished.attempt.question.title).font(.subheadline).foregroundStyle(.secondary) }
                            Spacer(); Button("계속하기") { Task { await model.open(unfinished) } }.buttonStyle(PrimaryButton(compact: true))
                        } }
                    }
                    if model.selectedPracticeLevel != nil {
                        Button { withAnimation { model.selectedPracticeLevel = nil } } label: { Label("난이도 선택",systemImage:"chevron.left") }.buttonStyle(.bordered)
                    }
                    HStack {
                        if let level = model.selectedPracticeLevel { Text("\(level.title) 청음 연습").font(.title2.bold()) }
                        else { Text("난이도를 골라보세요").font(.system(size:14,weight:.medium)).foregroundStyle(SolfegeTheme.muted) }
                        Spacer(); Text("\(visibleQuestions.count)개 문제").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if model.questions.isEmpty { ContentUnavailableView("아직 등록된 문제가 없어요", systemImage: "music.note", description: Text("문제가 게시되면 이곳에서 연습을 시작할 수 있어요.")) }
                    if model.selectedPracticeLevel == nil {
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:216),spacing:12)],spacing:12) {
                            ForEach(PracticeLevel.allCases) { level in
                                Button { withAnimation { model.selectedPracticeLevel = level } } label: {
                                    levelCard(level,count:model.questions.filter { $0.practiceLevel == level }.count)
                                }.buttonStyle(.plain).accessibilityIdentifier("practice-level-\(level.rawValue)")
                            }
                        }
                    } else {
                    filterBar
                    if let q = suggestedQuestion {
                        Card { VStack(alignment:.leading,spacing:12) {
                            Label("다음 연습 추천",systemImage:"sparkles").font(.headline)
                            Text(q.title).font(.subheadline)
                            Text("선택한 난이도에서 자기채점을 완료한 횟수가 적은 문제를 먼저 제안해요.").font(.caption).foregroundStyle(.secondary)
                            Button("이 문제 연습하기") { Task { await model.choose(q.id,mode:mode) } }.buttonStyle(PrimaryButton(compact:true))
                                .accessibilityIdentifier("practice-suggested-question")
                        } }
                    }
                    ForEach(Array(visibleQuestions.enumerated()), id: \.element.id) { index, q in
                        Button { Task { await model.choose(q.id,mode:mode) } } label: {
                            Card { HStack(spacing: 20) {
                                Text(String(format: "%02d", index+1)).font(.system(size: 29, weight: .light, design: .rounded)).foregroundStyle(SolfegeTheme.violet).frame(width: 48)
                                VStack(alignment: .leading, spacing: 10) { Text(q.title).font(.headline).foregroundStyle(SolfegeTheme.ink)
                                    HStack { Text(q.keySignature.label); Text("·"); Text("\(q.timeSignature.numerator)/\(q.timeSignature.denominator)"); Text("·"); Text("\(q.measureCount)마디"); Text("·"); Text("\(q.recommendedDurationSeconds / 60)분 \(q.recommendedDurationSeconds % 60)초") }.font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "arrow.up.right").font(.title3).foregroundStyle(SolfegeTheme.violet).padding(14).background(SolfegeTheme.soft, in: Circle())
                            } }
                        }.buttonStyle(.plain).accessibilityIdentifier("practice-question-\(q.id.uuidString.lowercased())")
                    }
                    if visibleQuestions.isEmpty {
                        if model.practiceFilter.isActive {
                            ContentUnavailableView("조건에 맞는 문제가 없어요",systemImage:"line.3.horizontal.decrease.circle",description:Text("조성이나 박자를 바꿔 보세요."))
                        } else { ContentUnavailableView("등록된 문제가 없어요",systemImage:"music.note") }
                    }
                    }
                    if model.hasNextPage { Button("문제 더 보기") { Task { await model.loadMore() } }.frame(maxWidth: .infinity) }
                    Button { model.navigate(.classical) } label: {
                        HStack {
                            Text("클래식 선율 문제").font(.system(size:20,weight:.bold)).foregroundStyle(SolfegeTheme.ink)
                            Spacer(); Image(systemName:"arrow.up.right").font(.system(size:20)).foregroundStyle(SolfegeTheme.violet)
                        }.padding(.horizontal,20).frame(maxWidth:.infinity,minHeight:76).background(.white,in:RoundedRectangle(cornerRadius:16))
                    }.buttonStyle(.plain)
                    if model.demo { DemoBadge() }
                }
            }.padding(32).frame(maxWidth: 924, alignment: .leading).frame(maxWidth: .infinity)
        }.refreshable { let level = model.selectedPracticeLevel; await model.refreshLibrary(destination:.home); model.selectedPracticeLevel = level }
    }
    private var levelQuestions: [QuestionSummary] {
        guard let level = model.selectedPracticeLevel else { return model.questions }
        return model.questions.filter { $0.practiceLevel == level }
    }
    private var visibleQuestions: [QuestionSummary] { model.practiceFilter.apply(to:levelQuestions) }
    // A menu with one option cannot narrow anything, as with the keys of 중급 and 고급.
    private var filterBar: some View {
        let keys = QuestionFilter.keyOptions(in:levelQuestions), meters = QuestionFilter.meterOptions(in:levelQuestions)
        return HStack(spacing:12) {
            if keys.count > 1 {
                filterMenu("조성",current:model.practiceFilter.key?.label,id:"practice-filter-key") {
                    Picker("조성",selection:$model.practiceFilter.key) {
                        Text("전체").tag(KeySignature?.none)
                        ForEach(keys,id:\.self) { Text($0.label).tag(KeySignature?.some($0)) }
                    }
                }
            }
            if meters.count > 1 {
                filterMenu("박자",current:model.practiceFilter.meter?.label,id:"practice-filter-meter") {
                    Picker("박자",selection:$model.practiceFilter.meter) {
                        Text("전체").tag(TimeSignature?.none)
                        ForEach(meters,id:\.self) { Text($0.label).tag(TimeSignature?.some($0)) }
                    }
                }
            }
            if model.practiceFilter.isActive {
                Button("필터 초기화") { model.practiceFilter = QuestionFilter() }.font(.system(size:15,weight:.medium)).frame(minHeight:44).accessibilityIdentifier("practice-filter-reset")
            }
        }
    }
    private func filterMenu<Options: View>(_ title: String, current: String?, id: String, @ViewBuilder options: () -> Options) -> some View {
        Menu { options() } label: {
            HStack(spacing:8) {
                Text("\(title) · \(current ?? "전체")").font(.system(size:15,weight:.semibold)).foregroundStyle(current == nil ? SolfegeTheme.ink : SolfegeTheme.deepViolet)
                Image(systemName:"chevron.down").font(.system(size:12,weight:.semibold)).foregroundStyle(SolfegeTheme.violet)
            }.padding(.horizontal,16).frame(minHeight:44).background(.white,in:RoundedRectangle(cornerRadius:12))
        }.accessibilityIdentifier(id)
    }
    private var suggestedQuestion: QuestionSummary? {
        var completed: [UUID:Int] = [:]
        for record in model.history where record.attempt.studyMode == .practice && record.selfAssessment?.isCompleted == true {
            completed[record.attempt.question.id,default:0] += 1
        }
        // Stable catalog order breaks ties; recommendations stay within the chosen level.
        return visibleQuestions.enumerated().min { lhs, rhs in
            let a = completed[lhs.element.id,default:0], b = completed[rhs.element.id,default:0]
            return a == b ? lhs.offset < rhs.offset : a < b
        }?.element
    }
    private func levelCard(_ level: PracticeLevel, count: Int) -> some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(alignment:.top) {
                Text(level.title).font(.system(size:28,weight:.bold)).foregroundStyle(SolfegeTheme.ink)
                Spacer(); Image(systemName:"arrow.up.right").font(.system(size:20)).foregroundStyle(SolfegeTheme.violet)
            }
            Spacer(minLength:16)
            Text(level.subtitle).font(.system(size:14)).foregroundStyle(SolfegeTheme.muted).multilineTextAlignment(.leading).fixedSize(horizontal:false,vertical:true)
            Text("\(count)개 문제 · 8마디").font(.system(size:14,weight:.semibold)).foregroundStyle(SolfegeTheme.deepViolet)
        }.padding(20).frame(maxWidth:.infinity,minHeight:200,alignment:.topLeading).background(.white,in:RoundedRectangle(cornerRadius:16))
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
                        if r.attempt.studyMode == .practice, r.attempt.status == "submitted" { Pill(text:r.selfAssessment?.isCompleted == true && r.practiceEdits == nil && r.selfAssessmentSave == nil ? "자기채점 완료" : "자기채점 중") }
                        else if r.grading?.status == "completed", let score = r.grading?.score { Text("\(score)점").font(.title2.bold()).foregroundStyle(SolfegeTheme.violet) }
                        else { Pill(text: r.attempt.status == "submitted" ? "결과 확인" : "이어서 연습") }
                        Image(systemName: "chevron.right")
                    } }
                }.buttonStyle(.plain)
            }
        }.padding(32).frame(maxWidth: 1100).frame(maxWidth: .infinity) }
    }
}
