import SwiftUI

struct ExamView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drawing: DrawingController
    @ObservedObject var player: PianoPlayback
    @State private var zoom = 1.0
    @State private var confirmSubmit = false
    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header.padding(.horizontal, 28).padding(.vertical, 18).background(.white)
                Divider()
                if model.drawingMissing {
                    Label("이 기기에 편집 가능한 필기 원본이 없어요. 연습 기록에서 기존 이미지를 확인하거나 새 응시를 시작해 주세요.", systemImage: "exclamationmark.triangle").font(.subheadline).padding().foregroundStyle(.orange)
                }
                HStack(spacing: 14) {
                    tool("펜", icon: "pencil.tip", selected: !drawing.erasing) { drawing.erasing = false }
                    tool("지우개", icon: "eraser", selected: drawing.erasing) { drawing.erasing = true }
                    Picker("펜 굵기", selection: $drawing.penWidth) { Text("가는 펜").tag(CGFloat(1.5)); Text("보통 펜").tag(CGFloat(2)); Text("굵은 펜").tag(CGFloat(3)) }.pickerStyle(.menu)
                    Divider().frame(height: 22)
                    Button { drawing.undo() } label: { Image(systemName: "arrow.uturn.backward") }.accessibilityLabel("실행 취소")
                    Button { drawing.redo() } label: { Image(systemName: "arrow.uturn.forward") }.accessibilityLabel("다시 실행")
                    Spacer()
                    Toggle(isOn: $drawing.fingerDrawing) { Image(systemName: "hand.draw").accessibilityLabel("손가락으로 그리기") }.toggleStyle(.button).help("손가락 필기")
                    Menu { ForEach([1.0,1.5,2.0], id: \.self) { value in Button("\(Int(value*100))%") { zoom = value } } } label: { Label("\(Int(zoom*100))%", systemImage: "magnifyingglass") }
                }.font(.subheadline).padding(.horizontal, 28).padding(.vertical, 14).background(.white).disabled(model.isLocked)
                ScrollView([.horizontal, .vertical]) {
                    if let template = model.template {
                        AnswerCanvas(template: template, drawing: drawing)
                            .frame(width: max(540, proxy.size.width - 56) * zoom)
                            .shadow(color: .black.opacity(0.04), radius: 12, y: 4).padding(28)
                    } else {
                        ContentUnavailableView("악보를 준비해 주세요", systemImage: "music.note", description: Text("오선·악보의 해시와 피아노 리소스를 확인해야 시작할 수 있어요."))
                            .frame(width: max(400, proxy.size.width-56), height: 400)
                    }
                }.scrollDisabled(drawing.fingerDrawing && !model.isLocked)
                footer.padding(20).background(.white)
            }
        }
        .confirmationDialog("이 답안으로 제출할까요?", isPresented: $confirmSubmit, titleVisibility: .visible) {
            Button("답안 제출") { Task { await model.submit() } }
            Button("계속 작성하기", role: .cancel) { }
        } message: { Text("제출을 시작하면 현재 필기를 고정해 전송합니다. 통신이 끊겨도 같은 답안으로 복구할 수 있어요.") }
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.session?.attempt.question.title ?? "청음 연습").font(.headline)
                if let tempo = model.session?.attempt.playbackPlan.tempo { Text(tempo.label).font(.caption).foregroundStyle(.secondary) }
                Text(player.message).font(.subheadline).foregroundStyle(SORITheme.violet).accessibilityIdentifier("playback-status")
            }
            Spacer(minLength: 12)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let seconds = model.remaining
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                    Text(String(format: "%02d:%02d", seconds/60, seconds%60)).font(.system(size: 25, weight: .semibold, design: .monospaced)).monospacedDigit()
                }.foregroundStyle(seconds == 0 && model.session?.attempt.status == "in_progress" ? .orange : SORITheme.ink)
                 .accessibilityLabel("권장 남은 시간 \(seconds)초")
            }
        }
    }
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { statusText; Spacer(); actions }
            VStack(alignment: .leading, spacing: 16) { statusText; HStack { actions } }
        }
    }
    private var statusText: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(model.session?.frozen == true ? "현재 답안 고정 · 제출 복구 가능" : "이 iPad에 필기 자동 저장", systemImage: model.session?.frozen == true ? "lock" : "checkmark.icloud").font(.caption).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if model.remaining == 0 && model.session?.attempt.status == "in_progress" { Text("권장 시간이 지났어요. 답안을 제출해 주세요.").font(.caption).foregroundStyle(.orange) }
            }
        }
    }
    @ViewBuilder private var actions: some View {
        if !model.prepared { Button("악보 준비 재시도") { Task { await model.retryPrepare() } }.buttonStyle(.bordered) }
        else if model.session?.attempt.status == "ready" {
            Button { Task { await model.start() } } label: { Label("청음 시작", systemImage: "play.fill") }.buttonStyle(PrimaryButton())
        } else if model.session?.attempt.status == "in_progress" {
            if player.cursor.index <= 11 && model.session?.frozen != true {
                Button { player.isPlaying ? player.pause() : player.resume() } label: { Label(player.isPlaying ? "일시 정지" : "재생 계속", systemImage: player.isPlaying ? "pause.fill" : "play.fill") }.buttonStyle(.bordered)
            }
            if model.isLocked && model.session?.frozen != true { Button("필기 저장 재시도") { model.retryDrawingSave() }.buttonStyle(.bordered) }
            Button { if model.session?.frozen == true { Task { await model.submit() } } else { confirmSubmit = true } } label: { Label(model.session?.frozen == true ? "제출 복구" : "답안 제출", systemImage: "arrow.up.doc") }.buttonStyle(PrimaryButton()).disabled(model.drawingMissing)
        }
    }
    private func tool(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).padding(8).background(selected ? SORITheme.soft : .clear, in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain).foregroundStyle(selected ? SORITheme.violet : SORITheme.ink)
    }
}
