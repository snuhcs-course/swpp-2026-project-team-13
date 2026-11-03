import SwiftUI

// Shown between the Exam key and the exam's instructions while the server picks the question.
struct ExamRecommendationView: View {
    var body: some View {
        VStack(spacing:20) {
            WaveMark()
            ProgressView().controlSize(.large)
            VStack(spacing:8) {
                Text("적절한 문제를 고르는 중이에요").font(.system(size:28,weight:.bold)).foregroundStyle(SolfegeTheme.ink).accessibilityAddTraits(.isHeader)
                Text("잠시만 기다려 주세요").font(.system(size:16)).foregroundStyle(SolfegeTheme.muted)
            }.multilineTextAlignment(.center)
        }.padding(32).frame(maxWidth:.infinity,maxHeight:.infinity).accessibilityIdentifier("exam-recommendation-loading")
    }
}
