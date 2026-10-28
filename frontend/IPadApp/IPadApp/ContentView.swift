import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var visibility: NavigationSplitViewVisibility = .all
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 8) { WaveMark(); Text("SORI").font(.system(size: 29, weight: .heavy, design: .rounded)).tracking(3) }.padding(.horizontal, 24).padding(.top, 32)
                Text("소리에서 시작하는 음악 공부").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24)
                VStack(spacing: 8) {
                    sidebar("나의 연습실", icon: "square.grid.2x2", screen: .home)
                    sidebar("연습 기록", icon: "clock.arrow.circlepath", screen: .history)
                    sidebar("연결 설정", icon: "slider.horizontal.3", screen: .settings)
                }.padding(.horizontal, 14)
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Circle().fill(model.connected ? SORITheme.green : .orange).frame(width: 7, height: 7); Text(model.demo ? "로컬 데모" : "API 연결").font(.caption.weight(.semibold)) }
                    Text("한 음씩 듣고,\n한 걸음씩 자라나요.").font(.footnote).foregroundStyle(.secondary).lineSpacing(5)
                    Text("SORI · iPad 연습실").font(.caption2).foregroundStyle(.tertiary)
                }.padding(24)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).background(.white)
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 260)
        } detail: {
            NavigationStack {
                ZStack {
                    SORITheme.background.ignoresSafeArea()
                    if !model.demo && !model.connected && model.screen != .settings {
                        LoginView(model: model)
                    } else { switch model.screen {
                    case .home: HomeView(model: model)
                    case .question: QuestionView(model: model)
                    case .exam: ExamView(model: model, drawing: model.drawing, player: model.player)
                    case .result: ResultView(model: model)
                    case .history: HistoryView(model: model)
                    case .settings: SettingsView(model: model)
                    } }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if [.question,.exam,.result].contains(model.screen) {
                            Button { model.navigate(.home) } label: { Label("연습실", systemImage: "chevron.left") }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if let profile = model.profile { Label(profile.displayName, systemImage: "person.crop.circle").font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
                .toolbarBackground(SORITheme.background, for: .navigationBar)
                .overlay { if model.busy || (model.authenticating && model.connected) {
                    ZStack { Color.black.opacity(0.12).ignoresSafeArea(); VStack(spacing: 14) { ProgressView(); Text(model.busyText).font(.subheadline) }.padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) }
                } }
            }
        }
        .tint(SORITheme.violet).preferredColorScheme(.light)
        .task { await model.connect() }
        .alert("확인이 필요해요", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("확인") { model.error = nil } } message: { Text(model.error ?? "") }
        .confirmationDialog("서버 로그아웃을 확인하지 못했어요", isPresented: $model.logoutNeedsConfirmation, titleVisibility: .visible) {
            Button("서버 로그아웃 재시도") { Task { await model.logout() } }
            Button("이 기기에서만 로그아웃", role: .destructive) { model.localLogout() }
            Button("취소", role: .cancel) { }
        } message: { Text(model.logoutFailure ?? "") }
        .onChange(of: model.screen) { _, screen in visibility = screen == .exam ? .detailOnly : .all }
        .onChange(of: phase) { _, phase in
            if phase == .active { Task { await model.foregroundAgain() } }
            else { model.background() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: RunLoop.main)) { _ in model.player.invalidateAudio() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification).receive(on: RunLoop.main)) { _ in model.player.invalidateAudio() }
        .onReceive(NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange).receive(on: RunLoop.main)) { notification in model.player.audioConfigurationChanged(notification) }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            if let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable { model.player.pause() }
        }
    }
    private func sidebar(_ title: String, icon: String, screen: AppModel.Screen) -> some View {
        Button { model.navigate(screen) } label: {
            Label(title, systemImage: icon).font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(15)
                .foregroundStyle(model.screen == screen ? SORITheme.violet : SORITheme.ink.opacity(0.65))
                .background(model.screen == screen ? SORITheme.soft : .clear, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(model.busy || model.authenticating)
    }
}
