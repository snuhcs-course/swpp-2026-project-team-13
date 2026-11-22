import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        // A ZStack, not a Group: the modifiers below must run once, not once per branch.
        ZStack {
            if model.needsAuthentication && model.screen != .settings {
                AuthFlowView(model: model)
            } else if model.needsGoalSelection {
                GoalSelectionView(model: model).overlay { busyOverlay }
            } else { mainInterface }
        }
        .tint(SolfegeTheme.violet).preferredColorScheme(.light)
        .environment(\.tutorialScope, model.rhythmConnection?.scope)
        .task { await model.connect() }
        .alert("확인이 필요해요", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("확인") { model.error = nil } } message: { Text(model.error ?? "") }
        .confirmationDialog("서버 로그아웃을 확인하지 못했어요", isPresented: $model.logoutNeedsConfirmation, titleVisibility: .visible) {
            Button("서버 로그아웃 재시도") { Task { await model.logout() } }
            Button("이 기기에서만 로그아웃", role: .destructive) { model.localLogout() }
            Button("취소", role: .cancel) { }
        } message: { Text(model.logoutFailure ?? "") }
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
    @ViewBuilder private var busyOverlay: some View {
        if model.busy || (model.authenticating && model.connected) {
            ZStack { Color.black.opacity(0.12).ignoresSafeArea(); VStack(spacing: 14) { ProgressView(); Text(model.busyText).font(.subheadline) }.padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) }
        }
    }
    private var mainInterface: some View {
        NavigationStack {
            ZStack {
                SolfegeTheme.background.ignoresSafeArea()
                switch model.screen {
                case .main: MainHomeView(model:model)
                case .home: PracticeEntryView(model:model)
                case .practiceLevels: PracticeLevelSelectionView(model:model)
                case .practiceQuestions: HomeView(model:model)
                case .recommendingExam: ExamRecommendationView()
                case .examSelection: ExamSelectionView(model:model)
                case .levelTest: LevelTestView(model:model)
                case .question: QuestionIntroView(model: model)
                case .exam: ExamView(model: model, drawing: model.drawing, player: model.player)
                case .result: ResultView(model: model)
                case .history: HistoryView(model: model)
                case .settings: SettingsView(model: model)
                case .minigames: DrillStairsView(connection:model.rhythmConnection,back:{ model.navigate(.main) }).id(model.rhythmConnection?.identity ?? "disconnected")
                case .classical: ClassicalExamLibraryView(model:model)
                case .dailyTraining: DailyTrainingView(model:model)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { backButton }
                ToolbarItem(placement: .principal) {
                    // S9 shows the question's title; S16 never reveals which question was recommended.
                    if model.screen == .question, let question = model.selectedQuestion {
                        Text(model.selectedMode == .exam ? examTitle : question.title)
                            .font(.system(size: 22, weight: .bold)).foregroundStyle(SolfegeTheme.ink).accessibilityAddTraits(.isHeader)
                    } else if model.screen == .exam, let attempt = model.session?.attempt {
                        // S11: only Practice names the question; Exam stays anonymous.
                        Text(attempt.studyMode == .exam ? examTitle : attempt.question.title)
                            .font(.system(size: 20, weight: .bold)).foregroundStyle(SolfegeTheme.ink).accessibilityAddTraits(.isHeader)
                    }
                }
            }
            // Both result views own their header. A second navigation bar creates
            // another Home button and leaves an empty toolbar above the content.
            // A selected composer shows the shared question bank, which has its own header too.
            .toolbar([.main,.home,.practiceLevels,.practiceQuestions,.recommendingExam,.examSelection,.levelTest,.minigames,.result].contains(model.screen) || (model.screen == .classical && model.selectedComposer != nil) ? .hidden : .automatic, for: .navigationBar)
            .toolbarBackground(SolfegeTheme.background, for: .navigationBar)
            .overlay { if model.screen != .recommendingExam { busyOverlay } }
        }
    }
    // A level-test stage keeps the level test's name on the intro and writing screens.
    private var examTitle: String {
        model.session?.attempt.levelTestStage != nil && model.session?.attempt.question.id == model.selectedQuestion?.id ? "레벨 테스트" : StudyMode.exam.title
    }
    @ViewBuilder private var backButton: some View {
        if [.question,.exam,.result].contains(model.screen) {
            let target = model.screen == .result ? model.resultLibraryScreen : model.selectedMode == .exam ? .main : model.questionLibraryScreen
            back(target == .classical ? "클래식" : target == .main ? "홈" : target == .dailyTraining ? "오늘의 트레이닝" : model.selectedMode.title, to: target)
        } else if model.needsAuthentication {
            back("돌아가기", to: .main).accessibilityIdentifier("back-to-auth")
        } else if model.screen == .practiceQuestions {
            back("난이도 선택", to: .practiceLevels)
        } else if model.screen == .classical {
            back(model.selectedMode.title, to: model.libraryScreen)
        } else if model.screen != .main {
            back("홈", to: .main).disabled(model.busy || model.authenticating).accessibilityIdentifier("back-to-home")
        }
    }
    private func back(_ title: String, to screen: AppModel.Screen) -> some View {
        Button { model.navigate(screen) } label: { HStack(spacing: 4) { Image(systemName:"chevron.left"); Text(title) } }
            .disabled(model.writingTutorialOpen)
    }
}
