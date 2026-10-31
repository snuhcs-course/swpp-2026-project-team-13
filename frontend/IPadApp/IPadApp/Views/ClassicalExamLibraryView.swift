import SwiftUI

private struct ComposerPortrait: Decodable, Identifiable {
    var id: String; var name: String; var englishName: String; var years: String
    var resource: String; var source: URL; var credit: String; var remote: URL?
}

struct ClassicalExamLibraryView: View {
    @ObservedObject var model: AppModel
    @State private var showCredits = false
    private let portraits: [ComposerPortrait] = (try? Bundled.decode("composer-portraits")) ?? []
    private var composers: [String] { Array(Set(model.classicalQuestions.compactMap(\.composer))).sorted() }
    private var selected: [QuestionSummary] { model.classicalQuestions.filter { $0.composer == model.selectedComposer } }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment:.leading,spacing:26) {
                    HStack(alignment:.top) {
                        SectionCaption(eyebrow:"CLASSICAL DICTATION",title:model.selectedComposer ?? "클래식 청음",
                            subtitle:model.selectedComposer == nil ? "마음이 가는 작곡가를 골라 8마디 선율을 기록해 보세요." : "음계와 선율을 듣고, 빈 오선에 직접 적어보세요.")
                        Spacer(minLength:8)
                        Button { showCredits = true } label: { Image(systemName:"info.circle").font(.title3) }.accessibilityLabel("악보와 초상화 출처")
                    }
                    if !model.connected {
                        ContentUnavailableView("학습 공간에 연결해 주세요",systemImage:"network")
                        Button("연결 설정") { model.navigate(.settings) }.buttonStyle(PrimaryButton())
                    } else if !model.classicalLoaded {
                        ProgressView("클래식 문제를 불러오는 중")
                        Button("다시 불러오기") { Task { await model.loadClassical(reset:true) } }.buttonStyle(.bordered)
                    } else if composers.isEmpty {
                        ContentUnavailableView("등록된 클래식 문제가 없어요",systemImage:"music.note.list",description:Text("서버에 클래식 문제를 등록한 뒤 다시 불러와 주세요."))
                        Button("다시 불러오기") { Task { await model.loadClassical(reset:true) } }.buttonStyle(.bordered)
                    } else if let name = model.selectedComposer {
                        Button { model.selectedComposer = nil } label: { Label("작곡가 선택",systemImage:"chevron.left") }.buttonStyle(.bordered)
                        if let portrait = portraits.first(where: { $0.name == name }) { composerCard(portrait,count:selected.count,height:180) }
                        ForEach(selected) { question in
                            Button { Task { await model.choose(question.id) } } label: {
                                Card { HStack(spacing:20) {
                                    Image(systemName:"music.note").font(.title2).foregroundStyle(SORITheme.violet)
                                    VStack(alignment:.leading,spacing:10) {
                                        Text(question.title).font(.headline).foregroundStyle(SORITheme.ink)
                                        Text("\(question.keySignature.label) · \(question.timeSignature.numerator)/\(question.timeSignature.denominator) · 8마디").font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength:8); Image(systemName:"arrow.up.right").foregroundStyle(SORITheme.violet)
                                } }
                            }.buttonStyle(.plain).accessibilityIdentifier("classical-question-\(question.id.uuidString.lowercased())")
                        }
                    } else {
                        let columns = geometry.size.width >= 950 ? 3 : geometry.size.width >= 580 ? 2 : 1
                        let rows = max(1,Int(ceil(Double(max(composers.count,1))/Double(columns))))
                        let height = max(210,(geometry.size.height-180)/CGFloat(rows)-18)
                        LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:18),count:columns),spacing:18) {
                            ForEach(composers,id:\.self) { name in
                                Button { withAnimation(.easeInOut(duration:0.2)) { model.selectedComposer = name } } label: {
                                    if let portrait = portraits.first(where: { $0.name == name }) {
                                        composerCard(portrait,count:model.classicalQuestions.filter { $0.composer == name }.count,height:height)
                                    } else {
                                        Text(name).font(.title2.bold()).frame(maxWidth:.infinity,minHeight:height).background(SORITheme.soft,in:RoundedRectangle(cornerRadius:24))
                                    }
                                }.buttonStyle(.plain).accessibilityIdentifier("composer-\(name)")
                            }
                        }
                    }
                    if model.classicalHasNextPage { Button("클래식 문제 더 불러오기") { Task { await model.loadClassical() } }.buttonStyle(.bordered) }
                    if model.demo { DemoBadge() }
                }.padding(28).frame(maxWidth:1400,alignment:.leading).frame(maxWidth:.infinity)
            }.refreshable { await model.loadClassical(reset:true) }
        }
        .task(id:model.connected) { if model.connected && !model.classicalLoaded { await model.loadClassical() } }
        .sheet(isPresented:$showCredits) {
            NavigationStack {
                ScrollView { VStack(alignment:.leading,spacing:22) {
                    Text("악보: GTTM Database / musicparser 미러 · CC BY-NC-SA 4.0").font(.headline)
                    Link("악보 데이터베이스",destination:URL(string:"https://gttm.jp/gttm/database/")!)
                    Text("원본부터 온전한 8마디인 단선율 발췌본만 사용합니다. 발췌 편곡의 조성을 유지합니다.").font(.subheadline)
                    ForEach(portraits) { portrait in
                        VStack(alignment:.leading,spacing:6) {
                            Text(portrait.name).font(.headline); Text(portrait.credit).font(.footnote)
                            Link("초상화 출처",destination:portrait.source)
                        }
                    }
                }.padding(28) }
                    .navigationTitle("악보와 초상화 출처").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement:.confirmationAction) { Button("닫기") { showCredits = false } } }
            }
        }
    }
    private func composerCard(_ portrait: ComposerPortrait, count: Int, height: CGFloat) -> some View {
        ZStack(alignment:.bottomLeading) {
            Color(red:0.92,green:0.91,blue:0.96)
            GeometryReader { geometry in
                Group {
                    if let image = UIImage(named:portrait.resource) { Image(uiImage:image).resizable().scaledToFill() }
                    else if let remote = portrait.remote { AsyncImage(url:remote) { image in image.resizable().scaledToFill() } placeholder: { Color.clear } }
                }.frame(width:geometry.size.width,height:geometry.size.height,alignment:.top).clipped().saturation(0).opacity(0.24).accessibilityHidden(true)
            }
            LinearGradient(colors:[Color.white.opacity(0.08),Color.white.opacity(0.9)],startPoint:.top,endPoint:.bottom)
            VStack(alignment:.leading,spacing:8) {
                Text(portrait.englishName.uppercased()).font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(SORITheme.violet)
                HStack(alignment:.firstTextBaseline) {
                    Text(portrait.name).font(.system(size:30,weight:.bold,design:.rounded)).foregroundStyle(SORITheme.ink)
                    Spacer(minLength:8); Image(systemName:"arrow.up.right").foregroundStyle(SORITheme.violet)
                }
                Text("\(portrait.years) · \(count)개 선율").font(.subheadline).foregroundStyle(SORITheme.ink.opacity(0.7))
            }.padding(24)
        }.frame(height:height).clipShape(RoundedRectangle(cornerRadius:24))
            .overlay(RoundedRectangle(cornerRadius:24).strokeBorder(.white.opacity(0.8),lineWidth:1))
            .accessibilityElement(children:.ignore).accessibilityLabel("\(portrait.name), \(count)개 청음 문제")
    }
}
