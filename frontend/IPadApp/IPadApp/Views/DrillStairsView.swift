import SwiftUI

// S20 Drill: the keyboard staircase (Figma "건반 계단 · E2안"). Tapping an open key starts that
// stage's minigame at once; finishing the current key lights the next one.
//
// Front-end rules decided on top of E2:
// • Narrow screens (portrait, iPad mini) squeeze the wave sideways; keys keep their 460×72 size.
// • Any key can be played in any order. A solved key stays pressed; the lowest unsolved key is purple.
// • A Rhythm puzzle key without a server shows a wifi.slash mark and says why it cannot start.
// • All feedback is one toast at the top, never a modal alert (alerts are kept for storage errors).
// • Clearing a key gives a success haptic; Reduce Motion drops the shake, spring and scroll animation.
struct DrillStairsView: View {
    let connection: RhythmConnection?
    let back: () -> Void
    @StateObject private var stairs: DrillStairsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playing: DrillStage?
    @State private var toast: String?
    @State private var shakes: [Int:Int] = [:]
    @State private var refusals = 0

    init(connection: RhythmConnection?, back: @escaping () -> Void) {
        self.connection = connection; self.back = back
        _stairs = StateObject(wrappedValue:DrillStairsModel(connection:connection))
    }

    private static let topPadding = 96.0
    // Where the current key sits when the stairs open (share of the screen height from the top).
    private static let currentAnchor = 0.62

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical,showsIndicators:false) {
                    stairsContent(width:geometry.size.width)
                        .padding(.top,Self.topPadding)
                        .padding(.bottom,max(DrillStairs.rowStep,geometry.size.height*(1-Self.currentAnchor)))
                }
                .onAppear { scroll(proxy,animated:false) }
                .onChange(of:geometry.size) { _, _ in scroll(proxy,animated:false) }
                .fullScreenCover(item:$playing,onDismiss:{ climbed(proxy) }) { stage in game(stage) }
            }
            .overlay(alignment:.top) {
                LinearGradient(colors:[DrillPalette.background,DrillPalette.background.opacity(0)],startPoint:.top,endPoint:.bottom)
                    .frame(height:72).allowsHitTesting(false)
            }
            .overlay(alignment:.bottom) {
                LinearGradient(colors:[DrillPalette.background.opacity(0),DrillPalette.background],startPoint:.top,endPoint:.bottom)
                    .frame(height:40).allowsHitTesting(false)
            }
            .overlay(alignment:.topLeading) {
                Button(action:back) {
                    BackChevron().stroke(DrillPalette.deep,style:StrokeStyle(lineWidth:2,lineCap:.round,lineJoin:.round))
                        .frame(width:20,height:20).frame(width:44,height:44).background(.white,in:Circle())
                }.buttonStyle(.plain).padding(.leading,24).padding(.top,20)
                    .accessibilityLabel("홈으로").accessibilityIdentifier("drill-back")
            }
            .overlay(alignment:.top) {
                if let toast {
                    Text(toast).font(.system(size:17,weight:.bold)).foregroundStyle(.white).multilineTextAlignment(.center)
                        .padding(.horizontal,22).padding(.vertical,12).background(SolfegeTheme.ink,in:Capsule())
                        .padding(.top,24).padding(.horizontal,84)
                        .transition(reduceMotion ? .opacity : .move(edge:.top).combined(with:.opacity))
                        .accessibilityIdentifier("drill-toast").accessibilityAddTraits(.isStaticText)
                }
            }
        }
        .background(DrillPalette.background.ignoresSafeArea())
        .preferredColorScheme(.light)
        .sensoryFeedback(.success,trigger:stairs.shown.cleared.count)
        .sensoryFeedback(.impact(weight:.light),trigger:refusals)
        .alert("확인이 필요해요",isPresented:Binding(get:{ stairs.error != nil },set:{ if !$0 { stairs.error = nil } })) {
            Button("확인") { stairs.error = nil }
        } message: { Text(stairs.error ?? "") }
    }

    // White keys top (D5) to bottom (C1), one 74pt row each; black keys float over the seams.
    private func stairsContent(width: CGFloat) -> some View {
        let spread = DrillStairs.spread(width:width)
        return VStack(spacing:0) {
            ForEach(DrillStairs.stages.reversed()) { stage in
                StageKey(stage:stage,state:stairs.state(stage),offline:stairs.needsConnection(stage),action:{ open(stage) })
                    .frame(width:DrillStairs.keySize.width,height:DrillStairs.keySize.height)
                    .modifier(Shake(phase:CGFloat(shakes[stage.number] ?? 0)))
                    .offset(x:DrillStairs.centerOffset(stage.number)*spread)
                    .frame(maxWidth:.infinity,alignment:.center)
                    .frame(height:DrillStairs.rowStep,alignment:.top)
                    .id(stage.number)
            }
        }
        .frame(width:width)
        .overlay(alignment:.topLeading) {
            ZStack(alignment:.topLeading) {
                ForEach(1..<DrillStairs.count,id:\.self) { number in
                    if DrillStairs.hasBlackKey(above:number) {
                        let row = Double(DrillStairs.count-1-number)
                        BlackKey(pressed:stairs.shown.blackKeyPressed(above:number))
                            .frame(width:DrillStairs.blackSize.width,height:DrillStairs.blackSize.height)
                            .offset(x:DrillStairs.blackKeyLeft(above:number,width:width),
                                    y:row*DrillStairs.rowStep+DrillStairs.keySize.height+1-DrillStairs.blackSize.height/2)
                            .accessibilityHidden(true)
                    }
                }
            }.allowsHitTesting(false)
        }
    }

    private func open(_ stage: DrillStage) {
        if stairs.needsConnection(stage) { refuse(stage,"서버에 연결하면 Rhythm puzzle 칸을 풀 수 있어요.") }
        else { playing = stage }
    }

    private func refuse(_ stage: DrillStage, _ message: String) {
        refusals += 1
        if !reduceMotion { withAnimation(.linear(duration:0.36)) { shakes[stage.number, default:0] += 1 } }
        show(message)
    }

    @ViewBuilder private func game(_ stage: DrillStage) -> some View {
        let context = DrillStageContext(stage:stage,finished:{ stairs.clear(stage.number) },exit:{ playing = nil })
        switch stage.game {
        case .echoDragon: EchoDragonView(stage:context)
        case .memoryRun: MelodyRunView(connection:connection,stage:context)
        case .rhythmPuzzle: RhythmPuzzleView(connection:connection,stage:context)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        let target = min(stairs.shown.next,DrillStairs.count)
        let anchor = UnitPoint(x:0.5,y:Self.currentAnchor)
        if animated && !reduceMotion { withAnimation(.easeInOut(duration:0.6)) { proxy.scrollTo(target,anchor:anchor) } }
        else { proxy.scrollTo(target,anchor:anchor) }
    }

    // Back from a game: press the solved key and the black key above it and say so.
    // The stairs scroll only when the suggested (purple) key moved.
    private func climbed(_ proxy: ScrollViewProxy) {
        let before = stairs.shown.next
        var solved: [Int] = []
        withAnimation(reduceMotion ? nil : .spring(response:0.45,dampingFraction:0.75)) { solved = stairs.reveal() }
        guard let number = solved.first, let stage = DrillStairs.stage(number) else { return }
        if stairs.shown.next != before { scroll(proxy,animated:true) }
        show(stairs.shown.isComplete ? "\(stage.name) 클리어! 건반 계단을 모두 풀었어요" : "\(stage.name) 클리어!")
    }

    private func show(_ message: String) {
        withAnimation(.easeOut(duration:0.25)) { toast = message }
        UIAccessibility.post(notification:.announcement,argument:message)
        Task { @MainActor in
            try? await Task.sleep(for:.seconds(2.6))
            if toast == message { withAnimation(.easeIn(duration:0.25)) { toast = nil } }
        }
    }
}

