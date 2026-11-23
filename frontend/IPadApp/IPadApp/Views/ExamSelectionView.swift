import SwiftUI

// S15 loading remains separate. S15a is the approved horizontal raised-card view.
struct ExamSelectionView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing:0) {
                HStack {
                    Button { model.navigate(.main) } label: {
                        HStack(spacing:6) { Image(systemName:"chevron.left"); Text("홈") }
                    }.frame(width:88,alignment:.leading).accessibilityIdentifier("exam-selection-home")
                    Spacer(); Text("Exam").font(.system(size:22,weight:.bold)).foregroundStyle(SolfegeTheme.ink); Spacer()
                    Color.clear.frame(width:88,height:44).accessibilityHidden(true)
                }.foregroundStyle(SolfegeTheme.violet).padding(.horizontal,28).frame(height:58)
                VStack(alignment:.leading,spacing:0) {
                    HStack(spacing:14) {
                        Text("나의 레이팅").font(.system(size:15,weight:.medium)).foregroundStyle(SolfegeTheme.muted)
                        Text(String(format:"%.1f",model.examOffer?.rating.value ?? 7))
                            .font(.system(size:36,weight:.bold)).monospacedDigit().foregroundStyle(SolfegeTheme.ink)
                            .accessibilityIdentifier("exam-current-rating")
                    }.frame(height:58)
                    Spacer().frame(height:34)
                    if let offer = model.examOffer {
                        HStack(spacing:24) {
                            ForEach(offer.choices) { choice in
                                Button { Task { await model.chooseExam(choice) } } label: {
                                    ExamChoiceCard(choice:choice)
                                }.buttonStyle(ExamRaisedCardStyle())
                                    .disabled(choice.questionId == nil || model.busy)
                                    .accessibilityIdentifier("exam-choice-"+choice.category)
                            }
                        }.frame(height:min(388,max(220,geometry.size.height-280)))
                    } else {
                        Button("다시 추천받기") { Task { await model.startRecommendedExam() } }
                            .buttonStyle(PrimaryButton()).frame(maxWidth:.infinity,maxHeight:.infinity)
                    }
                    Spacer(minLength:24)
                    VStack(alignment:.leading,spacing:6) {
                        Text("어려운 문제일수록 유리한 레이팅 보정이 적용됩니다.")
                        Text("선택한 문제는 변경할 수 없습니다.")
                    }.font(.system(size:13)).foregroundStyle(SolfegeTheme.muted)
                }.padding(.horizontal,40).padding(.top,40).padding(.bottom,42)
            }.background(.white).foregroundStyle(SolfegeTheme.ink)
        }
        .accessibilityIdentifier("exam-selection")
    }
}

private struct ExamChoiceCard: View {
    let choice: ExamChoice
    var body: some View {
        VStack(spacing:32) {
            Text(choice.title).font(.system(size:24,weight:.bold))
            if let score = choice.difficultyScore {
                VStack(spacing:17) {
                    Text(String(format:"%.1f",score)).font(.system(size:84,weight:.bold)).tracking(-2.5)
                        .monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                    VStack(spacing:3) {
                        Text("내 레이팅 대비").font(.system(size:12))
                        Text(deltaLabel).font(.system(size:22,weight:.medium)).monospacedDigit()
                    }
                }
            } else {
                Text("아직 풀지 않은\n문제가 없어요").font(.system(size:20)).multilineTextAlignment(.center)
            }
        }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity)
            .foregroundStyle(.white)
            .overlay(alignment:.bottomTrailing) {
                if choice.questionId != nil {
                    Image(systemName:"chevron.right").font(.system(size:24,weight:.medium)).padding(25).accessibilityHidden(true)
                }
            }
    }
    private var deltaLabel: String {
        let delta = choice.ratingDifference ?? 0
        return abs(delta) < 0.05 ? "0.0" : String(format:"%+.1f",delta).replacingOccurrences(of:"-",with:"−")
    }
}

private struct ExamRaisedCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(SolfegeTheme.violet,in:RoundedRectangle(cornerRadius:28))
            .padding(.bottom,configuration.isPressed ? 1 : 6)
            .background(SolfegeTheme.deepViolet,in:RoundedRectangle(cornerRadius:28))
            .offset(y:configuration.isPressed ? 5 : 0)
    }
}
