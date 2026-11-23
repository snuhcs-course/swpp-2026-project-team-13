import SwiftUI

// Only disposable examples live here. The real games and their journals are
// deliberately absent, while editing uses the same answer/board domain types.
@MainActor final class MiniTutorialSession: ObservableObject {
    let kind: TutorialKind
    @Published private(set) var page = 0
    @Published private(set) var memory: MelodyAnswers?
    @Published private(set) var selectedBar = 1
    @Published private(set) var echoInputs: [Int] = []
    @Published private(set) var board = RhythmBoard()
    @Published private(set) var didTap = false
    @Published private(set) var didDrag = false
    @Published private(set) var didConnect = false
    @Published private(set) var tieMode = false
    @Published var message = ""
    private var replaceSelectedBar = false
    private var rhythmPreparedPage: Int?
    init(kind: TutorialKind) {
        self.kind = kind
        if let round = TutorialSamples.memory { memory = MelodyAnswers(round: round, guideFirst: true) }
    }
    var tapTile: String? {
        TutorialSamples.rhythmRound?.solution.sorted { $0.start < $1.start }.first?.tileId
    }
    var dragTile: String? {
        guard let solution = TutorialSamples.rhythmRound?.solution.sorted(by: { $0.start < $1.start }), solution.count > 1 else { return nil }
        return solution[1].tileId
    }
    var canAdvance: Bool {
        if kind == .rhythmPuzzle && page == 3 { return didTap && didDrag }
        if kind == .rhythmPuzzle && page == 5 { return didConnect }
        return true
    }
    var taskCaption: String? {
        guard kind == .rhythmPuzzle else { return nil }
        if page == 3 { return !didTap ? "1. 강조된 조각을 터치해보세요." : !didDrag ? "2. 리듬 조각을 악보 빈칸에 끌어놓아보세요." : nil }
        if page == 5 { return !tieMode ? "1. 타이 버튼을 터치해보세요." : !didConnect ? "2. 강조된 두 조각을 손가락으로 이어보세요." : "두 조각을 타이로 연결했어요." }
        return nil
    }
    var highlights: [TutorialTarget] {
        guard page > 0 else { return [] }
        if kind == .memoryRun {
            if page == 3 { return [.keyboard, .notation] }
            if page == 4 { return [.notation, .keyboard, .undo, .erase] }
        }
        if kind == .echoDragon && page == 5 { return [.submit, .character] }
        if kind == .rhythmPuzzle {
            if page == 3 { return !didTap ? [.rhythmTapTile, .notation] : !didDrag ? [.rhythmDragTile, .dropSlot, .notation] : [.notation, .choices] }
            if page == 5 { return tieMode ? [.notation, .tieStart, .tieEnd] : [.tie] }
        }
        return [kind.steps[page-1].target]
    }
    func showPage(_ value: Int) {
        page = value; message = ""
        if kind == .echoDragon && page == 3 { echoInputs = [] }
        if kind == .echoDragon && page == 5 && echoInputs.count != 2 { echoInputs = [65, 69] }
        if kind == .memoryRun && page == 4, let round = TutorialSamples.memory {
            for bar in 1...2 {
                while let index = memory?.next(in: bar) { _ = memory?.enter(round.targets[index].midi, measure: bar) }
            }
            selectedBar = 1; replaceSelectedBar = false
        }
        if kind == .rhythmPuzzle && page == 3 && !didTap { board = RhythmBoard() }
        if kind == .rhythmPuzzle && [4, 5].contains(page), rhythmPreparedPage != page,
           let round = TutorialSamples.rhythmRound, let id = tapTile {
            board = RhythmBoard(placements: [.init(tileId: id, start: .zero), .init(tileId: id, start: round.pulse)])
            tieMode = false; didConnect = false; rhythmPreparedPage = page
        }
        if page != 5 { tieMode = false }
    }
    @discardableResult func enter(_ midi: Int) -> Bool {
        if kind == .echoDragon {
            guard [3, 4, 5].contains(page) else { return false }
            if echoInputs.count == 2 { echoInputs = [] }
            guard !echoInputs.isEmpty || midi == 65 else { message = "표시된 첫 음부터 눌러보세요."; return false }
            echoInputs.append(midi); return true
        }
        guard kind == .memoryRun, [3, 4].contains(page), var answer = memory else { return false }
        let changed = replaceSelectedBar ? answer.replace(measure: selectedBar, with: midi) : answer.enter(midi, measure: selectedBar)
        guard changed else { return false }
        memory = answer; replaceSelectedBar = false
        if answer.complete(selectedBar) && selectedBar < 2 { selectedBar += 1 }
        return true
    }
    func selectBar(_ bar: Int) {
        guard kind == .memoryRun, page == 4, (1...2).contains(bar), let answer = memory else { return }
        selectedBar = bar
        replaceSelectedBar = answer.round.targetIndices(measure: bar).contains { answer.pitches[$0] != nil }
    }
    func undo() {
        if kind == .echoDragon { if !echoInputs.isEmpty { echoInputs.removeLast() }; return }
        guard kind == .memoryRun, [3, 4].contains(page), var answer = memory else { return }
        if let bar = answer.undo() { selectedBar = bar; replaceSelectedBar = false; memory = answer }
    }
    func eraseBar() {
        guard kind == .memoryRun, page == 4, var answer = memory else { return }
        answer.clear(measure: selectedBar); memory = answer; replaceSelectedBar = false
    }
    func clearEcho() { echoInputs = [] }
    var rhythmFreeInput: Bool { kind == .rhythmPuzzle && page == 3 && didDrag }
    func choiceEnabled(_ id: String) -> Bool {
        page == 3 && (rhythmFreeInput || (!didTap && id == tapTile) || (didTap && !didDrag && id == dragTile))
    }
    @discardableResult func tapChoice(_ id: String) -> Bool {
        if rhythmFreeInput, let round = TutorialSamples.rhythmRound, let tiles = TutorialSamples.rhythm?.tileMap {
            return placeFreely(id, at: board.firstGap(tiles: tiles), round: round, tiles: tiles)
        }
        guard kind == .rhythmPuzzle, page == 3, !didTap, id == tapTile,
              let round = TutorialSamples.rhythmRound, let bank = TutorialSamples.rhythm else { return false }
        guard board.place(id, at: .zero, round: round, tiles: bank.tileMap) else { return false }
        didTap = true; message = ""; return true
    }
    @discardableResult func dropTile(_ id: String, at time: RhythmTime) -> Bool {
        if rhythmFreeInput, let round = TutorialSamples.rhythmRound, let tiles = TutorialSamples.rhythm?.tileMap {
            return placeFreely(id, at: time, round: round, tiles: tiles)
        }
        guard kind == .rhythmPuzzle, page == 3, didTap, !didDrag, id == dragTile,
              let round = TutorialSamples.rhythmRound, time == round.pulse, let bank = TutorialSamples.rhythm else {
            message = "강조된 조각을 점선 칸에 놓아주세요."; return false
        }
        guard board.place(id, at: time, round: round, tiles: bank.tileMap) else { return false }
        didDrag = true; message = ""; return true
    }
    private func placeFreely(_ id: String, at time: RhythmTime, round: RhythmRound, tiles: [String: RhythmTile]) -> Bool {
        if let issue = board.placementIssue(id, at: time, round: round, tiles: tiles) { message = issue; return false }
        let changed = board.place(id, at: time, round: round, tiles: tiles)
        if changed { message = "" }
        return changed
    }
    func remove(_ piece: RhythmPlacement) {
        guard kind == .rhythmPuzzle, page == 4 || rhythmFreeInput, let tiles = TutorialSamples.rhythm?.tileMap else { return }
        board.remove(piece, tiles: tiles)
    }
    func move(_ piece: RhythmPlacement, to time: RhythmTime) {
        guard kind == .rhythmPuzzle, page == 4 || rhythmFreeInput, let round = TutorialSamples.rhythmRound, let bank = TutorialSamples.rhythm else { return }
        if !board.move(piece, to: time, round: round, tiles: bank.tileMap) { message = "비어 있는 칸으로 옮겨보세요." }
        else { message = "" }
    }
    func enableTie() {
        guard kind == .rhythmPuzzle, page == 5 else { return }
        tieMode = true; message = ""
    }
    @discardableResult func connect(_ first: RhythmPlacement, _ second: RhythmPlacement) -> Bool {
        guard kind == .rhythmPuzzle, page == 5, tieMode, let round = TutorialSamples.rhythmRound,
              let tiles = TutorialSamples.rhythm?.tileMap,
              Set([first.start, second.start]) == Set([.zero, round.pulse]),
              board.connectionIssue(first, second, tiles: tiles) == nil else { return false }
        if !board.ties.contains(round.pulse) { _ = board.toggleTie(round.pulse, tiles: tiles) }
        didConnect = true; message = ""; return true
    }
}