enum DrillPalette {
    static let background = Color(red:0.925,green:0.910,blue:0.984)   // #ECE8FB
    static let deep = Color(red:0.290,green:0.224,blue:0.706)         // #4A39B4
}

// A short side-to-side shake; `phase` goes up by one per refused tap.
private struct Shake: GeometryEffect {
    var phase: CGFloat
    var animatableData: CGFloat { get { phase } set { phase = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX:7*sin(phase * .pi * 4),y:0))
    }
}

private struct StageKey: View {
    let stage: DrillStage
    let state: DrillStageState
    let offline: Bool
    let action: () -> Void
    private var face: Color {
        switch state {
        case .open: return .white
        case .next: return Color(red:0.392,green:0.314,blue:0.847)        // #6450D8
        case .done: return Color(red:0.867,green:0.847,blue:0.957)           // #DDD8F4
        }
    }
    private var edge: Color {
        switch state {
        case .open: return Color(red:0.835,green:0.808,blue:0.953)         // #D5CEF3
        case .next: return DrillPalette.deep
        case .done: return Color(red:0.812,green:0.784,blue:0.933)           // #CFC8EE
        }
    }
    private var noteColor: Color {
        switch state {
        case .open: return Color(red:0.420,green:0.400,blue:0.565)         // #6B6690
        case .next: return Color(red:0.894,green:0.875,blue:1.0)          // #E4DFFF
        case .done: return Color(red:0.361,green:0.341,blue:0.510)           // #5C5782
        }
    }
    private var gameColor: Color { state == .open ? SolfegeTheme.ink : state == .next ? .white : noteColor }
    private var stateLabel: String { state == .done ? "푼 칸" : state == .next ? "다음 칸" : "안 푼 칸" }
    var body: some View {
        Button(action:action) {
            // E2: no outline. The key has a side face along its bottom edge only — 6pt, or 2pt
            // when cleared, where the key also sits 4pt lower. Content is centred above
            // twice that height (Figma counts the side face and an equal bottom padding).
            let pressed = state == .done
            let side: CGFloat = pressed ? 2 : 6
            HStack(alignment:.center,spacing:0) {
                HStack(alignment:.firstTextBaseline,spacing:0) {
                    Text(stage.letter).font(.system(size:18,weight:.bold))
                    Text("\(stage.octave)").font(.system(size:13,weight:.bold))
                }
                Spacer(minLength:12)
                if offline {
                    Image(systemName:"wifi.slash").font(.system(size:15,weight:.semibold)).foregroundStyle(gameColor.opacity(0.8))
                        .padding(.trailing,8).accessibilityHidden(true)
                }
                Text(stage.game.title).font(.system(size:20,weight:.bold)).foregroundStyle(gameColor)
            }
            .foregroundStyle(noteColor)
            .padding(.leading,22).padding(.trailing,28).padding(.bottom,side*2)
            .frame(maxWidth:.infinity,maxHeight:.infinity)
            .background {
                RoundedRectangle(cornerRadius:10).fill(edge)
                KeyFace(radius:10,side:side).fill(face)
            }
            .padding(.top,pressed ? 4 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(stage.name), \(stage.game.title)")
        .accessibilityValue(offline ? "\(stateLabel), 연결 후 풀 수 있어요" : stateLabel)
        .accessibilityHint("두 번 탭하면 바로 시작해요")
        .accessibilityIdentifier("drill-stage-\(stage.number)")
    }
}

// The top face of an E2 key. Figma draws the side as a bottom-only inside stroke on a rounded
// rectangle, so the face is not cut by a straight line: its bottom corners curve too
// (radius wide, radius − side tall) and the side shows as a crescent that thickens at both ends.
private struct KeyFace: Shape {
    let radius: CGFloat
    let side: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = min(radius,rect.width/2), ry = max(0,r-side), bottom = rect.maxY-side, k: CGFloat = 0.5523
        var path = Path()
        path.move(to:CGPoint(x:rect.minX+r,y:rect.minY))
        path.addLine(to:CGPoint(x:rect.maxX-r,y:rect.minY))
        path.addArc(center:CGPoint(x:rect.maxX-r,y:rect.minY+r),radius:r,startAngle:.degrees(-90),endAngle:.degrees(0),clockwise:false)
        path.addLine(to:CGPoint(x:rect.maxX,y:bottom-ry))
        path.addCurve(to:CGPoint(x:rect.maxX-r,y:bottom),
                      control1:CGPoint(x:rect.maxX,y:bottom-ry+ry*k),control2:CGPoint(x:rect.maxX-r+r*k,y:bottom))
        path.addLine(to:CGPoint(x:rect.minX+r,y:bottom))
        path.addCurve(to:CGPoint(x:rect.minX,y:bottom-ry),
                      control1:CGPoint(x:rect.minX+r-r*k,y:bottom),control2:CGPoint(x:rect.minX,y:bottom-ry+ry*k))
        path.addLine(to:CGPoint(x:rect.minX,y:rect.minY+r))
        path.addArc(center:CGPoint(x:rect.minX+r,y:rect.minY+r),radius:r,startAngle:.degrees(180),endAngle:.degrees(270),clockwise:false)
        path.closeSubpath()
        return path
    }
}

// E2 black key: no outline, a 4pt side along the bottom; pressed, it sits 3pt lower with a 1pt side.
private struct BlackKey: View {
    let pressed: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius:8)
                .fill(pressed ? Color(red:0.212,green:0.196,blue:0.310) : Color(red:0.055,green:0.067,blue:0.125))   // #36324F / #0E1120
            KeyFace(radius:8,side:pressed ? 1 : 4)
                .fill(pressed ? Color(red:0.290,green:0.271,blue:0.408) : SolfegeTheme.ink)                    // #4A4568 / #1F2437
        }
        .padding(.top,pressed ? 3 : 0)
    }
}

// E2 back icon: a 5×10 chevron in a 20pt box, 2pt round stroke.
private struct BackChevron: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to:CGPoint(x:rect.minX+12,y:rect.minY+5))
        path.addLine(to:CGPoint(x:rect.minX+7,y:rect.minY+10))
        path.addLine(to:CGPoint(x:rect.minX+12,y:rect.minY+15))
        return path
    }
}

// Marks a minigame screen as one stage of the stairs.
struct StageChip: View {
    let stage: DrillStage
    var body: some View {
        Text("\(stage.name) 스테이지").font(.system(size:13,weight:.bold)).foregroundStyle(.white)
            .padding(.horizontal,10).padding(.vertical,4).background(SolfegeTheme.violet,in:Capsule())
            .accessibilityIdentifier("drill-stage-chip")
    }
}
