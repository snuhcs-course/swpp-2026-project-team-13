import SwiftUI

private struct MiniGameTutorial<Illustration: View>: View {
    let title: String; let titles: [String]; let messages: [String]; let done: ()->Void
    @ViewBuilder var illustration: (Int)->Illustration
    @State private var page = 0
    var body: some View {
        VStack(spacing:18) {
            HStack { Text(title+" · 게임 방법").font(.headline); Spacer(); Button("건너뛰기",action:done) }
            HStack(spacing:7) { ForEach(titles.indices,id:\.self) { i in Capsule().fill(i <= page ? SolfegeTheme.violet : SolfegeTheme.soft).frame(height:5) } }
            HStack { Text("\(page+1)/\(titles.count)").monospacedDigit(); Spacer(); Label("좌우로 넘겨보세요",systemImage:"hand.draw") }.font(.caption).foregroundStyle(.secondary)
            TabView(selection:$page) {
                ForEach(titles.indices,id:\.self) { i in
                    ScrollView {
                        VStack(spacing:22) {
                            illustration(i).frame(maxWidth:660).padding(18).background(.white,in:RoundedRectangle(cornerRadius:18))
                            Text(titles[i]).font(.title2.bold())
                            Text(messages[i]).font(.body).lineSpacing(7).frame(maxWidth:560).multilineTextAlignment(.center)
                        }.padding(.vertical,18).padding(.horizontal,8)
                    }.tag(i)
                }
            }.tabViewStyle(.page(indexDisplayMode:.never))
            HStack {
                Button("이전") { withAnimation { page -= 1 } }.disabled(page == 0).frame(minWidth:60,minHeight:44)
                Spacer()
                Button(page == titles.count-1 ? "시작하기" : "다음") {
                    if page == titles.count-1 { done() } else { withAnimation { page += 1 } }
                }.buttonStyle(PrimaryButton(compact:true))
            }
        }.padding(28).background(SolfegeTheme.background).presentationDetents([.large])
    }
}

private enum MiniGameExamples {
    static let rhythm: RhythmCatalog? = try? Bundled.decode("rhythm-puzzle-v3")
    static let melody: MelodyRound? = {
        guard let bank: MemoryCatalog = try? Bundled.decode("memory-run-v2"),
              let excerpt = bank.excerpts.first(where:{$0.beginnerEligible && $0.bars == 2}),
              let source = bank.sources.first(where:{$0.id == excerpt.sourceId}),
              let url = Bundle.main.url(forResource:source.file,withExtension:nil),
              let data = try? Data(contentsOf:url), let music = try? MelodyXMLParser.parse(data) else { return nil }
        return try? MelodyRound(source:music,start:excerpt.first,bars:2)
    }()
}

