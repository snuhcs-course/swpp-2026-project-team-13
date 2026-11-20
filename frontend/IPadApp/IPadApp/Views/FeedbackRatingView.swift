import SwiftUI

/// Kept out of the result layout until the server enables it for a completed job.
struct FeedbackRatingButton: View {
    @ObservedObject var model: AppModel
    let grading: Grading
    @State private var showing = false

    var body: some View {
        if grading.status == "completed", grading.feedbackRating?.enabled == true,
           let feedbackId = grading.feedbackRating?.feedbackId {
            Button { showing = true } label: {
                Label(grading.feedbackRating?.rating.map { "별점 \($0.stars)점 · 수정" } ?? "AI 피드백 평가",systemImage:grading.feedbackRating?.rating == nil ? "star" : "star.fill")
                    .font(.subheadline)
            }
            .accessibilityIdentifier("ai-feedback-rating")
            .sheet(isPresented:$showing) {
                FeedbackRatingForm(model:model,jobId:grading.jobId,feedbackId:feedbackId,previous:grading.feedbackRating?.rating)
            }
        }
    }
}

private struct FeedbackRatingForm: View {
    @ObservedObject var model: AppModel
    let jobId: UUID
    let feedbackId: String
    @Environment(\.dismiss) private var dismiss
    @State private var stars: Int
    @State private var reason: String
    @State private var saving = false
    @State private var error: String?

    init(model: AppModel, jobId: UUID, feedbackId: String, previous: FeedbackRatingEntry?) {
        self.model = model; self.jobId = jobId; self.feedbackId = feedbackId
        _stars = State(initialValue:previous?.stars ?? 0)
        _reason = State(initialValue:previous?.reason ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing:12) {
                        ForEach(1...5,id:\.self) { value in
                            Button { stars = value } label: {
                                Image(systemName:value <= stars ? "star.fill" : "star")
                                    .font(.system(size:30)).foregroundStyle(SolfegeTheme.violet)
                                    .frame(minWidth:44,minHeight:48)
                            }.buttonStyle(.plain).accessibilityLabel("\(value)점")
                                .accessibilityAddTraits(value == stars ? .isSelected : [])
                                .accessibilityIdentifier("feedback-stars-\(value)")
                        }
                    }.frame(maxWidth:.infinity)
                } header: { Text("AI 채점과 피드백이 도움이 되었나요?") }
                Section("이유를 남겨주세요 (선택)") {
                    TextEditor(text:$reason).frame(minHeight:120)
                        .accessibilityLabel("평가 이유").accessibilityIdentifier("feedback-reason")
                        .onChange(of:reason) { _,value in
                            var clipped = value
                            while clipped.unicodeScalars.count > 500 { clipped.removeLast() }
                            if clipped != value { reason = clipped }
                        }
                    Text("\(reason.unicodeScalars.count) / 500").font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.trailing)
                }
                if let error { Text(error).foregroundStyle(SolfegeTheme.danger).accessibilityIdentifier("feedback-rating-error") }
                Button {
                    saving = true; error = nil
                    Task {
                        do {
                            _ = try await model.saveFeedbackRating(jobId:jobId,feedbackId:feedbackId,stars:stars,reason:reason)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                        saving = false
                    }
                } label: {
                    HStack { Spacer(); if saving { ProgressView() }; Text(saving ? "저장 중" : "평가 남기기"); Spacer() }
                }.disabled(saving || stars == 0).accessibilityIdentifier("save-feedback-rating")
            }
            .navigationTitle("AI 피드백 평가").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("닫기") { dismiss() }.disabled(saving) } }
            .interactiveDismissDisabled(saving)
        }.presentationDetents([.medium,.large])
    }
}
