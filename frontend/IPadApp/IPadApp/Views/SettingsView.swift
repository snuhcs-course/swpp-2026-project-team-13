import SwiftUI

struct SettingsView: View {
    @ObservedObject var model:AppModel
    @State private var token=""
    @State private var useDemo = true
    @State private var address = ""
    @State private var outcome = "completed"
    var body: some View {
        ScrollView { VStack(alignment:.leading,spacing:28) {
            SectionCaption(eyebrow:"CONNECTION & PREFERENCES",title:"연결 설정",subtitle:"로컬 데모 또는 개발 중인 Django 서버에 연결하세요.")
            Card { VStack(alignment:.leading,spacing:20) {
                Toggle("로컬 데모 사용",isOn:$useDemo).font(.headline)
                if useDemo {
                    Text("인터넷 없이 실제 오선·MXL·합성 피아노·필기·제출 흐름을 확인할 수 있어요. 결과는 API 예시이며 필기를 인식하지 않습니다.").font(.subheadline).foregroundStyle(.secondary).lineSpacing(5)
                    Picker("데모 결과",selection:$outcome) { Text("완료 · 예시 81점").tag("completed"); Text("필기 확인 필요").tag("needs-review"); Text("분석 실패 · 재시도 가능").tag("failed") }
                } else {
                    Text("API 기준 주소").font(.subheadline.bold())
                    TextField("https://server/api/v1/",text:$address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).textFieldStyle(.roundedBorder).accessibilityIdentifier("api-base-url")
                    Text("개발용 Bearer 토큰").font(.subheadline.bold())
                    SecureField("새 토큰 입력 · 비워두면 저장된 토큰 사용",text:$token).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    Text("토큰은 이 기기의 Keychain에 저장됩니다. 실제 iPad에서 로컬 서버에 접속할 때는 서버를 실행하는 PC의 LAN IP 주소를 사용해 주세요.").font(.caption).foregroundStyle(.secondary)
                }
                Button { Task {
                    model.demo=useDemo; model.server=address.trimmingCharacters(in:.whitespacesAndNewlines); model.demoOutcome=outcome
                    await model.connect(token:token.isEmpty ? nil : token); token=""
                } } label: { Label(useDemo ? "데모 시작" : "서버 연결",systemImage:"arrow.right.circle") }.buttonStyle(PrimaryButton())
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
                Text("API 계약 v0.2.0 · MusicXML 4.0 · sori-piano-v1").font(.caption).foregroundStyle(.tertiary)
            } }
        }.padding(32).frame(maxWidth:900).frame(maxWidth:.infinity) }
        .onAppear { useDemo=model.demo; address=model.server; outcome=model.demoOutcome }
    }
}
