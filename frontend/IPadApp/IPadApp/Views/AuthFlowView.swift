import SwiftUI

// Full-screen signup and login: the intro panel beside (or above) one form.
struct AuthFlowView: View {
    @ObservedObject var model: AppModel
    @State private var keyboardOverlap: CGFloat = 0
    // Form and footer heights in the tallest state, so short screens give up the top margin first.
    private static let formHeight: CGFloat = 704

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 900
            let keyboardVisible = keyboardOverlap > 0
            let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                if wide || !keyboardVisible {
                    AuthIntroPanel(compact: !wide).frame(width: wide ? proxy.size.width * 0.452 : nil, height: wide ? nil : 300)
                }
                ZStack(alignment: .topTrailing) {
                    form(keyboardVisible: keyboardVisible, topInset: wide ? min(96, max(16, proxy.size.height - Self.formHeight)) : 24)
                    Button { model.navigate(.settings) } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 19)).foregroundStyle(SolfegeTheme.muted).frame(width: 64, height: 64).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(10).accessibilityLabel("서버 연결 설정").accessibilityIdentifier("server-settings")
                }
                .padding(.bottom, keyboardOverlap)
                .background(Color.white.ignoresSafeArea())
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let overlap = proxy.frame(in: .global).maxY - frame.minY
                // A hardware keyboard only leaves a short shortcut bar.
                withAnimation(.easeOut(duration: 0.25)) { keyboardOverlap = overlap > 120 ? overlap : 0 }
            }
        }
        .ignoresSafeArea(.keyboard)
        .task(id: model.server) { await model.refreshSignupAvailability() }
    }
    @ViewBuilder private func form(keyboardVisible: Bool, topInset: CGFloat) -> some View {
        if model.showingSignup && model.signupEnabled {
            SignupView(model: model, keyboardVisible: keyboardVisible, topInset: topInset)
        } else {
            LoginView(model: model, keyboardVisible: keyboardVisible, topInset: topInset)
        }
    }
}

// The scrolling form column with its pinned footer; the footer yields to the keyboard.
struct AuthForm<Content: View, Footer: View>: View {
    let keyboardVisible: Bool
    let topInset: CGFloat
    @ViewBuilder let content: (ScrollViewProxy) -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) { content(proxy) }
                        .frame(maxWidth: 440, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.top, keyboardVisible ? 24 : topInset)
                        .padding(.bottom, 16)
                }.scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
            }
            if !keyboardVisible { footer().padding(.bottom, 16) }
        }
    }
}

struct AuthHeader: View {
    let title: String
    let subtitle: String
    let compact: Bool
    var body: some View {
        if compact {
            Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(SolfegeTheme.ink).accessibilityAddTraits(.isHeader)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 34, weight: .bold)).foregroundStyle(SolfegeTheme.ink).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.system(size: 16)).foregroundStyle(SolfegeTheme.muted).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }.frame(minHeight: 98, alignment: .top)
        }
    }
}

struct AuthHint: Identifiable, Equatable {
    enum Tone { case neutral, good, bad }
    let text: String
    var tone = Tone.neutral
    var id: String { text }
}

// A labelled input with its hints underneath.
struct AuthField<Input: View>: View {
    let title: String
    let focused: Bool
    var hints: [AuthHint] = []
    // The text line is shorter than the box, so the rest of the box has to pass taps on.
    let focus: () -> Void
    @ViewBuilder let input: () -> Input
    private var failed: Bool { hints.contains { $0.tone == .bad } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(SolfegeTheme.ink)
            input()
                .font(.system(size: 17)).foregroundStyle(SolfegeTheme.ink)
                .padding(.horizontal, 16).frame(height: 52)
                .contentShape(RoundedRectangle(cornerRadius: 12)).onTapGesture(perform: focus)
                .background(focused || failed ? Color.white : SolfegeTheme.field, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(failed ? SolfegeTheme.danger : focused ? SolfegeTheme.violet : .clear, lineWidth: 2))
                .animation(.easeOut(duration: 0.16), value: focused)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(hints) { hint in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if hint.tone == .good { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
                        Text(hint.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(hint.tone == .bad ? SolfegeTheme.danger : hint.tone == .good ? SolfegeTheme.green : SolfegeTheme.muted)
                }
            }.frame(minHeight: 18, alignment: .top)
        }
    }
}

// Switches the field between masked and plain text; Keychain-style autofill stays on both.
struct AuthPasswordInput<Field: Hashable>: View {
    let placeholder: String
    @Binding var text: String
    @Binding var revealed: Bool
    let contentType: UITextContentType
    let identifier: String
    var showsToggle = true
    let focus: FocusState<Field?>.Binding
    let field: Field

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if revealed { TextField(placeholder, text: $text).keyboardType(.asciiCapable) } else { SecureField(placeholder, text: $text) }
            }
            .textContentType(contentType).textInputAutocapitalization(.never).autocorrectionDisabled()
            .focused(focus, equals: field).accessibilityIdentifier(identifier)
            if showsToggle {
                Button {
                    revealed.toggle()
                    if focus.wrappedValue == field { Task { await Task.yield(); focus.wrappedValue = field } }
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye").font(.system(size: 17)).foregroundStyle(SolfegeTheme.muted).frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.trailing, -10).accessibilityLabel(revealed ? "비밀번호 가리기" : "비밀번호 보기")
            }
        }
    }
}

struct AuthPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var height: CGFloat = 56
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 17, weight: .bold)).frame(maxWidth: .infinity).frame(height: height)
            .foregroundStyle(enabled ? Color.white : SolfegeTheme.disabledText)
            .background((enabled ? SolfegeTheme.violet : SolfegeTheme.disabledFill).opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 12))
            .animation(.easeOut(duration: 0.2), value: enabled)
    }
}

// "이미 회원이신가요? 로그인" and its counterpart.
struct AuthSwitchLink: View {
    let prompt: String
    let action: String
    let identifier: String
    let perform: () -> Void
    var body: some View {
        HStack(spacing: 2) {
            Text(prompt).foregroundStyle(SolfegeTheme.muted)
            Button(action: perform) { Text(action).fontWeight(.medium).underline().padding(.horizontal, 6).frame(height: 44) }
                .buttonStyle(.plain).foregroundStyle(SolfegeTheme.violet).accessibilityIdentifier(identifier)
        }.font(.system(size: 14))
    }
}

struct AuthCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isOn ? SolfegeTheme.violet : Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(configuration.isOn ? SolfegeTheme.violet : SolfegeTheme.muted, lineWidth: 1.5))
                    .overlay { if configuration.isOn { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) } }
                    .frame(width: 22, height: 22)
                configuration.label.font(.system(size: 15)).foregroundStyle(SolfegeTheme.ink)
            }.frame(height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}
