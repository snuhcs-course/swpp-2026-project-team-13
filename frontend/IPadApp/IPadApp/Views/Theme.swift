import SwiftUI

enum SolfegeTheme {
    static let ink = Color(red: 0.12, green: 0.14, blue: 0.21)
    static let violet = Color(red: 0.39, green: 0.31, blue: 0.85)
    static let background = Color(red: 0.97, green: 0.97, blue: 0.98)
    static let soft = Color(red: 0.93, green: 0.92, blue: 0.99)
    static let deepViolet = Color(red: 0.31, green: 0.24, blue: 0.76)
    static let keyEdge = Color(red: 0.84, green: 0.82, blue: 0.97)
    static let keyPressed = Color(red: 0.95, green: 0.95, blue: 1.0)
    static let keyUnavailable = Color(red: 0.87, green: 0.85, blue: 0.96)
    static let keyHighlight = Color(red: 0.23, green: 0.25, blue: 0.35)
    static let green = Color(red: 0.17, green: 0.46, blue: 0.36)
    static let muted = Color(red: 0.37, green: 0.38, blue: 0.46)
    static let softInk = Color(red: 0.29, green: 0.27, blue: 0.44)
    static let field = Color(red: 0.96, green: 0.96, blue: 0.97)
    static let danger = Color(red: 0.75, green: 0.20, blue: 0.12)
    static let disabledFill = Color(red: 0.89, green: 0.88, blue: 0.96)
    static let disabledText = Color(red: 0.44, green: 0.42, blue: 0.57)
}
struct WaveMark: View {
    var body: some View {
        HStack(spacing: 3) { ForEach(Array([14.0,25,34,25,14].enumerated()), id: \.offset) { _, height in Capsule().fill(SolfegeTheme.violet).frame(width: 4, height: height) } }.frame(width: 40, height: 40)
    }
}
struct PrimaryButton: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: compact ? 14 : 16, weight: .semibold))
            .padding(.horizontal, compact ? 16 : 24).padding(.vertical, compact ? 11 : 16)
            .foregroundStyle(.white).background(SolfegeTheme.violet.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 12))
    }
}
// Shared by answer submission and Practice completion, anchored above the action.
struct AnswerConfirmation: View {
    let title: String
    let message: String
    let confirmTitle: String
    let cancelTitle: String
    let confirmIdentifier: String
    let confirm: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(title).font(.system(size:18,weight:.bold)).foregroundStyle(SolfegeTheme.ink)
            Text(message).font(.system(size:14)).foregroundStyle(SolfegeTheme.muted)
                .fixedSize(horizontal:false,vertical:true)
            Button(action:confirm) {
                Text(confirmTitle).font(.system(size:15,weight:.bold)).foregroundStyle(.white)
                    .frame(maxWidth:.infinity).padding(.vertical,12)
                    .background(SolfegeTheme.violet,in:RoundedRectangle(cornerRadius:10))
            }.buttonStyle(.plain).padding(.top,4).accessibilityIdentifier(confirmIdentifier)
            Button(action:cancel) {
                Text(cancelTitle).font(.system(size:15,weight:.bold)).foregroundStyle(SolfegeTheme.violet)
                    .frame(maxWidth:.infinity).padding(.vertical,6)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal,24).padding(.top,22).padding(.bottom,14)
        .frame(width:352)
    }
}
struct Pill: View {
    let text: String; var icon: String? = nil
    var body: some View { HStack(spacing: 5) { if let icon { Image(systemName: icon) }; Text(text) }.font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 6).background(SolfegeTheme.background, in: Capsule()) }
}
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(.black.opacity(0.04))) }
}
struct SectionCaption: View {
    let eyebrow: String; let title: String; var subtitle: String = ""
    var body: some View { VStack(alignment: .leading, spacing: 10) {
        Text(eyebrow).font(.caption.weight(.bold)).tracking(2).foregroundStyle(SolfegeTheme.violet)
        Text(title).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(SolfegeTheme.ink)
        if !subtitle.isEmpty { Text(subtitle).foregroundStyle(.secondary).font(.subheadline) }
    } }
}
struct DemoBadge: View {
    var body: some View { Label("예시 결과 · 실제 필기 채점 아님", systemImage: "sparkles").font(.caption.weight(.medium)).padding(10).foregroundStyle(SolfegeTheme.violet).background(SolfegeTheme.soft, in: RoundedRectangle(cornerRadius: 10)) }
}
