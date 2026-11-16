import SwiftUI

// S11 Writing and S12 Confirm submit, for both Practice and Exam.
// Practice adds play/pause and tap-to-replay on the segment bar; Exam only moves forward.
struct ExamView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drawing: DrawingController
    @ObservedObject var player: PianoPlayback
    @State private var confirmSubmit = false

    private var attempt: Attempt? { model.session?.attempt }
    private var practice: Bool { attempt?.studyMode != .exam }
    private var frozen: Bool { model.session?.frozen == true }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 28).padding(.top, 6).padding(.bottom, 12)
            if player.showsScaleNotice, let key = player.scaleKey {
                scaleNotice(key).padding(.horizontal, 28).padding(.bottom, 12)
            }
            if model.drawingMissing {
                Label("이 기기에 편집 가능한 필기 원본이 없어요. 연습 기록에서 기존 이미지를 확인하거나 새 응시를 시작해 주세요.", systemImage: "exclamationmark.triangle").font(.subheadline).padding(.horizontal, 28).padding(.bottom, 8).foregroundStyle(.orange)
            }
            drawingTools.padding(.horizontal, 28).padding(.bottom, 12).disabled(model.isLocked)
            answerSheet.padding(.horizontal, 28)
            footer.padding(.horizontal, 28).padding(.vertical, 16)
        }
        .background(SolfegeTheme.background)
    }

    // MARK: Header — key/meter/tempo · segment progress · writing timer

    private var header: some View {
        HStack(spacing: 20) {
            questionMeta.fixedSize().frame(maxWidth: .infinity, alignment: .leading)
            SegmentProgressBar(cursor: player.cursor, onSelect: canJump ? { player.jump(to: $0) } : nil)
                .frame(minWidth: 360, idealWidth: 560, maxWidth: 560).layoutPriority(1)
            WritingTimer(cursor: player.cursor, plan: attempt?.playbackPlan)
                .fixedSize().frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var canJump: Bool {
        practice && model.prepared && attempt?.status == "in_progress" && !frozen && !model.isLocked && !model.busy
    }

    private var questionMeta: some View {
        HStack(spacing: 6) {
            if let q = attempt?.question, let plan = attempt?.playbackPlan {
                metaChip(q.keySignature.label)
                metaChip("\(q.timeSignature.numerator)/\(q.timeSignature.denominator)박자")
                    .accessibilityLabel("\(q.timeSignature.numerator)분의 \(q.timeSignature.denominator)박자")
                metaChip(plan.tempo?.label ?? "♩ = \(Int(plan.tempoBpm.rounded()))")
            }
        }
        .accessibilityElement(children: .combine).accessibilityIdentifier("question-meta")
    }

    private func metaChip(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .bold)).foregroundStyle(SolfegeTheme.ink)
            .padding(.horizontal, 11).padding(.vertical, 4)
            .background(SolfegeTheme.soft, in: Capsule())
    }

    private func scaleNotice(_ key: KeySignature) -> some View {
        let sounding = player.isPlaying && player.cursor.phase == "segment"
        return HStack(spacing:18) {
            Image(systemName:"pianokeys").font(.system(size:32)).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:6) {
                Text("\(key.label)\(key.mode == "minor" ? " 자연단음계" : " 음계") \(sounding ? "듣는 중" : "안내")")
                    .font(.title2.bold()).accessibilityIdentifier("scale-notice-title")
                Text("문제에 앞서 이 조성의 기준음을 들려드려요.").font(.subheadline)
                if let began = player.scaleStartedAt, sounding {
                    TimelineView(.animation(minimumInterval:0.1)) { context in
                        ProgressView(value:min(1,max(0,context.date.timeIntervalSince(began)/max(0.1,player.scaleDuration))))
                            .tint(SolfegeTheme.violet).accessibilityLabel("음계 재생 진행")
                    }
                }
            }
            Spacer(minLength:0)
        }.foregroundStyle(SolfegeTheme.violet).padding(18)
            .frame(maxWidth:.infinity,alignment:.leading).background(SolfegeTheme.soft,in:RoundedRectangle(cornerRadius:16))
            .accessibilityElement(children:.contain).accessibilityIdentifier("scale-notice")
    }

    // MARK: Drawing tools — pen, eraser, three pen widths, undo/redo

    private struct PenWidth { let width: CGFloat; let label: String; let dot: CGFloat }
    private static let penWidths = [PenWidth(width: 1.5, label: "가는 펜", dot: 4), PenWidth(width: 2, label: "보통 펜", dot: 8), PenWidth(width: 3, label: "굵은 펜", dot: 13)]

    private var drawingTools: some View {
        HStack(spacing: 4) {
            tool("펜", icon: "pencil.tip", selected: !drawing.erasing) { drawing.erasing = false }
            tool("지우개", icon: "eraser", selected: drawing.erasing) { drawing.erasing = true }
            toolDivider
            ForEach(Self.penWidths, id: \.width) { option in
                let selected = drawing.penWidth == option.width
                Button { drawing.penWidth = option.width; drawing.erasing = false } label: {
                    Circle().fill(selected ? SolfegeTheme.deepViolet : SolfegeTheme.ink).frame(width: option.dot, height: option.dot)
                        .frame(width: 38, height: 38)
                        .background(selected ? SolfegeTheme.soft : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? SolfegeTheme.violet : .clear, lineWidth: 2))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label).accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("pen-width-\(option.width)")
            }
            toolDivider
            Button { drawing.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 36, height: 36) }
                .disabled(!drawing.canUndo).accessibilityLabel("실행 취소")
            Button { drawing.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 36, height: 36) }
                .disabled(!drawing.canRedo).accessibilityLabel("다시 실행")
            Spacer(minLength: 0)
        }
        .font(.subheadline).foregroundStyle(SolfegeTheme.ink)
    }

    private var toolDivider: some View {
        Rectangle().fill(SolfegeTheme.keyEdge).frame(width: 1, height: 22).padding(.horizontal, 6)
    }

    private func tool(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 14, weight: selected ? .bold : .regular))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(selected ? SolfegeTheme.soft : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).foregroundStyle(selected ? SolfegeTheme.deepViolet : SolfegeTheme.softInk)
    }

    // MARK: Answer sheet — the whole 8-bar sheet always fits; it never scrolls.

    private var answerSheet: some View {
        GeometryReader { proxy in
            let height = Double(attempt?.question.sheetLayout.displayHeight ?? 846)
            let width = max(0, min(proxy.size.width, proxy.size.height * 1330 / height))
            Group {
                if let template = model.template {
                    AnswerCanvas(template: template, drawing: drawing, layout: attempt?.question.sheetLayout)
                        .frame(width: width)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.black.opacity(0.06)))
                        .shadow(color: .black.opacity(0.04), radius: 12, y: 4)
                } else {
                    ContentUnavailableView("악보를 준비해 주세요", systemImage: "music.note", description: Text("오선·악보의 해시와 피아노 리소스를 확인해야 시작할 수 있어요."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }

    // MARK: Footer — save status · (play/pause) · next segment · submit

    private var footer: some View {
        HStack(spacing: 8) {
            Label(frozen ? "현재 답안 고정 · 제출 복구 가능" : "이 iPad에 필기 자동 저장", systemImage: frozen ? "lock" : "checkmark.icloud")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            actions
        }
    }

    @ViewBuilder private var actions: some View {
        if !model.prepared { Button("악보 준비 재시도") { Task { await model.retryPrepare() } }.buttonStyle(SecondaryActionButton()) }
        else if attempt?.status == "ready" {
            Button { Task { await model.start() } } label: { Label("청음 시작", systemImage: "play.fill") }.buttonStyle(PrimaryButton())
        } else if attempt?.status == "in_progress" {
            if player.cursor.index <= 11 && !frozen {
                if practice {
                    Button { player.isPlaying ? player.pause() : player.resume() } label: {
                        Label(player.isPlaying ? "일시 정지" : "재생", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                    }.buttonStyle(SecondaryActionButton()).accessibilityIdentifier("play-pause")
                } else if !player.isPlaying {
                    // Exam has no pause control. Sound stopped by leaving the app still needs
                    // an explicit tap to come back, so offer only that.
                    Button { player.resume() } label: { Label("이어서 재생", systemImage: "play.fill") }
                        .buttonStyle(SecondaryActionButton()).accessibilityIdentifier("resume-playback")
                }
            }
            if (1...10).contains(player.cursor.index), !frozen {
                Button { player.skipWritingWait() } label: { Label("다음 구간", systemImage: "forward.end.fill") }
                    .buttonStyle(SecondaryActionButton()).disabled(!player.canSkipWritingWait || model.isLocked || model.busy)
                    .accessibilityIdentifier("skip-writing-wait")
            }
            if model.isLocked && !frozen { Button("필기 저장 재시도") { model.retryDrawingSave() }.buttonStyle(SecondaryActionButton()) }
            Button { if frozen { Task { await model.submit() } } else { confirmSubmit = true } } label: {
                Text(frozen ? "제출 복구" : "답안 제출")
            }
            .buttonStyle(PrimaryButton()).disabled(model.drawingMissing).accessibilityIdentifier("submit-answer")
            // A popover keeps the sheet visible (no dimming) and points at the button it belongs to.
            .popover(isPresented: $confirmSubmit, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                SubmitConfirmation(exam: !practice) {
                    confirmSubmit = false
                    Task { await model.submit() }
                } cancel: { confirmSubmit = false }
                .presentationCompactAdaptation(.popover)
            }
        }
    }
}

// The 11 listening segments in the S9/S16 playback-order style, filled from the left as they play.
struct SegmentProgressBar: View {
    let cursor: PlaybackCursor
    // Practice passes a handler so a segment can be tapped to hear it again.
    var onSelect: ((Int) -> Void)? = nil
    private let ranges = PlaybackPlan.examMeasureRanges

    // 0-based segment that is playing or whose writing time is running.
    private var current: Int? { (1...11).contains(cursor.index) ? cursor.index - 1 : nil }
    private var finished: Int { min(11, max(0, cursor.index - 1)) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(ranges.enumerated()), id: \.offset) { index, range in
                segment(index, range)
            }
        }
        .frame(height: 32)
        .background(.white)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(SolfegeTheme.keyEdge, lineWidth: 1.5))
        .accessibilityElement(children: onSelect == nil ? .ignore : .contain)
        .accessibilityLabel(onSelect == nil ? "구간 진행 \(min(cursor.index, 11)) / 11" : "구간 진행")
        .accessibilityIdentifier("segment-progress")
    }

    @ViewBuilder private func segment(_ index: Int, _ range: (from: Int, to: Int)) -> some View {
        let isCurrent = index == current
        let done = index < finished && !isCurrent
        let label = Text("\(range.from)–\(range.to)").font(.system(size: 14, weight: .bold))
            .foregroundStyle(isCurrent ? .white : done ? SolfegeTheme.deepViolet : SolfegeTheme.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isCurrent ? SolfegeTheme.violet : done ? SolfegeTheme.keyUnavailable : .clear)
            .overlay(alignment: .leading) {
                // Dividers as on S9/S16, hidden next to the solid current segment.
                if index > 0 && !isCurrent && index - 1 != current {
                    Rectangle().fill(SolfegeTheme.keyEdge).frame(width: 1.5, height: 18).offset(x: -0.75)
                }
            }
        if let onSelect {
            Button { onSelect(index + 1) } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel("\(index + 1)번째 구간 \(range.from)에서 \(range.to)마디 다시 듣기")
                .accessibilityIdentifier("segment-\(index + 1)")
        } else {
            label
        }
    }
}

