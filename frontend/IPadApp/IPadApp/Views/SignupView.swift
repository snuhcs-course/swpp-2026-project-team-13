import SwiftUI

struct SignupView: View {
    @ObservedObject var model: AppModel
    let keyboardVisible: Bool
    let topInset: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var username = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var showPassword = false
    @State private var passwordWasCleared = false
    // How many fields after the username are open. It only grows, so corrections never collapse the form.
    @State private var revealed = 0
    // The keyboard's next key was pressed before the username check finished.
    @State private var advanceAfterCheck = false
    @FocusState private var focus: Field?
    private enum Field: Hashable { case username, displayName, password, confirmation }
    private let submitAnchor = "signup-submit-area"

    private var usernameTaken: Bool { model.signupFieldErrors.contains { $0.field == "username" && $0.code == "taken" } }
    private var usernameStatus: UsernameStatus? { model.usernameStatus(username) }
    private var reachable: Int {
        SignupRules.reachableFields(username: username, status: usernameStatus, displayName: displayName, password: password)
    }
    private var isReady: Bool {
        SignupRules.usernameIsValid(username) && usernameStatus != .taken && SignupRules.displayNameIsValid(displayName)
            && SignupRules.passwordMeetsPolicy(password) && password == confirmation
    }

    var body: some View {
        AuthForm(keyboardVisible: keyboardVisible, topInset: topInset) { proxy in
            AuthHeader(title: title, subtitle: subtitle, compact: keyboardVisible)
            VStack(alignment: .leading, spacing: 14) {
                AuthField(title: "아이디", focused: focus == .username, hints: usernameHints, focus: { focus = .username }) {
                    TextField("예: melody_01", text: $username)
                        .textContentType(.username).keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .username).submitLabel(.next).onSubmit { advance(from: .username) }
                        .accessibilityIdentifier("signup-username")
                }.id(Field.username)
                if revealed >= 1 {
                    AuthField(title: "닉네임", focused: focus == .displayName, hints: displayNameHints, focus: { focus = .displayName }) {
                        TextField("1~20자", text: $displayName)
                            .textContentType(.nickname).autocorrectionDisabled()
                            .focused($focus, equals: .displayName).submitLabel(.next).onSubmit { advance(from: .displayName) }
                            .accessibilityIdentifier("signup-display-name")
                    }.id(Field.displayName).transition(.opacity.combined(with: .move(edge: .top)))
                }
                if revealed >= 2 {
                    AuthField(title: "비밀번호", focused: focus == .password, hints: passwordHints, focus: { focus = .password }) {
                        AuthPasswordInput(placeholder: passwordWasCleared ? "비밀번호를 다시 입력해 주세요" : "영문·숫자 포함 8자 이상", text: $password, revealed: $showPassword, contentType: .newPassword, identifier: "signup-password", focus: $focus, field: Field.password)
                            .submitLabel(.next).onSubmit { advance(from: .password) }
                    }.id(Field.password).transition(.opacity.combined(with: .move(edge: .top)))
                }
                if revealed >= 3 {
                    AuthField(title: "비밀번호 확인", focused: focus == .confirmation, hints: confirmationHints, focus: { focus = .confirmation }) {
                        AuthPasswordInput(placeholder: "한 번 더 입력해 주세요", text: $confirmation, revealed: $showPassword, contentType: .newPassword, identifier: "signup-confirmation", showsToggle: false, focus: $focus, field: Field.confirmation)
                            .submitLabel(.go).onSubmit { submit() }
                    }.id(Field.confirmation).transition(.opacity.combined(with: .move(edge: .top)))
                    submitArea.padding(.top, 4).id(submitAnchor).transition(.opacity)
                }
            }
            .onChange(of: focus) { _, field in scroll(to: field, proxy) }
            .onChange(of: keyboardVisible) { _, _ in scroll(to: focus, proxy) }
        } footer: {
            AuthSwitchLink(prompt: "이미 회원이신가요?", action: "로그인", identifier: "close-signup") { model.closeSignup() }
                .disabled(model.authenticating)
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.42), value: revealed)
        // A pause in typing starts the check. Changing the username cancels this task, which drops its late answer.
        .task(id: username) {
            guard SignupRules.usernameIsValid(username), usernameStatus == nil else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await model.checkUsername(username)
            guard !Task.isCancelled else { return }
            revealed = max(revealed, reachable)
            if advanceAfterCheck { advanceAfterCheck = false; advance(from: .username) }
        }
        // A pause in typing opens the next field, so it never jumps mid-word and never takes focus.
        .task(id: [username, displayName, password]) {
            guard reachable > revealed else { return }
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { revealed = max(revealed, reachable) }
        }
        .onChange(of: username) { model.clearSignupError("username"); advanceAfterCheck = false }
        .onChange(of: displayName) { model.clearSignupError("display_name") }
        .onChange(of: password) { model.clearSignupError("password"); passwordWasCleared = false }
        .onChange(of: model.signupFieldErrors) { _, errors in if errors.contains(where: { $0.field == "username" }) { focus = .username } }
        .onDisappear { password = ""; confirmation = "" }
    }

    private var title: String {
        if usernameTaken { return "아이디만 바꿔 주세요" }
        return revealed >= 1 ? "거의 다 됐어요" : "아이디를 만들어 주세요"
    }
    private var subtitle: String {
        if usernameTaken { return "다른 아이디와 비밀번호를 입력하면 바로 가입돼요." }
        return revealed >= 1 ? "닉네임과 비밀번호만 정하면 끝나요." : "이메일 없이 아이디로 시작해요. 실명, 학번, 전화번호처럼 나를 알 수 있는 정보는 쓰지 말아 주세요."
    }
    private static let takenMessage = "이미 사용 중인 아이디예요. 다른 아이디를 입력해 주세요."
    private func serverHints(_ field: String) -> [AuthHint] {
        model.signupFieldErrors.filter { $0.field == field }.map { AuthHint(text: $0.code == "taken" ? Self.takenMessage : $0.message, tone: .bad) }
    }
    private var usernameHints: [AuthHint] {
        let server = serverHints("username")
        if !server.isEmpty { return server }
        switch SignupRules.usernameIssue(username) {
        case .empty: return [AuthHint(text: "영문 소문자로 시작하고, 영문 소문자·숫자·_로 4~20자")]
        case .tooShort: return [AuthHint(text: "4자 이상 입력해 주세요")]
        case .tooLong: return [AuthHint(text: "20자 이하로 입력해 주세요", tone: .bad)]
        case .mustStartWithLowercase: return [AuthHint(text: "영문 소문자로 시작해 주세요", tone: .bad)]
        case .invalidCharacter: return [AuthHint(text: "영문 소문자, 숫자, _만 쓸 수 있어요", tone: .bad)]
        case .none:
            switch usernameStatus {
            case nil: return [AuthHint(text: "사용할 수 있는지 확인하고 있어요")]
            case .available: return [AuthHint(text: "사용할 수 있는 아이디예요", tone: .good)]
            case .taken: return [AuthHint(text: Self.takenMessage, tone: .bad)]
            case .unknown: return [AuthHint(text: "쓸 수 있는 형식이에요", tone: .good)]
            }
        }
    }
    private var displayNameHints: [AuthHint] {
        var hints = serverHints("display_name")
        if hints.isEmpty, !displayName.isEmpty, !SignupRules.displayNameIsValid(displayName) {
            hints.append(AuthHint(text: "앞뒤 공백이나 제어 문자 없이 1~20자로 입력해 주세요.", tone: .bad))
        }
        return hints.isEmpty ? [AuthHint(text: "가입 후에는 바꿀 수 없어요. 실명 대신 별명을 써 주세요.")] : hints
    }
    // The no-recovery notice stays visible even next to a server error.
    private var passwordHints: [AuthHint] {
        let server = serverHints("password")
        return (server.isEmpty ? passwordRuleHint : server) + [AuthHint(text: "잊으면 복구할 수 없어요.")]
    }
    private var passwordRuleHint: [AuthHint] {
        switch SignupRules.passwordIssue(password) {
        case .empty: return []
        case .tooShort: return [AuthHint(text: "8자 이상 입력해 주세요", tone: .bad)]
        case .tooLong: return [AuthHint(text: "1024자 이하로 입력해 주세요", tone: .bad)]
        case .missingLetterOrDigit: return [AuthHint(text: "영문과 숫자를 함께 넣어 주세요", tone: .bad)]
        case .none: return [AuthHint(text: "사용할 수 있는 비밀번호예요", tone: .good)]
        }
    }
    private var confirmationHints: [AuthHint] {
        switch SignupRules.confirmation(confirmation, of: password) {
        case .pending: return []
        case .matches: return [AuthHint(text: "비밀번호가 일치해요", tone: .good)]
        case .differs: return [AuthHint(text: "비밀번호가 일치하지 않아요", tone: .bad)]
        }
    }
    private var submitArea: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let wait = max(0, Int(ceil(model.signupRetryUntil?.timeIntervalSince(context.date) ?? 0)))
            VStack(spacing: 8) {
                Button(action: submit) {
                    HStack(spacing: 8) {
                        if model.authenticating { ProgressView() }
                        Text(model.authenticating ? "계정을 만드는 중" : wait > 0 ? "\(wait)초 후 다시 시도할 수 있어요" : "회원가입")
                    }
                }
                .buttonStyle(AuthPrimaryButtonStyle(height: keyboardVisible ? 52 : 56))
                .disabled(model.authenticating || !isReady || wait > 0).accessibilityIdentifier("signup-submit")
                if model.authenticating { Button("가입 취소") { model.cancelLogin() }.font(.system(size: 14)).frame(minHeight: 44) }
            }
        }
    }
    private func advance(from field: Field) {
        if field == .username, SignupRules.usernameIsValid(username) {
            // The check decides, so wait for it. Return ends editing, so a username still in question takes the focus back.
            let status = usernameStatus
            if status == nil { advanceAfterCheck = true }
            if status == nil || status == .taken { Task { await Task.yield(); focus = .username }; return }
        }
        revealed = max(revealed, reachable)
        let next: Field? = switch field { case .username: .displayName; case .displayName: .password; case .password: .confirmation; case .confirmation: nil }
        let open = switch field { case .username: revealed >= 1; case .displayName: revealed >= 2; case .password: revealed >= 3; case .confirmation: false }
        // Wait a beat so a field opened just now exists before it takes focus.
        if open, let next { Task { await Task.yield(); focus = next } }
    }
    private func scroll(to field: Field?, _ proxy: ScrollViewProxy) {
        guard let field else { return }
        // Wait out the keyboard and the field opening, so the scroll uses the final visible height.
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            withAnimation(.easeOut(duration: 0.2)) {
                // The last field also brings the button into view.
                if field == .confirmation { proxy.scrollTo(submitAnchor, anchor: .bottom) } else { proxy.scrollTo(field, anchor: .center) }
            }
        }
    }
    private func submit() {
        guard !model.authenticating, isReady, (model.signupRetryUntil ?? .distantPast) <= Date() else { return }
        // Clear the view state immediately; retain the password only for this request.
        let submittedPassword = password; password = ""; confirmation = ""; focus = nil; showPassword = false; passwordWasCleared = true
        Task { await model.signup(username: username, displayName: displayName, password: submittedPassword) }
    }
}
