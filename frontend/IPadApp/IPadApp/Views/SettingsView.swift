import SwiftUI

struct SettingsView: View {
    @ObservedObject var model:AppModel
    @State private var token=""
    @State private var address = ""
    @State private var outcome = "completed"
    @State private var showSoundLicense = false
    @State private var rememberToken = true
    @State private var hasSavedToken = false
    var body: some View {
        ScrollView { VStack(alignment:.leading,spacing:28) {
            SectionCaption(eyebrow:"CONNECTION & PREFERENCES",title:"연결 설정",subtitle:"로컬 데모 또는 개발 중인 Django 서버에 연결하세요.")
            Card { VStack(alignment:.leading,spacing:20) {
                Toggle("로컬 데모 사용",isOn:Binding(get:{model.demo},set:{ value in Task { await model.setDemoMode(value) } })).font(.headline).disabled(model.busy).accessibilityIdentifier("use-local-demo")
                if model.demo {
                    Text("인터넷 없이 실제 오선·MXL·악기 음색·필기·제출 흐름을 확인할 수 있어요. 결과는 API 예시이며 필기를 인식하지 않습니다.").font(.subheadline).foregroundStyle(.secondary).lineSpacing(5)
                    Picker("데모 결과",selection:$outcome) { Text("완료 · 예시 81점").tag("completed"); Text("필기 확인 필요").tag("needs-review"); Text("분석 실패 · 재시도 가능").tag("failed") }
                } else {
                    Text("API 기준 주소").font(.subheadline.bold())
                    TextField("https://server/api/v1/",text:$address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).textFieldStyle(.roundedBorder).accessibilityIdentifier("api-base-url")
                    Text("개발용 Bearer 토큰").font(.subheadline.bold())
                    SecureField(hasSavedToken ? "저장된 토큰 사용 · 변경할 때만 입력" : "개발 토큰 입력",text:$token).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder).accessibilityIdentifier("development-token")
                    Toggle("이 서버의 토큰을 기기에 저장",isOn:$rememberToken).toggleStyle(TokenCheckboxStyle()).accessibilityIdentifier("remember-development-token")
                    if hasSavedToken && rememberToken { Label("저장된 토큰이 있어요. 비워 두고 연결해도 됩니다.",systemImage:"checkmark.shield.fill").font(.caption).foregroundStyle(.green).accessibilityIdentifier("saved-token-status") }
                    Text("저장을 선택하면 다음 앱 업데이트에도 토큰을 다시 사용할 수 있어요. 체크를 해제하면 이 서버에 저장한 토큰을 지웁니다.").font(.caption).foregroundStyle(.secondary)
                    Text("실제 iPad에서는 서버 PC의 LAN IP 주소를 사용해 주세요.").font(.caption).foregroundStyle(.secondary)
                }
                Button { Task {
                    model.server=address.trimmingCharacters(in:.whitespacesAndNewlines); model.demoOutcome=outcome
                    model.rememberToken=rememberToken
                    await model.connect(token:token.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil : token); token=""
                    updateSavedStatus()
                } } label: { Label(model.demo ? "데모 시작" : "서버 연결",systemImage:"arrow.right.circle") }.buttonStyle(PrimaryButton())
            } }
            Card { VStack(alignment:.leading,spacing:16) {
                Label("악기 음색",systemImage:"pianokeys").font(.headline)
                Picker("재생 악기",selection:Binding(get:{model.selectedVoice},set:{model.selectVoice($0)})) {
                    ForEach(model.instrumentVoices) { voice in Text(voice.title).tag(voice.id) }
                }
                Text("클래식 그랜드 피아노는 미니게임과 청음 시험에서 같은 소리로 재생돼요. 선택한 음색은 다음 연습의 음계와 선율에 함께 적용됩니다.").font(.subheadline).foregroundStyle(.secondary)
                Text("YDP Grand Piano · FreePats / 그 외 악기: GeneralUser GS").font(.caption).foregroundStyle(.secondary)
                Button("음원 출처와 이용 조건") { showSoundLicense = true }.font(.caption)
            } }
            if let user=model.profile {
                Card { VStack(alignment:.leading,spacing:16) {
                    Text("나의 학습 목표").font(.headline)
                    Picker("학습 목표",selection:Binding(get:{user.learningGoal},set:{ goal in Task { await model.updateGoal(goal) } })) { ForEach(SORITheme.goals,id:\.0) { key,title in Text(title).tag(key) } }
                } }
            }
            Card { VStack(alignment:.leading,spacing:12) {
                Label("필기와 응시 복구",systemImage:"externaldrive").font(.headline)
                Text("필기 원본, 고정된 제출 이미지와 요청 키는 사용자·서버별로 이 iPad에 보관합니다. 앱을 지우거나 기기를 바꾸면 편집 가능한 필기를 복구할 수 없습니다.").font(.subheadline).foregroundStyle(.secondary).lineSpacing(5)
                Text("API 계약 v0.6.0 · MusicXML 4.0 · GeneralUser GS").font(.caption).foregroundStyle(.tertiary)
            } }
        }.padding(32).frame(maxWidth:900).frame(maxWidth:.infinity) }
        .sheet(isPresented:$showSoundLicense) {
            NavigationStack {
                ScrollView { VStack(alignment:.leading,spacing:24) {
                    Text((try? String(data:Bundled.data("melody-piano-license",ext:"txt"),encoding:.utf8)) ?? "클래식 피아노 라이선스를 불러오지 못했습니다.")
                    Text((try? String(data:Bundled.data("generaluser-license",ext:"txt"),encoding:.utf8)) ?? "GeneralUser GS 라이선스를 불러오지 못했습니다.")
                }.font(.footnote).textSelection(.enabled).padding() }
                    .navigationTitle("음원 출처와 이용 조건")
                    .toolbar { ToolbarItem(placement:.confirmationAction) { Button("닫기") { showSoundLicense = false } } }
            }
        }
        .onAppear { address=model.server; outcome=model.demoOutcome; rememberToken=model.rememberToken; updateSavedStatus() }
        .onChange(of:address) { _,_ in updateSavedStatus() }
        .onChange(of:rememberToken) { _,value in model.setRememberToken(value,server:address); updateSavedStatus() }
    }
    private func updateSavedStatus() { hasSavedToken = !((try? TokenVault.read(server:address)) ?? "").isEmpty }
}

private struct TokenCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing:12) {
                Image(systemName:configuration.isOn ? "checkmark.square.fill" : "square").font(.title2).foregroundStyle(SORITheme.violet)
                configuration.label.foregroundStyle(.primary)
            }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(configuration.isOn ? "선택됨" : "선택 안 됨")
    }
}
