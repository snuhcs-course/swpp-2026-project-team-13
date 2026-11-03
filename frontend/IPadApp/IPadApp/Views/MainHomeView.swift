import SwiftUI

// The landing screen. Four piano keys replace the old sidebar; history, settings and the profile sit in the top bar.
struct MainHomeView: View {
    @ObservedObject var model: AppModel
    @State private var showingProfile = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private struct Entry: Identifiable {
        let id, title, symbol, detail: String
        let screen: AppModel.Screen
        var needsServer = true
        var accent = false
    }
    private let entries = [
        Entry(id: "daily", title: "Daily Training", symbol: "sun.max", detail: "미니게임 세트와 청음 한 문제를 매일 연습해요", screen: .dailyTraining),
        Entry(id: "drill", title: "Drill", symbol: "pianokeys", detail: "미니게임을 골라 듣고 기억하는 연습을 해요", screen: .minigames, needsServer: false),
        Entry(id: "practice", title: "Practice", symbol: "pencil", detail: StudyMode.practice.detail, screen: .home),
        Entry(id: "exam", title: "Exam", symbol: "music.note.list", detail: StudyMode.exam.detail, screen: .examLibrary, accent: true),
    ]
    // Startup also has no connection yet, so only a finished attempt counts as offline.
    private var offline: Bool { !model.connected && !model.authenticating }
    private var locked: Bool { model.busy || model.authenticating }
    private var resumable: SessionRecord? { model.connected ? model.history.first(where: model.isUnfinished) : nil }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let keyboard = width >= 600 && !typeSize.isAccessibilitySize
            let margin: CGFloat = width >= 700 ? 40 : 20
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar.padding(.leading, margin).padding(.trailing, margin - 12).padding(.top, 8)
                    headline.padding(.horizontal, margin).padding(.top, 24).padding(.bottom, 30)
                    if keyboard { self.keyboard(large: width >= 1000).padding(.horizontal, margin).padding(.bottom, 24) }
                    else { keyList.padding(.horizontal, margin).padding(.bottom, 24) }
                }
                .frame(height: keyboard ? max(proxy.size.height, 620) : nil)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDisabled(keyboard && proxy.size.height >= 620)
        }
        .background(SORITheme.soft.ignoresSafeArea())
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            HStack(spacing: 8) { WaveMark(); Text("SORI").font(.system(size: 29, weight: .heavy, design: .rounded)).tracking(3).foregroundStyle(SORITheme.ink) }
                .accessibilityElement(children: .ignore).accessibilityLabel("SORI")
            Spacer(minLength: 8)
            if offline { statusChip("연결 안 됨", color: .orange) }
            else if model.demo && model.connected { statusChip("로컬 데모", color: SORITheme.green) }
            barButton("연습 기록", icon: "clock.arrow.circlepath", id: "home-history") { model.navigate(.history) }
            barButton("설정", icon: "slider.horizontal.3", id: "home-settings") { model.navigate(.settings) }
            if let profile = model.profile {
                Button { showingProfile = true } label: { Avatar(name: profile.displayName, size: 32, fill: .white).frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .buttonStyle(.plain).disabled(locked)
                    .accessibilityLabel("내 프로필").accessibilityIdentifier("home-profile")
                    .popover(isPresented: $showingProfile, arrowEdge: .top) { profilePanel(profile).presentationBackground(.white).presentationCompactAdaptation(.popover) }
            }
        }
    }
    private func statusChip(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(SORITheme.ink)
        }.padding(.horizontal, 12).frame(height: 32).background(.white, in: Capsule()).padding(.trailing, 8)
    }
    private func barButton(_ title: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 19)).foregroundStyle(SORITheme.softInk).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .buttonStyle(.plain).disabled(locked).accessibilityLabel(title).accessibilityIdentifier(id)
    }
    private func profilePanel(_ profile: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Avatar(name: profile.displayName, size: 56, fill: SORITheme.soft)
                VStack(alignment: .leading, spacing: 0) {
                    Text(profile.displayName).font(.system(size: 20, weight: .bold)).foregroundStyle(SORITheme.ink).lineLimit(2)
                    if let username = profile.username {
                        Text(username).font(.system(size: 14)).foregroundStyle(SORITheme.muted).lineLimit(1).truncationMode(.middle)
                            .accessibilityLabel("아이디 \(username)").accessibilityIdentifier("home-profile-username")
                    }
                }
            }
            HStack {
                Text("학습 목표").foregroundStyle(SORITheme.muted)
                Spacer()
                Text(SORITheme.goal(profile.learningGoal)).fontWeight(.bold).foregroundStyle(SORITheme.ink)
            }.font(.system(size: 14)).padding(.horizontal, 16).padding(.vertical, 12).background(SORITheme.background, in: RoundedRectangle(cornerRadius: 12))
            Button { showingProfile = false; model.navigate(.settings) } label: {
                Text("프로필과 계정 설정").font(.system(size: 15, weight: .bold)).foregroundStyle(SORITheme.deepViolet)
                    .frame(maxWidth: .infinity).frame(height: 48).background(SORITheme.soft, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityIdentifier("home-profile-settings")
        }.padding(20).frame(width: 320)
    }

    private var headline: some View {
        let greeting = VStack(alignment: .leading, spacing: 6) {
            Text(model.profile.map { "\($0.displayName)님, 안녕하세요" } ?? "안녕하세요").font(.system(size: 16, weight: .medium)).foregroundStyle(SORITheme.deepViolet).lineLimit(1)
            Text("오늘은 무엇을 해 볼까요?").font(.system(size: 34, weight: .bold)).foregroundStyle(SORITheme.ink).accessibilityAddTraits(.isHeader)
        }
        // Notices sit beside the greeting so the keys never move when one appears.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) { greeting; Spacer(minLength: 0); notice.fixedSize(horizontal: true, vertical: false) }
            VStack(alignment: .leading, spacing: 16) { greeting; notice }
        }
    }
    @ViewBuilder private var notice: some View {
        if offline {
            noticeCard(title: "학습 공간에 연결해 주세요", detail: "설정에서 로컬 데모를 시작하거나 서버를 연결할 수 있어요.", action: "연결 설정 열기", id: "home-open-settings") { model.navigate(.settings) }
        } else if let record = resumable {
            noticeCard(title: "\(record.attempt.studyMode.title) 이어서 하기", detail: record.attempt.question.title, action: "계속하기", id: "home-resume") { Task { await model.open(record) } }
        }
    }
    private func noticeCard(title: String, detail: String, action: String, id: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(SORITheme.ink).lineLimit(1)
                Text(detail).font(.system(size: 14)).foregroundStyle(SORITheme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: perform) {
                Text(action).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).padding(.horizontal, 20).frame(height: 44).background(SORITheme.violet, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).disabled(locked).accessibilityIdentifier(id)
        }.padding(.leading, 22).padding(.trailing, 15).padding(.vertical, 15).background(.white, in: RoundedRectangle(cornerRadius: 16))
    }

    private func keyboard(large: Bool) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(SORITheme.ink).frame(height: 8).accessibilityHidden(true)
            HStack(spacing: Self.keyGap) { ForEach(entries) { key($0, large: large, topRadius: 0) } }
                .overlay { BlackKeys(gap: Self.keyGap).allowsHitTesting(false).accessibilityHidden(true) }
        }
    }
    // Narrow windows and accessibility text sizes keep the same keys, stacked, so nothing is cut off.
    private var keyList: some View {
        VStack(spacing: 12) { ForEach(entries) { key($0, large: true, topRadius: 24).frame(minHeight: 132) } }
    }
    private static let keyGap: CGFloat = 6
    private func key(_ entry: Entry, large: Bool, topRadius: CGFloat) -> some View {
        let unavailable = entry.needsServer && offline
        let title: Color = unavailable ? SORITheme.softInk : entry.accent ? .white : SORITheme.ink
        let symbol: Color = unavailable ? SORITheme.softInk : entry.accent ? .white : SORITheme.violet
        let detail: Color = unavailable ? SORITheme.softInk : entry.accent ? .white : SORITheme.muted
        return Button { model.navigate(entry.screen) } label: {
            VStack(alignment: .leading, spacing: 12) {
                Spacer(minLength: 0)
                Image(systemName: entry.symbol).font(.system(size: large ? 30 : 26, weight: .light)).foregroundStyle(symbol)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title).font(.system(size: large ? 30 : 24, weight: .heavy, design: .rounded)).foregroundStyle(title).lineLimit(2).minimumScaleFactor(0.8)
                    Text(unavailable ? "연결 후 사용할 수 있어요" : !entry.needsServer && offline ? "Memory run은 연결 없이 할 수 있어요" : entry.detail)
                        .font(.system(size: large ? 15 : 14)).foregroundStyle(detail).fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, large ? 28 : 16).padding(.bottom, large ? 32 : 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PianoKeyStyle(accent: entry.accent, unavailable: unavailable, topRadius: topRadius))
        .disabled(unavailable || locked)
        .accessibilityIdentifier("home-key-\(entry.id)")
    }
}

