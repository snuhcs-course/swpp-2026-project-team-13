import SwiftUI

// S24: today's four items. Each item opens its own screens; the set only tracks what is done.
struct DailyTrainingView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    // Rows for Rhythm puzzle and Practice close and reopen as the network comes and goes.
    @ObservedObject private var network = NetworkStatus.shared

    private var plan: DailyPlan? { model.daily.plan }
    private var nextOpen: Int? { plan?.firstOpen(available: model.dailyAvailable) }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 900 && !typeSize.isAccessibilitySize
            ScrollView {
                Group {
                    if wide {
                        HStack(alignment: .top, spacing: 40) {
                            hero(ring: 220).frame(width: 380).frame(minHeight: max(560, proxy.size.height - 64))
                            itemList.frame(maxWidth: .infinity).frame(minHeight: max(560, proxy.size.height - 64))
                        }
                    } else {
                        VStack(spacing: 24) { hero(ring: 160); itemList }
                    }
                }
                .padding(.horizontal, wide ? 32 : 20).padding(.top, 8).padding(.bottom, 32)
                .frame(maxWidth: 1180).frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(SolfegeTheme.background.ignoresSafeArea())
        .task {
            model.refreshDailyPlan()
            // A minigame that follows a Practice item opens once this screen is up.
            if let pending = model.daily.pendingGame {
                try? await Task.sleep(for: .milliseconds(350))
                guard model.daily.pendingGame == pending else { return }
                model.daily.pendingGame = nil; model.daily.presentedGame = pending
            }
        }
        .fullScreenCover(item: $model.daily.presentedGame) { item in game(item) }
    }

    private func hero(ring: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(Date.now, format: .dateTime.month(.wide).day().weekday(.wide)).font(.system(size: 15)).opacity(0.9)
                Spacer(minLength: 8)
                if let plan, plan.hasStarted, !plan.isComplete {
                    Text("진행 중").font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 4).background(.white.opacity(0.2), in: Capsule())
                        .accessibilityIdentifier("daily-in-progress")
                }
            }
            Text("오늘의 트레이닝").font(.system(size: 34, weight: .bold)).padding(.top, 6).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 24)
            DailyRing(done: plan?.items.map(\.completed) ?? [], size: ring).frame(maxWidth: .infinity)
            Spacer(minLength: 24)
            cta
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 36).padding(.top, 40).padding(.bottom, 36)
        .background(SolfegeTheme.violet, in: RoundedRectangle(cornerRadius: 28))
    }
    @ViewBuilder private var cta: some View {
        if let plan, plan.isComplete {
            VStack(alignment: .leading, spacing: 4) {
                Label("오늘 완료", systemImage: "checkmark.circle.fill").font(.system(size: 20, weight: .bold))
                Text("내일 새 세트가 열려요").font(.system(size: 15)).opacity(0.85)
            }.frame(maxWidth: .infinity, minHeight: 60, alignment: .leading).accessibilityElement(children: .combine)
        } else {
            Button { if let nextOpen { model.startDailyItem(nextOpen) } } label: {
                Label(plan?.hasStarted == true ? "이어서 하기" : "시작하기", systemImage: "play.fill")
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(SolfegeTheme.violet)
                    .frame(maxWidth: .infinity).frame(height: 60).background(.white, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain).disabled(nextOpen == nil || model.busy).opacity(nextOpen == nil ? 0.6 : 1)
            .accessibilityIdentifier("daily-start")
        }
    }

    @ViewBuilder private var itemList: some View {
        if let plan, !plan.items.isEmpty {
            VStack(spacing: 12) {
                ForEach(plan.items) { item in
                    // A little more room where minigames end and Practice begins.
                    if item.id > 0, plan.items[item.id - 1].kind.isMinigame != item.kind.isMinigame { Spacer().frame(height: 16) }
                    row(item)
                }
                if !plan.items.contains(where: { $0.kind == .practice }) {
                    Text("풀 수 있는 Practice 문제가 없어 오늘은 미니게임만 있어요.").font(.subheadline).foregroundStyle(SolfegeTheme.muted).padding(.top, 8)
                }
            }.frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("오늘의 세트를 준비하고 있어요").foregroundStyle(SolfegeTheme.muted)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func row(_ item: DailyItem) -> some View {
        let available = model.dailyAvailable(item)
        let isNext = item.id == nextOpen
        return Button { model.startDailyItem(item.id) } label: {
            HStack(spacing: 20) {
                badge(item, isNext: isNext)
                Text(item.title).font(.system(size: 22, weight: .bold)).foregroundStyle(available || item.completed ? SolfegeTheme.ink : SolfegeTheme.disabledText)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 12)
                Text(item.completed ? "완료" : available ? item.kind.typeLabel : "연결 후 풀 수 있어요")
                    .font(.system(size: 13, weight: item.completed ? .bold : .regular))
                    .foregroundStyle(item.completed ? SolfegeTheme.green : available ? SolfegeTheme.muted : SolfegeTheme.disabledText)
            }
            .padding(.horizontal, 28).frame(maxWidth: .infinity).frame(height: 96)
            .background(available || item.completed ? Color.white : SolfegeTheme.disabledFill, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20).strokeBorder(isNext ? SolfegeTheme.violet : Color(red: 0.91, green: 0.90, blue: 0.96), lineWidth: isNext ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain).disabled(item.completed || !available || model.busy)
        .accessibilityLabel("\(item.id + 1)번, \(item.title), \(item.kind.typeLabel)")
        .accessibilityValue(item.completed ? "완료" : available ? "" : "연결 후 풀 수 있어요")
        .accessibilityIdentifier("daily-item-\(item.id)")
    }
    @ViewBuilder private func badge(_ item: DailyItem, isNext: Bool) -> some View {
        if item.completed {
            Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                .frame(width: 36, height: 36).background(SolfegeTheme.green, in: Circle())
        } else if isNext {
            Text("\(item.id + 1)").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                .frame(width: 36, height: 36).background(SolfegeTheme.violet, in: Circle())
        } else {
            Text("\(item.id + 1)").font(.system(size: 15, weight: .bold)).foregroundStyle(SolfegeTheme.muted)
                .frame(width: 36, height: 36).overlay(Circle().strokeBorder(SolfegeTheme.keyEdge, lineWidth: 1.5))
        }
    }

    @ViewBuilder private func game(_ item: DailyItem) -> some View {
        let context = DailyGameContext(
            difficulty: model.dailyPracticeLevel.minigameDifficulty,
            done: model.daily.plan?.items.map(\.completed) ?? [],
            index: item.id,
            nextTitle: model.dailyNextTitle(after: item.id),
            finished: { model.completeDailyItem(item.id) },
            next: { model.advanceDaily() },
            exit: { model.exitDailyItem() })
        switch item.kind {
        case .memoryRun: MelodyRunView(connection: model.rhythmConnection, daily: context)
        case .rhythmPuzzle: RhythmPuzzleView(connection: model.rhythmConnection, daily: context)
        case .practice: EmptyView()
        }
    }
}

// What a minigame needs to run as one Daily Training item.
struct DailyGameContext {
    let difficulty: MemoryDifficulty
    let done: [Bool]
    let index: Int
    // nil when nothing is left to open, so the button finishes the set.
    let nextTitle: String?
    let finished: () -> Void
    let next: () -> Void
    let exit: () -> Void
    var buttonTitle: String { nextTitle == nil ? "완료" : "다음 항목" }
}

// The button at the end of every item: "다음 항목 · <name>" or "완료".
struct DailyNextButton: View {
    let nextTitle: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(nextTitle == nil ? "완료" : "다음 항목").font(.system(size: 17, weight: .bold))
                if let nextTitle { Text(nextTitle).font(.system(size: 15)).opacity(0.85).lineLimit(1) }
            }
        }
        .buttonStyle(PrimaryButton(compact: true)).accessibilityIdentifier("daily-next")
    }
}

