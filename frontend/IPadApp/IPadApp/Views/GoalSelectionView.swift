import SwiftUI

// The last onboarding step. It also returns whenever the account still has no goal,
// for example when the app closed right after signup.
struct GoalSelectionView: View {
    @ObservedObject var model: AppModel
    @State private var selection: String?
    private let examGoals = ["arts_school_entrance", "college_entrance", "teacher_exam"]
    private let otherGoals = ["arts_school_student", "other"]
    private let details = [
        "arts_school_entrance": "예술중·고등학교 진학 준비", "college_entrance": "음악대학 진학 준비", "teacher_exam": "임용 시험 준비",
        "arts_school_student": "예술중·고등학교 재학 중", "other": "취미, 기초 학습 등",
    ]

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(model.profile?.displayName ?? "")님, 반가워요").font(.system(size: 16, weight: .medium)).foregroundStyle(SORITheme.violet).lineLimit(1)
                        Text("어떤 목표로 음악을 공부하고 있나요?").font(.system(size: 34, weight: .bold)).foregroundStyle(SORITheme.ink).accessibilityAddTraits(.isHeader)
                        Text("가입 후 설정에서 바꿀 수 있어요.").font(.system(size: 16)).foregroundStyle(SORITheme.muted)
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        group("입시·시험 준비", examGoals, wide: proxy.size.width >= 600)
                        group("그 외", otherGoals, wide: proxy.size.width >= 600)
                        Button("시작하기") { if let selection { Task { await model.updateGoal(selection) } } }
                            .buttonStyle(AuthPrimaryButtonStyle(height: 60))
                            .disabled(selection == nil || model.busy || model.authenticating).padding(.top, 8).accessibilityIdentifier("goal-start")
                    }
                }
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, max(24, (proxy.size.height - 560) / 2))
            }
        }
        .background(SORITheme.background.ignoresSafeArea())
    }
    private func group(_ title: String, _ keys: [String], wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(SORITheme.muted)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: wide ? keys.count : 1), spacing: 12) {
                ForEach(keys, id: \.self) { card($0) }
            }
        }
    }
    private func card(_ key: String) -> some View {
        let selected = selection == key
        return Button { selection = key } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(SORITheme.goal(key)).font(.system(size: 20, weight: .bold)).foregroundStyle(SORITheme.ink)
                    Text(details[key] ?? "").font(.system(size: 14)).foregroundStyle(selected ? SORITheme.softInk : SORITheme.muted)
                }
                Spacer(minLength: 8)
                Circle().fill(selected ? SORITheme.violet : Color.clear)
                    .overlay(Circle().stroke(selected ? SORITheme.violet : Color(red: 0.79, green: 0.79, blue: 0.84), lineWidth: 2))
                    .overlay { if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) } }
                    .frame(width: 24, height: 24)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(selected ? SORITheme.soft : Color.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? SORITheme.violet : .clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .animation(.easeOut(duration: 0.16), value: selected)
        }
        .buttonStyle(.plain).accessibilityIdentifier("goal-\(key)").accessibilityAddTraits(selected ? .isSelected : [])
    }
}