// Counts down only the writing time after each segment: 20 s between segments, 2 min after the last.
struct WritingTimer: View {
    let cursor: PlaybackCursor
    let plan: PlaybackPlan?

    private func limitMs(after index: Int) -> Int {
        guard let plan, (1...plan.steps.count).contains(index) else { return index == 11 ? 120_000 : 20_000 }
        return plan.steps[index - 1].pauseAfterMs
    }

    private var state: (ms: Int, caption: String, live: Bool) {
        switch cursor.index {
        case 0: return (limitMs(after: 1), "필기 시간", false)
        case 1...11:
            if cursor.phase == "gap" {
                if cursor.shortenedGap == true { return (0, "다음 구간 준비", false) }
                return (cursor.remainingWaitMs ?? limitMs(after: cursor.index), "필기 남은 시간", true)
            }
            return (limitMs(after: cursor.index), "재생 후 필기 시간", false)
        default: return (0, "필기 시간 종료", false)
        }
    }

    var body: some View {
        let state = state
        let seconds = (state.ms + 999) / 1000
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock").font(.system(size: 18, weight: .semibold))
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                    .font(.system(size: 28, weight: .bold)).monospacedDigit()
            }
            .foregroundStyle(state.live ? SolfegeTheme.ink : SolfegeTheme.muted.opacity(0.7))
            Text(state.caption).font(.system(size: 11)).foregroundStyle(SolfegeTheme.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(state.caption) \(seconds)초")
        .accessibilityIdentifier("writing-timer")
    }
}

// S12: confirmation shown directly above the submit button, without dimming the sheet.
private struct SubmitConfirmation: View {
    let exam: Bool
    let submit: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("이 답안으로 제출할까요?").font(.system(size: 18, weight: .bold)).foregroundStyle(SolfegeTheme.ink)
            Text(exam ? "제출하면 현재 필기를 고정해 AI 평가로 전송합니다.\n제출 후에는 답안을 수정할 수 없어요."
                      : "제출을 시작하면 현재 필기를 고정해 전송합니다.\n통신이 끊겨도 같은 답안으로 복구할 수 있어요.")
                .font(.system(size: 14)).foregroundStyle(SolfegeTheme.muted).fixedSize(horizontal: false, vertical: true)
            Button(action: submit) {
                Text("답안 제출").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(SolfegeTheme.violet, in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).padding(.top, 4).accessibilityIdentifier("confirm-submit")
            Button(action: cancel) {
                Text("계속 작성하기").font(.system(size: 15, weight: .bold)).foregroundStyle(SolfegeTheme.violet)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
        .frame(width: 352)
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