// Marks a minigame or Practice screen as part of today's set.
struct DailyChip: View {
    var body: some View {
        Text("오늘의 트레이닝").font(.system(size: 13, weight: .bold)).foregroundStyle(SolfegeTheme.violet)
            .padding(.horizontal, 10).padding(.vertical, 4).background(SolfegeTheme.soft, in: Capsule())
    }
}

// One segment per item, filled as each is finished; the number is the item being played.
struct DailyProgressBar: View {
    let done: [Bool]
    let current: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(done.indices, id: \.self) { i in Capsule().fill(done[i] ? SolfegeTheme.violet : SolfegeTheme.violet.opacity(0.13)).frame(height: 6) }
            Text("\(current + 1)/\(done.count)").font(.caption.monospacedDigit()).padding(.leading, 8)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("오늘의 트레이닝 \(done.count)개 중 \(current + 1)번째, \(done.filter { $0 }.count)개 완료")
    }
}

struct DailyRing: View {
    let done: [Bool]
    let size: CGFloat
    var body: some View {
        let count = max(done.count, 1)
        let gap = 5.0 / 360
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .trim(from: Double(i) / Double(count) + gap / 2, to: Double(i + 1) / Double(count) - gap / 2)
                    .stroke(.white.opacity(done.indices.contains(i) && done[i] ? 1 : 0.25), lineWidth: size * 0.064)
                    .rotationEffect(.degrees(-90))
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(done.filter { $0 }.count)").font(.system(size: size * 0.29, weight: .heavy))
                Text("/ \(done.count)").font(.system(size: size * 0.12, weight: .bold)).opacity(0.85)
            }
        }
        .padding(size * 0.032).frame(width: size, height: size)
        .animation(.easeOut(duration: 0.4), value: done)
        .accessibilityElement(children: .ignore).accessibilityLabel("\(done.count)개 중 \(done.filter { $0 }.count)개 완료")
    }
}
