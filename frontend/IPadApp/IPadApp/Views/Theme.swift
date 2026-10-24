import SwiftUI

enum SORITheme {
    static let ink = Color(red: 0.12, green: 0.14, blue: 0.21)
    static let violet = Color(red: 0.39, green: 0.31, blue: 0.85)
    static let background = Color(red: 0.97, green: 0.97, blue: 0.98)
    static let soft = Color(red: 0.93, green: 0.92, blue: 0.99)
    static let green = Color(red: 0.17, green: 0.46, blue: 0.36)
    static let goals: [(String, String)] = [("arts_school_entrance","예중·예고 입시"),("arts_school_student","예중·예고 재학생"),("college_entrance","음대 입시"),("teacher_exam","중등 음악 임용"),("other","기타")]
    static func goal(_ value: String) -> String { goals.first { $0.0 == value }?.1 ?? "지원하지 않는 목표" }
}
struct WaveMark: View {
    var body: some View {
        HStack(spacing: 3) { ForEach(Array([14.0,25,34,25,14].enumerated()), id: \.offset) { _, height in Capsule().fill(SORITheme.violet).frame(width: 4, height: height) } }.frame(width: 40, height: 40)
    }
}
struct PrimaryButton: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: compact ? 14 : 16, weight: .semibold))
            .padding(.horizontal, compact ? 16 : 24).padding(.vertical, compact ? 11 : 16)
            .foregroundStyle(.white).background(SORITheme.violet.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 12))
    }
}
struct Pill: View {
    let text: String; var icon: String? = nil
    var body: some View { HStack(spacing: 5) { if let icon { Image(systemName: icon) }; Text(text) }.font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 6).background(SORITheme.background, in: Capsule()) }
}
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(.black.opacity(0.04))) }
}
struct SectionCaption: View {
    let eyebrow: String; let title: String; var subtitle: String = ""
    var body: some View { VStack(alignment: .leading, spacing: 10) {
        Text(eyebrow).font(.caption.weight(.bold)).tracking(2).foregroundStyle(SORITheme.violet)
        Text(title).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(SORITheme.ink)
        if !subtitle.isEmpty { Text(subtitle).foregroundStyle(.secondary).font(.subheadline) }
    } }
}
struct DemoBadge: View {
    var body: some View { Label("예시 결과 · 실제 필기 채점 아님", systemImage: "sparkles").font(.caption.weight(.medium)).padding(10).foregroundStyle(SORITheme.violet).background(SORITheme.soft, in: RoundedRectangle(cornerRadius: 10)) }
}
