import SwiftUI

struct SignupView: View {
    @ObservedObject var model: AppModel
    @State private var username = ""
    @State private var displayName = ""
    @State private var learningGoal: String?
    @State private var password = ""
    @State private var confirmation = ""
    @FocusState private var focus: Field?
    private enum Field { case username, displayName, password, confirmation }

    private var isReady: Bool {
        SignupRules.usernameIsValid(username) && SignupRules.displayNameIsValid(displayName) && learningGoal != nil
            && SignupRules.passwordLengthIsValid(password) && password == confirmation
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SectionCaption(eyebrow: "WELCOME TO SORI", title: "새 계정 만들기", subtitle: "이메일이나 실명 없이 아이디와 비밀번호로 시작해요.")
                Card {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("아이디, 표시 이름에 실명, 학번, 전화번호 등 본인을 알 수 있는 정보를 쓰지 마세요.")
                            .font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
                        field("아이디", key: "username", hint: "영문 소문자로 시작하고 영문 소문자, 숫자, _만 쓰는 4~20자",
                              problem: !username.isEmpty && !SignupRules.usernameIsValid(username) ? "아이디 형식을 확인해 주세요." : nil) {
                            TextField("예: melody_01", text: $username)
                                .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder).focused($focus, equals: .username)
                                .submitLabel(.next).onSubmit { focus = .displayName }.accessibilityIdentifier("signup-username")
                                .onChange(of: username) { model.clearSignupError("username") }
                        }
                        field("표시 이름", key: "display_name", hint: "닉네임을 1~20자로 입력해 주세요. 가입 후에는 바꿀 수 없어요.",
                              problem: !displayName.isEmpty && !SignupRules.displayNameIsValid(displayName) ? "앞뒤 공백이나 제어 문자 없이 1~20자로 입력해 주세요." : nil) {
                            TextField("닉네임", text: $displayName)
                                .textContentType(.nickname).autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder).focused($focus, equals: .displayName)
                                .submitLabel(.next).onSubmit { focus = .password }.accessibilityIdentifier("signup-display-name")
                                .onChange(of: displayName) { model.clearSignupError("display_name") }
                        }
                        field("학습 목표", key: "learning_goal", hint: "가입 후 연결 설정에서 바꿀 수 있어요.", problem: nil) {
                            Picker("학습 목표", selection: $learningGoal) {
                                Text("선택해 주세요").tag(String?.none)
                                ForEach(SORITheme.goals, id: \.0) { key, title in Text(title).tag(String?.some(key)) }
                            }.accessibilityIdentifier("signup-learning-goal")
                            .onChange(of: learningGoal) { model.clearSignupError("learning_goal") }
                        }
                        field("비밀번호", key: "password", hint: "비밀번호를 잊으면 복구할 수 없어요. 연락처를 받지 않아 관리자도 재설정해 드릴 수 없습니다.",
                              problem: !password.isEmpty && !SignupRules.passwordLengthIsValid(password) ? "비밀번호는 1024자 이하로 입력해 주세요." : nil) {
                            SecureField("8자 이상", text: $password)
                                .textContentType(.newPassword).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder).focused($focus, equals: .password)
                                .submitLabel(.next).onSubmit { focus = .confirmation }.accessibilityIdentifier("signup-password")
                                .onChange(of: password) { model.clearSignupError("password") }
                        }
                        field("비밀번호 확인", key: "", hint: nil,
                              problem: !confirmation.isEmpty && confirmation != password ? "비밀번호가 일치하지 않습니다." : nil) {
                            SecureField("비밀번호 다시 입력", text: $confirmation)
                                .textContentType(.newPassword).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder).focused($focus, equals: .confirmation)
                                .submitLabel(.go).onSubmit { submit() }.accessibilityIdentifier("signup-confirmation")
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let wait = max(0, Int(ceil(model.signupRetryUntil?.timeIntervalSince(context.date) ?? 0)))
                            VStack(alignment: .leading, spacing: 12) {
                                if wait > 0 { Text("\(wait)초 후 다시 시도할 수 있어요.").font(.subheadline).foregroundStyle(.secondary) }
                                Button(action: submit) {
                                    HStack { if model.authenticating { ProgressView() }; Text(model.authenticating ? "계정을 만드는 중" : "계정 만들기") }
                                }.buttonStyle(PrimaryButton()).disabled(model.authenticating || !isReady || wait > 0).accessibilityIdentifier("signup-submit")
                            }
                        }
                        if model.authenticating {
                            Button("가입 취소") { model.cancelLogin() }
                        }
                    }
                }
                Button { model.closeSignup() } label: { Label("로그인으로 돌아가기", systemImage: "chevron.left") }
                    .disabled(model.authenticating).accessibilityIdentifier("close-signup")
            }.padding(32).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }.onDisappear { password = ""; confirmation = "" }
    }

    private func field<Input: View>(_ title: String, key: String, hint: String?, problem: String?, @ViewBuilder input: () -> Input) -> some View {
        let serverProblems = model.signupFieldErrors.filter { $0.field == key }.map(\.message)
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.bold())
            input()
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary).lineSpacing(3) }
            ForEach(([problem].compactMap { $0 } + serverProblems), id: \.self) { message in
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func submit() {
        guard !model.authenticating, isReady, let learningGoal, (model.signupRetryUntil ?? .distantPast) <= Date() else { return }
        // Clear the view state immediately; retain the password only for this request.
        let submittedPassword = password; password = ""; confirmation = ""; focus = nil
        Task { await model.signup(username: username, displayName: displayName, learningGoal: learningGoal, password: submittedPassword) }
    }
}
