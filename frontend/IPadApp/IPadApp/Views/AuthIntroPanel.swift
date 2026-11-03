import SwiftUI
import Combine

// The looping "listen, write, compare" demo beside the signup and login forms.
struct AuthIntroPanel: View {
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage = 0
    @State private var beat = 0
    @State private var tick = 3
    @State private var paused = false
    private let timer = Timer.publish(every: 0.24, on: .main, in: .common).autoconnect()
    private let steps = ["듣기", "적기", "비교"]
    private let captions = ["먼저 소리를 듣고", "Apple Pencil로 오선에 적고", "정답과 마디별로 비교해요"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) { WaveMark(); Text("SORI").font(.system(size: 29, weight: .heavy, design: .rounded)).tracking(3).foregroundStyle(SORITheme.ink) }
                Text("소리에서 시작하는 음악 공부").font(.system(size: 14)).foregroundStyle(SORITheme.softInk)
            }.padding(.horizontal, 36)
            Spacer(minLength: compact ? 8 : 24)
            VStack(alignment: .leading, spacing: compact ? 8 : 28) {
                Text(captions[stage]).font(.system(size: compact ? 22 : 28, weight: .bold)).foregroundStyle(SORITheme.ink).padding(.horizontal, 36)
                    .accessibilityAddTraits(.isHeader)
                AuthStaffDemo(stage: stage, beat: beat, tick: tick).frame(maxWidth: compact ? 540 : .infinity)
            }
            Spacer(minLength: compact ? 8 : 24)
            HStack {
                HStack(spacing: 4) {
                    ForEach(steps.indices, id: \.self) { index in
                        Button { withAnimation(.easeInOut(duration: 0.28)) { stage = index; beat = 99; paused = true } } label: {
                            Text(steps[index]).font(.system(size: 15, weight: .medium)).padding(.horizontal, 18).frame(minHeight: 44)
                                .foregroundStyle(stage == index ? Color.white : SORITheme.softInk)
                                .background(stage == index ? SORITheme.violet : .clear, in: Capsule())
                        }.buttonStyle(.plain).accessibilityAddTraits(stage == index ? .isSelected : [])
                    }
                }
                Spacer()
                Button { paused.toggle() } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 17)).frame(width: 44, height: 44).foregroundStyle(SORITheme.softInk)
                }.buttonStyle(.plain).accessibilityLabel(paused ? "데모 재생" : "데모 멈추기")
            }.padding(.horizontal, 36)
        }
        .padding(.vertical, compact ? 16 : 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SORITheme.soft.ignoresSafeArea())
        .onAppear { if reduceMotion { paused = true; beat = 99 } }
        .onReceive(timer) { _ in
            guard !paused else { return }
            tick += 1; beat += 1
            if beat >= 15 { withAnimation(.easeInOut(duration: 0.28)) { stage = (stage + 1) % 3; beat = 0 } }
        }
    }
}

private struct DemoNote: Identifiable {
    let id: Int; let x: CGFloat; let y: CGFloat; let stemUp: Bool; var hollow = false; var measure = 1
}