private struct Avatar: View {
    let name: String; let size: CGFloat; let fill: Color
    var body: some View {
        Text(String(name.prefix(1))).font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(SORITheme.violet)
            .frame(width: size, height: size).background(fill, in: Circle()).accessibilityHidden(true)
    }
}

// Decoration only: the three black keys straddle the gaps between the four buttons.
private struct BlackKeys: View {
    let gap: CGFloat
    var body: some View {
        GeometryReader { proxy in
            let step = (proxy.size.width + gap) / 4
            ForEach(1..<4, id: \.self) { index in
                UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).fill(SORITheme.ink)
                    .overlay(alignment: .bottom) { Rectangle().fill(SORITheme.keyHighlight).frame(height: 10) }
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
                    .frame(width: proxy.size.width * 0.093, height: proxy.size.height * 0.49)
                    .position(x: step * CGFloat(index) - gap / 2, y: proxy.size.height * 0.245)
            }
        }
    }
}

private struct PianoKeyStyle: ButtonStyle {
    var accent: Bool; var unavailable: Bool; var topRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let sinks = pressed && !reduceMotion
        let fill: Color = unavailable ? SORITheme.keyUnavailable : accent ? (pressed ? SORITheme.deepViolet : SORITheme.violet) : (pressed ? SORITheme.keyPressed : .white)
        let edge: Color = unavailable ? .clear : accent ? SORITheme.deepViolet : SORITheme.keyEdge
        let shape = UnevenRoundedRectangle(topLeadingRadius: topRadius, bottomLeadingRadius: 24, bottomTrailingRadius: 24, topTrailingRadius: topRadius)
        return configuration.label
            .background { shape.fill(fill).shadow(color: edge, radius: 0, y: sinks ? 2 : 6) }
            .offset(y: sinks ? 4 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
    }
}
