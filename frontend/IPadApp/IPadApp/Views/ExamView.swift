import SwiftUI

// Live Practice/Exam and its read-only contextual guide share one layout.
struct ExamView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drawing: DrawingController
    @ObservedObject var player: PianoPlayback
    @State private var confirmSubmit = false
    @Environment(\.tutorialScope) private var tutorialScope
    private var attempt: Attempt? { model.session?.attempt }
    private var practice: Bool { attempt?.studyMode != .exam }
    private var frozen: Bool { model.session?.frozen == true }
    var body: some View {
        WritingScreenLayout {
            header
        } warning: {
            if model.drawingMissing {
                Label("이 기기에 편집 가능한 필기 원본이 없어요. 연습 기록에서 기존 이미지를 확인하거나 새 응시를 시작해 주세요.", systemImage: "exclamationmark.triangle")
                    .font(.subheadline).padding(.horizontal, 28).padding(.bottom, 8).foregroundStyle(.orange)
            }
        } tools: { drawingTools } sheet: { answerSheet } footer: { footer }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    TutorialHelpButton(label: "시험 모드 안내", action: model.openWritingTutorial)
                        .padding(.trailing, 14)
                        .disabled(!model.prepared || frozen || model.writingTutorialOpen)
                }
            }
            .writingTutorial(isPresented: model.writingTutorialOpen, mode: practice ? .practice : .exam) {
                model.closeWritingTutorial()
            }
            .task(id: "\(attempt?.id.uuidString ?? "")-\(model.prepared)") {
                if model.prepared && attempt?.status == "ready" && !TutorialHistory.hasSeen(.exam, scope: tutorialScope) {
                    model.openWritingTutorial()
                }
            }
            .onDisappear { model.closeWritingTutorial(resumePlayback: false) }
    }
    private var header: some View {
        WritingScreenHeader {
            if let q = attempt?.question, let plan = attempt?.playbackPlan {
                WritingQuestionMeta(key: q.keySignature, meter: q.timeSignature,
                                    tempo: plan.tempo?.label ?? "♩ = \(Int(plan.tempoBpm.rounded()))")
            }
        } progress: {
            SegmentProgressBar(cursor: player.cursor, onSelect: canJump ? { player.jump(to: $0) } : nil).tutorialTarget(.progress)
        } clock: {
            WritingTimer(cursor: player.cursor, plan: attempt?.playbackPlan, isPlaying: player.isPlaying).tutorialTarget(.timer)
        }
    }
    private var canJump: Bool {
        practice && model.prepared && attempt?.status == "in_progress" && !frozen && !model.isLocked && !model.busy && !model.writingTutorialOpen
    }
    private var drawingTools: some View {
        WritingToolsRow(erasing: drawing.erasing, penWidth: drawing.penWidth, canUndo: drawing.canUndo, canRedo: drawing.canRedo,
                        pen: { drawing.erasing = false }, erase: { drawing.erasing = true },
                        chooseWidth: { drawing.penWidth = $0; drawing.erasing = false }, undo: drawing.undo, redo: drawing.redo)
            .disabled(model.isLocked).tutorialTarget(.tools)
    }
    private var answerSheet: some View {
        WritingSheetFrame(displayHeight: attempt?.question.sheetLayout.displayHeight ?? 846) { width in
            if let template = model.template {
                AnswerCanvas(template: template, drawing: drawing, layout: attempt?.question.sheetLayout)
                    .frame(width: width)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.black.opacity(0.06)))
                    .shadow(color: .black.opacity(0.04), radius: 12, y: 4).tutorialTarget(.notation)
            } else {
                ContentUnavailableView("악보를 준비해 주세요", systemImage: "music.note", description: Text("오선·악보의 해시와 피아노 리소스를 확인해야 시작할 수 있어요."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
    private var footer: some View { WritingScreenFooter(frozen: frozen) { actions } }
    @ViewBuilder private var actions: some View {
        if !model.prepared {
            Button("악보 준비 재시도") { Task { await model.retryPrepare() } }.buttonStyle(SecondaryActionButton())
        } else if attempt?.status == "ready" {
            nextSegmentButton
            Button { Task { await model.start() } } label: { Label("청음 시작", systemImage: "play.fill") }
                .buttonStyle(PrimaryButton()).frame(width: 150).tutorialTarget(.start)
        } else if attempt?.status == "in_progress" {
            if player.cursor.index <= 11 && !frozen {
                if practice {
                    Button { player.isPlaying ? player.pause() : player.resume() } label: {
                        Label(player.isPlaying ? "일시 정지" : "재생", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                    }.buttonStyle(SecondaryActionButton()).accessibilityIdentifier("play-pause").tutorialTarget(.playPause)
                } else if !player.isPlaying && !model.writingTutorialOpen {
                    Button { player.resume() } label: { Label("이어서 재생", systemImage: "play.fill") }
                        .buttonStyle(SecondaryActionButton()).accessibilityIdentifier("resume-playback")
                }
            }
            if !frozen { nextSegmentButton }
            if model.isLocked && !frozen {
                Button("필기 저장 재시도") { model.retryDrawingSave() }.buttonStyle(SecondaryActionButton())
            }
            Button { if frozen { Task { await model.submit() } } else { confirmSubmit = true } } label: {
                Text(frozen ? "제출 복구" : "답안 제출")
            }.buttonStyle(PrimaryButton()).frame(width: 150).disabled(model.drawingMissing).accessibilityIdentifier("submit-answer").tutorialTarget(.submit)
                .popover(isPresented: $confirmSubmit, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                    AnswerConfirmation(title: "이 답안으로 제출할까요?",
                                       message: practice ? "제출을 시작하면 현재 필기를 고정해 전송합니다.\n통신이 끊겨도 같은 답안으로 복구할 수 있어요." : "제출하면 현재 필기를 고정해 AI 평가로 전송합니다.\n제출 후에는 답안을 수정할 수 없어요.",
                                       confirmTitle: "답안 제출", cancelTitle: "계속 작성하기", confirmIdentifier: "confirm-submit") {
                        confirmSubmit = false; Task { await model.submit() }
                    } cancel: { confirmSubmit = false }
                    .presentationCompactAdaptation(.popover)
                }
        }
    }
    var nextSegmentEnabled: Bool {
        attempt?.status == "in_progress" && player.cursor.phase == "gap" && player.canSkipWritingWait &&
            !frozen && !model.isLocked && !model.busy && !model.writingTutorialOpen
    }
    private var nextSegmentButton: some View {
        Button { player.skipWritingWait() } label: { Label("다음 구간", systemImage: "forward.end.fill") }
            .buttonStyle(SecondaryActionButton()).frame(width: 150).disabled(!nextSegmentEnabled)
            .accessibilityIdentifier("skip-writing-wait").tutorialTarget(.next)
    }
}

// Scale and all eleven listening segments share one stable progress bar.
struct SegmentProgressBar: View {
    let cursor: PlaybackCursor
    var onSelect: ((Int) -> Void)? = nil
    private var labels: [String] {
        ["스케일"] + PlaybackPlan.examMeasureRanges.map { "\($0.from)–\($0.to)" }
    }
    var body: some View {
        HStack(spacing:0) {
            ForEach(0..<12,id:\.self) { index in segment(index) }
        }
        .frame(height:36).background(.white).clipShape(Capsule())
        .overlay(Capsule().strokeBorder(SolfegeTheme.keyEdge,lineWidth:1.5))
        .accessibilityElement(children:onSelect == nil ? .ignore : .contain)
        .accessibilityLabel(onSelect == nil ? "구간 진행 \(min(12,cursor.progressIndex+1)) / 12" : "구간 진행")
        .accessibilityIdentifier("segment-progress")
    }
    @ViewBuilder private func segment(_ index: Int) -> some View {
        let current = cursor.progressIndex == index
        let done = cursor.progressIndex > index
        let label = Text(labels[index]).font(.system(size:12,weight:.bold))
            .foregroundStyle(current ? .white : done ? SolfegeTheme.deepViolet : SolfegeTheme.ink)
            .frame(maxWidth:.infinity,maxHeight:.infinity)
            .background(current ? SolfegeTheme.violet : done ? SolfegeTheme.keyUnavailable : .clear)
            .overlay(alignment:.leading) {
                if index > 0 && !current && index-1 != cursor.progressIndex {
                    Rectangle().fill(SolfegeTheme.keyEdge).frame(width:1,height:18)
                }
            }
        if let onSelect {
            Button { onSelect(index) } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(index == 0 ? "스케일 다시 듣기" : "\(index)번째 구간 \(labels[index])마디 다시 듣기")
                .accessibilityIdentifier("segment-\(index)")
        } else { label }
    }
}

struct WritingTimer: View {
    let cursor: PlaybackCursor
    let plan: PlaybackPlan?
    var isPlaying = true
    var body: some View {
        let state = WritingTimerState(cursor:cursor,plan:plan,isPlaying:isPlaying)
        VStack(alignment:.trailing,spacing:1) {
            Text(state.caption).font(.system(size:11)).foregroundStyle(SolfegeTheme.muted)
            HStack(spacing:7) {
                Image(systemName:"clock").font(.system(size:15,weight:.medium))
                Text(state.text).font(.system(size:34,weight:.semibold)).monospacedDigit().frame(width:100,alignment:.trailing)
            }.foregroundStyle(state.urgent ? Color.orange : SolfegeTheme.ink)
        }
        .frame(width:132,height:56,alignment:.trailing)
        .padding(.horizontal,10).padding(.vertical,4)
        .background(Color.black.opacity(0.025),in:RoundedRectangle(cornerRadius:10))
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("\(state.caption) \(state.text)")
        .accessibilityIdentifier("writing-timer")
    }
}

struct SecondaryActionButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .bold))
            .padding(.horizontal, 20).padding(.vertical, 15)
            .foregroundStyle(enabled ? SolfegeTheme.deepViolet : SolfegeTheme.disabledText)
            .background((enabled ? SolfegeTheme.soft : SolfegeTheme.disabledFill).opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 12))
    }
}