// Coordinates are on a 540-wide staff whose lines sit at y = 0, 14, 28, 42, 56 below the top margin.
private struct AuthStaffDemo: View {
    let stage: Int; let beat: Int; let tick: Int
    private let top: CGFloat = 30
    private let notes = [
        DemoNote(id: 0, x: 136, y: 42, stemUp: true), DemoNote(id: 1, x: 184, y: 35, stemUp: true),
        DemoNote(id: 2, x: 232, y: 28, stemUp: false), DemoNote(id: 3, x: 280, y: 42, stemUp: true),
        DemoNote(id: 4, x: 350, y: 21, stemUp: false, measure: 2), DemoNote(id: 5, x: 404, y: 35, stemUp: true, measure: 2),
        DemoNote(id: 6, x: 456, y: 42, stemUp: true, hollow: true, measure: 2),
    ]
    private static let wrongNote = 5
    private let correct = Color(red: 0.14, green: 0.38, blue: 0.29)
    private let wrong = Color(red: 0.66, green: 0.29, blue: 0.02)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                let scale = proxy.size.width / 540
                ZStack(alignment: .topLeading) {
                    bands(scale)
                    staff(scale)
                    ForEach(notes) { note in
                        NoteShape(note: note, top: top)
                            .fill(color(note), style: FillStyle(eoFill: note.hollow))
                            .opacity(opacity(note))
                            .animation(.easeIn(duration: 0.24), value: opacity(note))
                    }
                    NoteShape(note: DemoNote(id: 7, x: 404, y: 28, stemUp: true), top: top, stem: false)
                        .stroke(wrong, style: StrokeStyle(lineWidth: 1.5 * scale, dash: [2.5 * scale, 2 * scale]))
                        .opacity(stage == 2 ? 1 : 0)
                    waves(scale)
                }
            }
            .aspectRatio(540.0 / 120.0, contentMode: .fit)
            .accessibilityElement().accessibilityLabel("오선보 위의 두 마디 선율 예시")
            GeometryReader { proxy in
                let scale = proxy.size.width / 540
                HStack(spacing: 6 * scale) {
                    Label("맞았어요", systemImage: "checkmark").foregroundStyle(correct).frame(width: 205 * scale)
                    Text("한 음 다시 들어봐요").foregroundStyle(wrong).frame(width: 186 * scale)
                }.font(.system(size: 13, weight: .medium)).padding(.leading, 112 * scale)
            }.frame(height: 20).opacity(stage == 2 ? 1 : 0)
        }
    }
    private func opacity(_ note: DemoNote) -> Double {
        switch stage { case 0: 0; case 1: beat > note.id ? 1 : 0; default: 1 }
    }
    private func color(_ note: DemoNote) -> Color {
        guard stage == 2 else { return SORITheme.ink }
        if note.id == Self.wrongNote { return wrong }
        return note.measure == 1 ? correct : SORITheme.ink
    }
    private func bands(_ scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8 * scale).fill(correct.opacity(0.1)).frame(width: 205 * scale, height: 88 * scale).offset(x: 112 * scale, y: 14 * scale)
            RoundedRectangle(cornerRadius: 8 * scale).fill(wrong.opacity(0.1)).frame(width: 186 * scale, height: 88 * scale).offset(x: 323 * scale, y: 14 * scale)
        }.opacity(stage == 2 ? 1 : 0)
    }
    private func staff(_ scale: CGFloat) -> some View {
        Canvas { context, _ in
            let ink = SORITheme.ink
            func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
                var path = Path(); path.move(to: CGPoint(x: x1 * scale, y: (top + y1) * scale)); path.addLine(to: CGPoint(x: x2 * scale, y: (top + y2) * scale))
                context.stroke(path, with: .color(ink.opacity(0.38)), lineWidth: 1)
            }
            for index in 0..<5 { line(28, CGFloat(index) * 14, 512, CGFloat(index) * 14) }
            line(320, 0, 320, 56); line(512, 0, 512, 56)
            // Same proportions as NativeScoreRenderer's clef, scaled from its 12pt line gap to 14pt.
            context.draw(Text("𝄞").font(.system(size: 87.5 * scale)).foregroundColor(ink), at: CGPoint(x: 58 * scale, y: (top + 26.8) * scale))
            for y: CGFloat in [14, 42] {
                context.draw(Text("4").font(.system(size: 30 * scale, weight: .bold, design: .serif)).foregroundColor(ink), at: CGPoint(x: 94 * scale, y: (top + y) * scale))
            }
        }
    }
    private func waves(_ scale: CGFloat) -> some View {
        HStack(alignment: .center) {
            ForEach(0..<21, id: \.self) { index in
                let wave = abs(sin(Double(tick) * 0.8 + Double(index) * 0.62))
                let envelope = 0.45 + 0.55 * sin(Double(index + 1) / 22 * .pi)
                Capsule().fill(SORITheme.violet).frame(width: 6 * scale, height: (10 + 78 * wave * envelope) * scale)
                if index < 20 { Spacer(minLength: 0) }
            }
        }
        .animation(.linear(duration: 0.24), value: tick)
        .frame(width: 386 * scale, height: 120 * scale)
        .offset(x: 118 * scale)
        .opacity(stage == 0 ? 1 : 0)
    }
}

private struct NoteShape: Shape {
    let note: DemoNote; let top: CGFloat; var stem = true
    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 540
        let center = CGPoint(x: note.x * scale, y: (top + note.y) * scale)
        let tilt = CGAffineTransform(rotationAngle: -.pi / 9).concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        func head(_ rx: CGFloat, _ ry: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: -rx * scale, y: -ry * scale, width: 2 * rx * scale, height: 2 * ry * scale)).applying(tilt)
        }
        var path = head(7.6, 5.4)
        if note.hollow { path.addPath(head(5.4, 2.9)) }
        if stem {
            let x = note.stemUp ? center.x + 7 * scale : center.x - 8.6 * scale
            let y = note.stemUp ? center.y - 37 * scale : center.y + 1 * scale
            path.addRect(CGRect(x: x, y: y, width: 1.6 * scale, height: 36 * scale))
        }
        return path
    }
}
