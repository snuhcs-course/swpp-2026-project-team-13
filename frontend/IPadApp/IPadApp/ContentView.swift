import SwiftUI

struct ContentView: View {
    @State private var isChecking = false
    @State private var connectionMessage = "서버 연결을 확인해 보세요."
    private let apiClient = APIClient()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "ipad")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("새 프로젝트를 시작합니다")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("이곳에 아이패드 앱의 기능을 추가할 수 있습니다.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await checkConnection() }
                } label: {
                    HStack {
                        if isChecking { ProgressView() }
                        Text(isChecking ? "확인 중…" : "서버 연결 확인")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isChecking)
                Text(connectionMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("connectionStatus")
            }
            .padding(32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Team 13")
        }
    }

    @MainActor
    private func checkConnection() async {
        isChecking = true
        defer { isChecking = false }
        do {
            _ = try await apiClient.checkHealth()
            connectionMessage = "서버에 연결되었습니다."
        } catch {
            connectionMessage = "연결하지 못했습니다. \(error.localizedDescription)"
        }
    }
}

#Preview {
    ContentView()
}
