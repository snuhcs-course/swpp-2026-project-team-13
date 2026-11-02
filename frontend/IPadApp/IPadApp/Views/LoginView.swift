import SwiftUI

struct LoginView: View {
    @ObservedObject var model: AppModel
    @State private var username = ""
    @State private var password = ""
    @FocusState private var focus: Field?
    private enum Field { case username, password }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SectionCaption(eyebrow: "WELCOME TO SORI", title: "나의 연습실에 로그인", subtitle: "아이디와 비밀번호를 입력해 주세요.")
                Card {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("아이디").font(.subheadline.bold())
                        TextField("계정 아이디", text: $username)
                            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder).focused($focus, equals: .username)
                            .submitLabel(.next).onSubmit { focus = .password }.accessibilityIdentifier("login-username")
                        Text("비밀번호").font(.subheadline.bold())
                        SecureField("비밀번호", text: $password)
                            .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder).focused($focus, equals: .password)
                            .submitLabel(.go).onSubmit { submit() }.accessibilityIdentifier("login-password")
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let wait = max(0, Int(ceil(model.loginRetryUntil?.timeIntervalSince(context.date) ?? 0)))
                            VStack(alignment: .leading, spacing: 12) {
                                if wait > 0 { Text("\(wait)초 후 다시 시도할 수 있어요.").font(.subheadline).foregroundStyle(.secondary) }
                                Button(action: submit) {
                                    HStack { if model.authenticating { ProgressView() }; Text(model.authenticating ? "로그인 확인 중" : "로그인") }
                                }.buttonStyle(PrimaryButton()).disabled(model.authenticating || username.isEmpty || password.isEmpty || wait > 0)
                            }
                        }
                        if model.authenticating {
                            Button("로그인 취소") { password = ""; model.cancelLogin() }
                        } else {
                            Button("저장된 로그인 다시 확인") { Task { await model.connect() } }
                        }
                        Text("비밀번호는 저장하지 않습니다. 필기와 미제출 답안은 같은 계정으로 다시 로그인하면 이어갈 수 있어요.")
                            .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                    }
                }
                if model.signupEnabled {
                    Button { model.openSignup() } label: { Label("새 계정 만들기", systemImage: "person.badge.plus") }
                        .disabled(model.authenticating).accessibilityIdentifier("open-signup")
                }
                Button { model.navigate(.settings) } label: { Label("서버 연결 설정", systemImage: "slider.horizontal.3") }
            }.padding(32).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .task(id: model.server) { await model.refreshSignupAvailability() }
        .onAppear { if let name = model.loginPrefill { username = name; model.loginPrefill = nil } }
        .onChange(of: model.loginPrefill) { _, name in if let name { username = name; model.loginPrefill = nil } }
        .onDisappear { password = "" }
    }

    private func submit() {
        guard !model.authenticating, !username.isEmpty, !password.isEmpty,
              (model.loginRetryUntil ?? .distantPast) <= Date() else { return }
        // Clear the view state immediately; retain credentials only for this request.
        let submittedPassword = password; password = ""; focus = nil
        Task { await model.login(username: username, password: submittedPassword) }
    }
}