struct RhythmTutorialView: View {
    let done: ()->Void
    var body: some View {
        MiniGameTutorial(title:"Rhythm puzzle",titles:["예비박 다음, 두 마디 듣기","탭하거나 바로 끌어 넣기","연결하고, 누르면 지우기","채점하거나 정답 보고 넘기기"],messages:[
            "1초 후 예비박 한 마디와 선율이 나와요. 4/4는 4번, 3/4는 3번, 6/8은 6번의 예비박이 들리고 첫 박이 더 커요.",
            "보기를 탭하면 첫 빈칸에, 기다리지 않고 끌면 원하는 칸에 들어가요. 점선은 한 박이고, 긴 음 뒤에 남은 반 박은 반 칸으로 표시돼요. 파란 조각은 한 박보다 길고 보라 조각은 짧아요.",
            "이웃한 두 조각 사이를 그어 붙임줄을 연결하세요. 오른쪽 아래 타이 버튼으로도 연결할 수 있어요. 조각이나 붙임줄을 탭하면 삭제되고, 되돌리기로 복원할 수 있어요. 쉼표는 연결되지 않아요.",
            "첫 오답은 정오만, 두 번째는 위치 힌트, 세 번째는 정답을 보여줘요. 빈칸 제출은 오답으로 세지 않아요. 어려우면 게임 방법 메뉴의 ‘정답 보고 넘기기’를 선택하세요."
        ],done:done) { step in
            VStack(spacing:10) {
                if let bank = MiniGameExamples.rhythm,let round = bank.rounds.first {
                    let board = step >= 2 ? RhythmBoard(placements:round.solution,ties:round.solutionTies) : step == 1 ? RhythmBoard(placements:Array(round.solution.prefix(2)),ties:[]) : RhythmBoard()
                    RhythmStaffSystem(round:round,board:board,tiles:bank.tileMap)
                    if step == 1 {
                        HStack { ForEach(Array(round.choices.prefix(3)),id:\.self) { id in
                            if let tile = bank.tileMap[id] { RhythmTileFace(tile:tile,pulse:round.pulse) }
                        } }
                        Label("탭 ↑   또는   드래그 ↑",systemImage:"hand.point.up.left").foregroundStyle(SolfegeTheme.violet)
                    }
                }
                if step == 0 { Label("예비박 → 선율 재생",systemImage:"speaker.wave.2").foregroundStyle(SolfegeTheme.violet) }
                if step == 2 { HStack { RhythmTieIcon().frame(width:40,height:40); Text("조각 → 이웃 조각"); Spacer(); Image(systemName:"arrow.uturn.backward") } }
                if step == 3 { HStack { Label("게임 방법",systemImage:"questionmark.circle"); Spacer(); Text("정답 보고 넘기기 →").foregroundStyle(SolfegeTheme.violet) } }
            }
        }
    }
}

struct MemoryTutorialView: View {
    let done: ()->Void
    var body: some View {
        MiniGameTutorial(title:"Memory run",titles:["두 가지 연습 방식","듣고, 첫 음부터 직접 입력","다시 듣고 편하게 고치기","정답과 내 답을 나란히 확인"],messages:[
            "Memory는 전체 선율을 연속으로 듣고 시간제한 없이 복원해요. Groove는 한 마디 듣기와 정해진 입력 시간을 번갈아 진행해요.",
            "리듬과 쉼표는 이미 표시되어 있어요. 회색 점선 음표 자리를 건반으로 채우세요. 강조된 첫 음도 직접 눌러야 해요. 첫 음은 안내이므로 점수에서 제외돼요.",
            "Memory의 다시 듣기에서 바로 듣거나 예비박부터 들을 수 있어요. 답은 유지돼요. 채운 마디를 선택하고 건반을 누르면 그 마디를 지운 뒤 첫 음부터 다시 입력해요. 되돌리면 지우기 전 답 전체가 돌아와요.",
            "위에는 정답 전체, 아래에는 내 답 전체가 같은 간격으로 보여요. 빈칸이 있어도 제출할 수 있어요. 초급은 2마디씩, 중급은 2·2·4·4마디, 고급은 4마디씩 네 문제를 풀어요."
        ],done:done) { step in
            VStack(spacing:12) {
                if step == 0 { HStack(spacing:20) { Label("Memory",systemImage:"brain.head.profile"); Label("Groove",systemImage:"metronome") }.font(.title3.bold()).foregroundStyle(SolfegeTheme.violet).padding(.vertical,30) }
                else if let round = MiniGameExamples.melody {
                    let pitches: [Int?] = round.targets.enumerated().map { step == 3 || $0.offset < 2 ? $0.element.midi : nil }
                    if step == 3 { Text("정답").font(.caption); MemoryPhraseView(round:round,answers:pitches,reveal:true); Text("내 답").font(.caption) }
                    MemoryPhraseView(round:round,answers:pitches,selectedBar:step == 2 ? 1 : nil)
                    if step == 1 { MelodyPianoView(range:60...72,enabled:false,solfege:true,reference:round.targets.first?.midi,onDown:{_ in},onUp:{_ in}).frame(height:130) }
                    if step == 2 { HStack { Label("바로 다시 듣기",systemImage:"play.fill"); Label("예비박부터",systemImage:"metronome"); Image(systemName:"arrow.uturn.backward") }.font(.caption).foregroundStyle(SolfegeTheme.violet) }
                }
            }
        }
    }
}
