import SwiftUI

struct LoginView: View {
    @ObservedObject var model: AppModel
    let keyboardVisible: Bool
    let topInset: CGFloat
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var keepSignedIn = true
    @FocusState private var focus: Field?
    private enum Field: Hashable { case username, password }

    var body: some View {
        AuthForm(keyboardVisible: keyboardVisible, topInset: topInset) { proxy in
            AuthHeader(title: "다시 만나서 반가워요", subtitle: "아이디와 비밀번호를 입력해 주세요.", compact: keyboardVisible)
            VStack(alignment: .leading, spacing: 14) {
                AuthField(title: "아이디", focused: focus == .username, focus: { focus = .username }) {
                    TextField("계정 아이디", text: $username)
                        .textContentType(.username).keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .username).submitLabel(.next).onSubmit { focus = .password }
                        .accessibilityIdentifier("login-username")
                }.id(Field.username)
                AuthField(title: "비밀번호", focused: focus == .password, hints: model.loginMessage.map { [AuthHint(text: $0, tone: .bad)] } ?? [], focus: { focus = .password }) {
                    AuthPasswordInput(placeholder: "비밀번호", text: $password, revealed: $showPassword, contentType: .password, identifier: "login-password", focus: $focus, field: Field.password)
                        .submitLabel(.go).onSubmit { submit() }
                }.id(Field.password)
                Toggle("로그인 상태 유지", isOn: $keepSignedIn).toggleStyle(AuthCheckboxStyle()).accessibilityIdentifier("login-keep-signed-in")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let wait = max(0, Int(ceil(model.loginRetryUntil?.timeIntervalSince(context.date) ?? 0)))
                    Button(action: submit) {
                        HStack(spacing: 8) {
                            if model.authenticating { ProgressView() }
                            Text(model.authenticating ? "로그인 확인 중" : wait > 0 ? "\(wait)초 후 다시 시도할 수 있어요" : "로그인")
                        }
                    }
                    .buttonStyle(AuthPrimaryButtonStyle(height: keyboardVisible ? 52 : 56))
                    .disabled(model.authenticating || username.isEmpty || password.isEmpty || wait > 0).accessibilityIdentifier("login-submit")
                }
                if model.authenticating {
                    Button("로그인 취소") { password = ""; model.cancelLogin() }.font(.system(size: 14)).frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    Text("필기와 미제출 답안은 같은 계정으로 로그인하면 이어갈 수 있어요.")
                        .font(.system(size: 13)).foregroundStyle(SORITheme.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .onChange(of: focus) { _, field in scroll(to: field, proxy) }
            .onChange(of: keyboardVisible) { _, _ in scroll(to: focus, proxy) }
        } footer: {
            if model.signupEnabled {
                AuthSwitchLink(prompt: "처음이신가요?", action: "회원가입", identifier: "open-signup") { model.openSignup() }
                    .disabled(model.authenticating)
            }
        }
        .onAppear { if let name = model.loginPrefill { username = name; model.loginPrefill = nil } }
        .onChange(of: model.loginPrefill) { _, name in if let name { username = name; model.loginPrefill = nil } }
        .onChange(of: username) { model.loginMessage = nil }
        .onChange(of: password) { _, value in if !value.isEmpty { model.loginMessage = nil } }
        .onDisappear { password = "" }
    }

    private func scroll(to field: Field?, _ proxy: ScrollViewProxy) {
        guard let field else { return }
        // Wait out the keyboard, so the scroll uses the final visible height.
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(field, anchor: .center) }
        }
    }
    private func submit() {
        guard !model.authenticating, !username.isEmpty, !password.isEmpty,
              (model.loginRetryUntil ?? .distantPast) <= Date() else { return }
        // Clear the view state immediately; retain credentials only for this request.
        let submittedPassword = password; password = ""; focus = nil; showPassword = false
        Task { await model.login(username: username, password: submittedPassword, keepSignedIn: keepSignedIn) }
    }
}
