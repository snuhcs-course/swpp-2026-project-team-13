import SwiftUI

// Lives in the same per-origin/per-user folder as the minigame journals, so account
// deletion's LocalStore.removeAll also removes the climb.
final class DrillStairsStore {
    let root: URL
    var file: URL { root.appendingPathComponent("drill-stairs-v1.json") }
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    func load() throws -> DrillStairsProgress {
        guard FileManager.default.fileExists(atPath:file.path) else { return DrillStairsProgress() }
        return try DrillStairsProgress.load(Data(contentsOf:file))
    }
    func save(_ progress: DrillStairsProgress) throws {
        try JSONEncoder().encode(progress).write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
    }
}

// What a minigame needs to run as one stage of the stairs.
struct DrillStageContext {
    let stage: DrillStage
    // Called once the stage's round is finished (scored, answered correctly or revealed).
    let finished: () -> Void
    // Back to the stairs, from the result or from ✕.
    let exit: () -> Void
}

@MainActor final class DrillStairsModel: ObservableObject {
    // What the stairs show. A clear is saved at once but shown when the game closes,
    // so the next key lights up while the user is looking.
    @Published private(set) var shown = DrillStairsProgress()
    @Published var error: String?
    private(set) var progress = DrillStairsProgress()
    let rhythmAvailable: Bool
    private var store: DrillStairsStore?
    private var readable = true

    init(connection: RhythmConnection?, root: URL? = nil) {
        rhythmAvailable = connection != nil
        do {
            let folder = try root ?? LocalStore(scope:connection?.scope ?? "drill-stairs-guest").root
            let local = try DrillStairsStore(root:folder)
            store = local; progress = try local.load(); shown = progress
        } catch {
            readable = false
            self.error = "계단 진행 기록을 읽지 못했어요. 기존 기록은 그대로 두고, 이번 플레이는 저장하지 않아요."
        }
    }
    func state(_ stage: DrillStage) -> DrillStageState { shown.state(stage.number) }
    // Rhythm puzzle needs the server, as on the old Drill cards.
    func needsConnection(_ stage: DrillStage) -> Bool { stage.game == .rhythmPuzzle && !rhythmAvailable }
    func canStart(_ stage: DrillStage) -> Bool { !needsConnection(stage) }
    func clear(_ number: Int) {
        guard progress.clear(number), readable, let store else { return }
        do { try store.save(progress) }
        catch { self.error = "계단 진행을 기기에 저장하지 못했어요. \(error.localizedDescription)" }
    }
    // Shows what was solved while a game was open; returns those stage numbers, lowest first.
    @discardableResult func reveal() -> [Int] {
        let solved = progress.cleared.subtracting(shown.cleared).sorted()
        if !solved.isEmpty { shown = progress }
        return solved
    }
}
