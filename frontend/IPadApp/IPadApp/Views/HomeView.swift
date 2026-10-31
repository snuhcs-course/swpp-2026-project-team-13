import SwiftUI

struct HomeView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top) {
                    SectionCaption(eyebrow: "MY PRACTICE ROOM", title: "나의 연습실", subtitle: "오늘도 소리에 귀 기울여 볼까요?")
                    Spacer()
                    if let profile = model.profile {
                        Menu { ForEach(SORITheme.goals, id: \.0) { key, title in Button(title) { Task { await model.updateGoal(key) } } } } label: { Pill(text: SORITheme.goal(profile.learningGoal), icon: "scope") }
                    }
                }
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("MELODIC DICTATION").font(.caption.weight(.bold)).tracking(2).foregroundStyle(SORITheme.violet)
                        Text("소리를 듣고,\n음악을 기록하세요.").font(.system(size: 34, weight: .bold, design: .rounded)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                        Text("멜로디를 듣고 오선 위에 옮겨 적는 시간.\n작은 연습이 더 정확한 귀를 만들어요.").font(.subheadline).lineSpacing(6).foregroundStyle(.secondary)
                        HStack { Pill(text: "Apple Pencil", icon: "pencil.tip"); Pill(text: "8마디 · 시험 순서", icon: "music.note.list") }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "waveform.path").font(.system(size: 96, weight: .ultraLight)).foregroundStyle(SORITheme.violet.opacity(0.45)).accessibilityHidden(true)
                }.padding(32).frame(maxWidth: .infinity, alignment: .leading).background(SORITheme.soft, in: RoundedRectangle(cornerRadius: 24))
                Button { model.navigate(.minigames) } label: {
                    Card { HStack(spacing:18) {
                        Image(systemName:"pianokeys").font(.system(size:34)).foregroundStyle(SORITheme.violet)
                        VStack(alignment:.leading,spacing:6) { Text("멜로디 런 · 미니게임").font(.headline).foregroundStyle(SORITheme.ink); Text("듣고 기억한 멜로디를 건반으로 복원해 보세요").font(.subheadline).foregroundStyle(.secondary) }
                        Spacer(); Image(systemName:"arrow.up.right").foregroundStyle(SORITheme.violet)
                    } }
                }.buttonStyle(.plain)
                if !model.connected {
                    Card { VStack(alignment: .leading, spacing: 16) {
                        Label("학습 공간에 연결해 주세요", systemImage: "network")
                        Text("설정에서 로컬 데모를 시작하거나 개발 서버와 토큰을 연결할 수 있어요.").font(.subheadline).foregroundStyle(.secondary)
                        Button("연결 설정 열기") { model.navigate(.settings) }.buttonStyle(PrimaryButton())
                    } }
                } else {
                    if model.pendingCreation { Button { Task { await model.recoverPending() } } label: { Label("응답을 받지 못한 연습 생성 요청 복구", systemImage: "arrow.clockwise") }.buttonStyle(.bordered) }
                    if let unfinished = model.history.first(where: { $0.attempt.status != "submitted" }) {
                        Card { HStack {
                            VStack(alignment: .leading, spacing: 6) { Text("이어서 연습하기").font(.headline); Text(unfinished.attempt.question.title).font(.subheadline).foregroundStyle(.secondary) }
                            Spacer(); Button("계속하기") { Task { await model.open(unfinished) } }.buttonStyle(PrimaryButton(compact: true))
                        } }
                    }
                    HStack { Text("청음 연습").font(.title2.bold()); Spacer(); Text("\(model.questions.count)개 문제").font(.subheadline).foregroundStyle(.secondary) }
                    if model.questions.isEmpty { ContentUnavailableView("아직 등록된 문제가 없어요", systemImage: "music.note", description: Text("문제가 게시되면 이곳에서 연습을 시작할 수 있어요.")) }
                    ForEach(Array(model.questions.enumerated()), id: \.element.id) { index, q in
                        Button { Task { await model.choose(q.id) } } label: {
                            Card { HStack(spacing: 20) {
                                Text(String(format: "%02d", index+1)).font(.system(size: 29, weight: .light, design: .rounded)).foregroundStyle(SORITheme.violet).frame(width: 48)
                                VStack(alignment: .leading, spacing: 10) { Text(q.title).font(.headline).foregroundStyle(SORITheme.ink)
                                    HStack { Text(q.keySignature.label); Text("·"); Text("\(q.timeSignature.numerator)/\(q.timeSignature.denominator)"); Text("·"); Text("\(q.measureCount)마디"); Text("·"); Text("\(q.recommendedDurationSeconds / 60)분 \(q.recommendedDurationSeconds % 60)초") }.font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "arrow.up.right").font(.title3).foregroundStyle(SORITheme.violet).padding(14).background(SORITheme.soft, in: Circle())
                            } }
                        }.buttonStyle(.plain)
                    }
                    if model.hasNextPage { Button("문제 더 보기") { Task { await model.loadMore() } }.frame(maxWidth: .infinity) }
                    if model.demo { DemoBadge() }
                }
            }.padding(32).frame(maxWidth: 1150, alignment: .leading).frame(maxWidth: .infinity)
        }.refreshable { await model.connect() }
    }
}
struct QuestionView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView { if let q = model.selectedQuestion {
            VStack(alignment: .leading, spacing: 28) {
                SectionCaption(eyebrow: "READY TO LISTEN", title: q.title, subtitle: q.description)
                HStack {
                    Pill(text:q.keySignature.label,icon:"music.note")
                    Pill(text:"\(q.timeSignature.numerator)/\(q.timeSignature.denominator) · 8마디")
                    if let tempo = q.tempo { Pill(text:tempo.label,icon:"metronome") }
                    Pill(text:"권장 \(q.recommendedDurationSeconds/60)분 \(q.recommendedDurationSeconds%60)초",icon:"clock")
                }
                Card { VStack(alignment: .leading, spacing: 24) {
                    Text("연습은 이렇게 진행돼요").font(.title2.bold())
                    instruction("01", "스케일과 멜로디 듣기", "시작 2초 후 스케일을 듣고, 2초 뒤 예비박과 첫 전체 재생이 이어져요. 마지막 전체 재생 앞에도 예비박이 나와요.")
                    instruction("02", "Pencil로 오선에 기록하기", "검정 펜으로 자유롭게 적어 주세요. 필기는 이 iPad에 자동 저장돼요.")
                    instruction("03", "답안을 제출하고 확인하기", "제출한 답안을 분석한 뒤 점수와 피드백, 정답 악보를 확인해요.")
                } }
                Label("이어폰과 음량을 확인해 주세요", systemImage: "headphones").font(.headline)
                Text("악보와 피아노를 모두 준비한 뒤 시작 버튼이 나타나요. 권장 시간이 지나도 필기와 수동 제출을 계속할 수 있어요. 재생을 멈춘 시간에도 타이머는 흐릅니다.").font(.subheadline).foregroundStyle(.secondary).lineSpacing(6)
                if model.demo { DemoBadge() }
                Button { Task { await model.begin() } } label: { Label("연습 준비하기", systemImage: "arrow.right") }.buttonStyle(PrimaryButton())
            }.padding(36).frame(maxWidth: 960, alignment: .leading).frame(maxWidth: .infinity)
        } }
    }
    func instruction(_ index: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(index).font(.caption.bold()).foregroundStyle(SORITheme.violet).padding(12).background(SORITheme.soft, in: Circle())
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
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
                            if r.attempt.gradingMode == "demo" { Text("데모 연습").font(.caption).foregroundStyle(SORITheme.violet) }
                        }; Spacer()
                        if r.grading?.status == "completed", let score = r.grading?.score { Text("\(score)점").font(.title2.bold()).foregroundStyle(SORITheme.violet) }
                        else { Pill(text: r.attempt.status == "submitted" ? "결과 확인" : "이어서 연습") }
                        Image(systemName: "chevron.right")
                    } }
                }.buttonStyle(.plain)
            }
        }.padding(32).frame(maxWidth: 1100).frame(maxWidth: .infinity) }
    }
}
